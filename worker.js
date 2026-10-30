/**
 * Enivel Worker (Cloudflare Workers, free plan)
 *  1. SMS one-time codes through BulkSMS            POST /send, POST /check
 *  2. Pickup reminder pop-ups to drivers' phones     runs every minute (Cron Trigger "* * * * *")
 *
 * Secrets (Settings → Variables and Secrets → type Secret):
 *   BULKSMS_TOKEN      base64 of "username:password" from BulkSMS
 *   OTP_SECRET         any long random string
 *   SUPABASE_SECRET    Supabase → Project Settings → API Keys → secret key (sb_secret_...) or legacy service_role key
 *   VAPID_PRIVATE_JWK  the private key JSON from vapid-private-key.json (keep private, never in GitHub)
 * Variables (type Text):
 *   ALLOWED_ORIGIN     https://cyiber069.github.io
 *   SENDER             Enivel
 * Binding (Settings → Bindings → KV namespace), strongly recommended:
 *   LIMITS             a KV namespace. Limits code sends per phone and per network, attempts per code,
 *                      and makes each code single-use. Without it /send and /check refuse to run.
 *   SUPABASE_URL       https://kakzsotpfzgghlfanaut.supabase.co
 *   VAPID_PUBLIC       the public key (also inside the app)
 *   VAPID_SUBJECT      mailto:acxebikes@gmail.com
 */
const CODE_TTL_MS = 5 * 60 * 1000;
const enc = new TextEncoder();
const b64u = buf => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = s => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), c => c.charCodeAt(0));
const concat = (...a) => { const out = new Uint8Array(a.reduce((n, x) => n + x.length, 0)); let o = 0; for (const x of a) { out.set(x, o); o += x.length; } return out; };

async function hmac(secret, msg) {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return [...new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(msg)))].map(b => b.toString(16).padStart(2, '0')).join('');
}
function cors(env) {
  return { 'Access-Control-Allow-Origin': env.ALLOWED_ORIGIN || '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type', 'Content-Type': 'application/json' };
}
const json = (env, obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: cors(env) });
const validZA = p => /^\+27[6-8]\d{8}$/.test(p);
/* simple counters in KV: at most `max` hits per `ttl` seconds for a key */
async function allow(env, key, max, ttl) {
  const n = parseInt(await env.LIMITS.get('rl:' + key) || '0', 10);
  if (n >= max) return false;
  await env.LIMITS.put('rl:' + key, String(n + 1), { expirationTtl: Math.max(60, ttl) });
  return true;
}
function safeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let r = 0; for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}



/* ---------- Sign in with Face ID / fingerprint (WebAuthn passkeys) ---------- */
const b64uBytes = s => unb64u(String(s || ''));
async function sha256(buf) { return new Uint8Array(await crypto.subtle.digest('SHA-256', buf)); }
function derToRaw(der) {
  // ECDSA signature: DER SEQUENCE(r, s) -> 64-byte r||s
  let i = 2; if (der[1] & 0x80) i = 2 + (der[1] & 0x7f);
  const read = () => { i++; const len = der[i++]; let v = der.slice(i, i + len); i += len; while (v.length > 32 && v[0] === 0) v = v.slice(1); const out = new Uint8Array(32); out.set(v, 32 - v.length); return out; };
  return concat(read(), read());
}
async function passkeyChallenge(env) {
  const challenge = b64u(crypto.getRandomValues(new Uint8Array(32)));
  const exp = Date.now() + 2 * 60 * 1000;
  return { challenge, exp, sig: await hmac(env.OTP_SECRET, 'pk|' + challenge + '|' + exp) };
}
async function passkeyLogin(b, env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SECRET) return { error: 'Face ID sign-in is not set up yet' };
  if (!b || typeof b.challenge !== 'string' || typeof b.sig !== 'string') return { error: 'bad request' };
  if (Date.now() > Number(b.exp)) return { error: 'This sign-in took too long. Try again.' };
  if (!safeEqual(await hmac(env.OTP_SECRET, 'pk|' + b.challenge + '|' + b.exp), b.sig)) return { error: 'bad challenge' };
  if (env.LIMITS) { if (await env.LIMITS.get('pkc:' + b.challenge)) return { error: 'already used' }; await env.LIMITS.put('pkc:' + b.challenge, '1', { expirationTtl: 300 }); }
  const clientData = b64uBytes(b.clientDataJSON), authData = b64uBytes(b.authenticatorData), sig = b64uBytes(b.signature);
  let cd; try { cd = JSON.parse(new TextDecoder().decode(clientData)); } catch { return { error: 'bad client data' }; }
  const origin = env.ALLOWED_ORIGIN || '';
  if (cd.type !== 'webauthn.get' || cd.challenge !== b.challenge || (origin && origin !== '*' && cd.origin !== origin)) return { error: 'This sign-in did not come from the Enivel app' };
  const rpId = b.rpId && (origin === '*' || !origin) ? b.rpId : new URL(origin).hostname;
  const rpHash = await sha256(enc.encode(rpId));
  if (authData.length < 37 || !rpHash.every((x, i) => x === authData[i])) return { error: 'wrong site' };
  const flags = authData[32]; if (!(flags & 0x01) || !(flags & 0x04)) return { error: 'Face ID or fingerprint was not confirmed' };
  const look = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/passkey_lookup', { method: 'POST', headers: supaHeaders(env), body: JSON.stringify({ p_cred_id: b.id }) });
  if (!look.ok) return { error: 'lookup failed' };
  const rows = await look.json(); const row = rows && rows[0];
  if (!row) return { error: 'This Face ID is not linked to an Enivel account. Sign in with your password and turn it on again.' };
  if (row.banned) return { error: 'This account has been permanently banned.' };
  if (row.suspended) return { error: 'This account is suspended. Contact Enivel support.' };
  const signed = concat(authData, await sha256(clientData));
  let ok = false;
  try {
    if (row.alg === -257) { const key = await crypto.subtle.importKey('spki', b64uBytes(row.pk), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']); ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, sig, signed); }
    else { const key = await crypto.subtle.importKey('spki', b64uBytes(row.pk), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']); ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, derToRaw(sig), signed); }
  } catch (e) { ok = false; }
  if (!ok) return { error: 'Face ID sign-in could not be verified' };
  const gl = await fetch(env.SUPABASE_URL + '/auth/v1/admin/generate_link', { method: 'POST', headers: supaHeaders(env), body: JSON.stringify({ type: 'magiclink', email: row.email }) });
  if (!gl.ok) return { error: 'Could not start the session (' + gl.status + ')' };
  const link = await gl.json();
  const token_hash = link.hashed_token || (link.properties && link.properties.hashed_token);
  if (!token_hash) return { error: 'Could not start the session' };
  return { token_hash, email: row.email, user_id: row.user_id };
}

/* ---------- Web Push (RFC 8291 aes128gcm + RFC 8292 VAPID) ---------- */
async function hkdf(salt, ikm, info, len) {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, len * 8));
}
export async function encryptPayload(payload, p256dhB64, authB64) {
  const uaPublic = unb64u(p256dhB64), authSecret = unb64u(authB64);
  const asKeys = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', asKeys.publicKey));
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asKeys.privateKey, 256));
  const ikm = await hkdf(authSecret, shared, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const aes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aes, concat(enc.encode(payload), new Uint8Array([2]))));
  const rs = new Uint8Array([0, 0, 16, 0]);
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, cipher);
}
export async function vapidAuth(endpoint, env) {
  const aud = new URL(endpoint).origin;
  const header = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const claims = b64u(enc.encode(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: env.VAPID_SUBJECT || 'mailto:acxebikes@gmail.com' })));
  const key = await crypto.subtle.importKey('jwk', JSON.parse(env.VAPID_PRIVATE_JWK), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(header + '.' + claims));
  return `vapid t=${header}.${claims}.${b64u(sig)}, k=${env.VAPID_PUBLIC}`;
}
async function sendPush(row, env) {
  const payload = JSON.stringify({ title: row.title, body: row.body, tag: row.tag, url: row.url });
  const body = await encryptPayload(payload, row.p256dh, row.auth);
  return fetch(row.endpoint, { method: 'POST', body, headers: { 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '900', Urgency: 'high', Authorization: await vapidAuth(row.endpoint, env) } });
}
function supaHeaders(env) {
  const k = env.SUPABASE_SECRET; const h = { apikey: k, 'Content-Type': 'application/json' };
  if (!k.startsWith('sb_')) h.Authorization = 'Bearer ' + k;
  return h;
}
async function runReminders(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SECRET || !env.VAPID_PRIVATE_JWK) return { skipped: 'not configured' };
  const r = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/due_push', { method: 'POST', headers: supaHeaders(env), body: '{}' });
  if (!r.ok) return { error: 'due_push ' + r.status + ' ' + (await r.text()) };
  const rows = await r.json(); let sent = 0, dropped = 0;
  for (const row of rows) {
    try {
      const res = await sendPush(row, env);
      if (res.status === 404 || res.status === 410) {
        dropped++;
        await fetch(env.SUPABASE_URL + '/rest/v1/rpc/drop_push_sub', { method: 'POST', headers: supaHeaders(env), body: JSON.stringify({ p_endpoint: row.endpoint }) });
      } else if (res.ok) sent++;
    } catch (e) { /* one bad phone must not stop the others */ }
  }
  return { due: rows.length, sent, dropped };
}

export default {
  async fetch(req, env) {
    if (req.method === 'OPTIONS') return new Response(null, { headers: cors(env) });
    const url = new URL(req.url);
    if (req.method === 'GET' && url.pathname === '/health') return json(env, { ok: true, sms: !!env.BULKSMS_TOKEN, limits: !!env.LIMITS, reminders: !!(env.SUPABASE_SECRET && env.VAPID_PRIVATE_JWK), faceid: !!(env.SUPABASE_SECRET && env.OTP_SECRET) });
    if (req.method !== 'POST') return json(env, { error: 'POST only' }, 405);
    let body; try { body = await req.json(); } catch { return json(env, { error: 'bad json' }, 400); }
    if (url.pathname === '/passkey/challenge') return json(env, await passkeyChallenge(env));
    if (url.pathname === '/passkey/login') {
      if (env.LIMITS && !(await allow(env, 'pk:' + (req.headers.get('CF-Connecting-IP') || 'x'), 30, 600))) return json(env, { error: 'Too many attempts. Try again later.' }, 429);
      const r = await passkeyLogin(body, env); return json(env, r, r.error ? 400 : 200);
    }
    const phone = String(body.phone || '').replace(/[\s\-()]/g, '');
    if (!validZA(phone)) return json(env, { error: 'South African cellphone in +27 format required' }, 400);
    if (!env.LIMITS) return json(env, { error: 'Rate limiting is not set up (add the LIMITS KV binding)' }, 503);
    const ip = req.headers.get('CF-Connecting-IP') || 'unknown';
    if (url.pathname === '/send') {
      if (!(await allow(env, 'p:' + phone, 3, 900)) || !(await allow(env, 'ip:' + ip, 10, 3600))) return json(env, { error: 'Too many codes requested. Try again later.' }, 429);
      const code = String(Math.floor(100000 + Math.random() * 900000));
      const exp = Date.now() + CODE_TTL_MS;
      const token = await hmac(env.OTP_SECRET, `${phone}|${code}|${exp}`);
      const r = await fetch('https://api.bulksms.com/v1/messages', {
        method: 'POST', headers: { Authorization: 'Basic ' + env.BULKSMS_TOKEN, 'Content-Type': 'application/json' },
        body: JSON.stringify({ to: phone, from: env.SENDER || 'Enivel', body: `Enivel code: ${code}. It expires in 5 minutes. Never share it.` })
      });
      if (!r.ok) return json(env, { error: 'SMS provider error ' + r.status, detail: await r.text() }, 502);
      return json(env, { token, exp });
    }
    if (url.pathname === '/check') {
      const { code, token, exp } = body;
      if (typeof token !== 'string' || !/^[0-9a-f]{64}$/.test(token)) return json(env, { ok: false, reason: 'format' });
      if (!/^\d{6}$/.test(String(code || ''))) return json(env, { ok: false, reason: 'format' });
      if (Date.now() > Number(exp)) return json(env, { ok: false, reason: 'expired' });
      if (await env.LIMITS.get('used:' + token)) return json(env, { ok: false, reason: 'used' });
      if (!(await allow(env, 't:' + token, 5, 600))) return json(env, { ok: false, reason: 'locked' });
      const good = safeEqual(await hmac(env.OTP_SECRET, `${phone}|${code}|${exp}`), token);
      if (good) await env.LIMITS.put('used:' + token, '1', { expirationTtl: 900 });
      return json(env, { ok: good });
    }
    return json(env, { error: 'not found' }, 404);
  },
  async scheduled(event, env, ctx) { ctx.waitUntil(runReminders(env)); }
};
