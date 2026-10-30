/**
 * Enivel Worker (Cloudflare Workers, free plan)
 *  1. SMS one-time codes through BulkSMS            POST /send, POST /check
 *  2. Pickup reminder pop-ups to drivers' phones     runs every minute (Cron Trigger "* * * * *")
 *  3. Phone pop-ups for parents and kids             POST /push/notify {id} right away, and the same cron
 *     (driver nearby, picked up, dropped off, driver outside, running late, emergency)
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
/* only real browser push services (Chrome/Android, Firefox, Safari/iPhone, Edge) */
const PUSH_HOSTS = /^https:\/\/([a-z0-9-]+\.)*(googleapis\.com|push\.services\.mozilla\.com|mozaws\.net|push\.apple\.com|notify\.windows\.com)(:\d+)?\//i;
export const pushHostOk = endpoint => PUSH_HOSTS.test(String(endpoint || ''));
async function sendPush(row, env) {
  if (!pushHostOk(row.endpoint)) return new Response(null, { status: 400 });
  const payload = JSON.stringify({ title: row.title, body: row.body, tag: row.tag, url: row.url });
  const body = await encryptPayload(payload, row.p256dh, row.auth);
  return fetch(row.endpoint, { method: 'POST', body, headers: { 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '900', Urgency: 'high', Authorization: await vapidAuth(row.endpoint, env) } });
}
function supaHeaders(env) {
  const k = env.SUPABASE_SECRET; const h = { apikey: k, 'Content-Type': 'application/json' };
  if (!k.startsWith('sb_')) h.Authorization = 'Bearer ' + k;
  return h;
}
/* send a list of pop-up rows; phones that no longer accept pop-ups are removed */
async function deliver(rows, env) {
  let sent = 0, dropped = 0;
  for (const row of rows || []) {
    try {
      const res = await sendPush(row, env);
      if (res.status === 404 || res.status === 410) {
        dropped++;
        await fetch(env.SUPABASE_URL + '/rest/v1/rpc/drop_push_sub', { method: 'POST', headers: supaHeaders(env), body: JSON.stringify({ p_endpoint: row.endpoint }) });
      } else if (res.ok) sent++;
    } catch (e) { /* one bad phone must not stop the others */ }
  }
  return { sent, dropped };
}
const pushReady = env => !!(env.SUPABASE_URL && env.SUPABASE_SECRET && env.VAPID_PRIVATE_JWK);
/* parents' and kids' pop-ups: notifications saved in the last 5 minutes (each sent once, checked in Supabase) */
async function notifPush(id, env) {
  const r = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/notif_push', { method: 'POST', headers: supaHeaders(env), body: JSON.stringify({ p_id: id }) });
  if (!r.ok) return { error: 'notif_push ' + r.status };
  const rows = await r.json();
  return { due: rows.length, ...(await deliver(rows, env)) };
}
async function runNotifs(env) {
  if (!pushReady(env)) return { skipped: 'not configured' };
  const r = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/notif_push_due', { method: 'POST', headers: supaHeaders(env), body: '{}' });
  if (!r.ok) return { error: 'notif_push_due ' + r.status + ' ' + (await r.text()) };
  const rows = await r.json();
  return { due: rows.length, ...(await deliver(rows, env)) };
}
async function runReminders(env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SECRET || !env.VAPID_PRIVATE_JWK) return { skipped: 'not configured' };
  const r = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/due_push', { method: 'POST', headers: supaHeaders(env), body: '{}' });
  if (!r.ok) return { error: 'due_push ' + r.status + ' ' + (await r.text()) };
  const rows = await r.json();
  return { due: rows.length, ...(await deliver(rows, env)) };
}

/* ===== PayFast (pays) ===== */
/* "Pay for parents" and Enivel Pays card payments (admin only).
 * The admin types the card on PayFast's own page: Enivel and this Worker never see or store it.
 *   POST /pay/start {intentId}  signs the PayFast form for a payment Supabase created (pay_intent_create
 *                               works out the amount from bookings, never from the app) -> {action, fields}
 *   POST /pay/itn               PayFast's payment notice. Needs a good signature, PayFast's own validate
 *                               check, status COMPLETE and exactly the payment's amount; then Supabase
 *                               pay_intent_complete marks it paid. A repeated notice changes nothing.
 * Settings: PAYFAST_MERCHANT_ID, PAYFAST_MERCHANT_KEY (Text), PAYFAST_PASSPHRASE (Secret),
 *           PAYFAST_SANDBOX ('1' = sandbox.payfast.co.za test payments), APP_URL (the app address).
 *           Also uses SUPABASE_URL + SUPABASE_SECRET. See WORKER-SETUP.md "Card payments (PayFast)". */
/* MD5 (PayFast signs with MD5; Workers' crypto.subtle has no MD5). Input is hashed as UTF-8. */
export function pfMd5(str) {
  const bytes = new TextEncoder().encode(String(str));
  const n = bytes.length, blocks = ((n + 8) >>> 6) + 1, w = new Uint32Array(blocks * 16);
  for (let i = 0; i < n; i++) w[i >> 2] |= bytes[i] << ((i % 4) * 8);
  w[n >> 2] |= 0x80 << ((n % 4) * 8);
  w[blocks * 16 - 2] = (n * 8) >>> 0; w[blocks * 16 - 1] = Math.floor(n / 0x20000000);
  const S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21];
  const K = Array.from({ length: 64 }, (_, i) => Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296) >>> 0);
  let a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  for (let o = 0; o < w.length; o += 16) {
    let A = a0, B = b0, C = c0, D = d0;
    for (let i = 0; i < 64; i++) {
      const r = i >> 4; let F, g;
      if (r === 0) { F = (B & C) | (~B & D); g = i; }
      else if (r === 1) { F = (D & B) | (~D & C); g = (5 * i + 1) % 16; }
      else if (r === 2) { F = B ^ C ^ D; g = (3 * i + 5) % 16; }
      else { F = C ^ (B | ~D); g = (7 * i) % 16; }
      F = (F + A + K[i] + w[o + g]) >>> 0; const s = S[r * 4 + (i % 4)];
      A = D; D = C; C = B; B = (B + ((F << s) | (F >>> (32 - s)))) >>> 0;
    }
    a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0; c0 = (c0 + C) >>> 0; d0 = (d0 + D) >>> 0;
  }
  return [a0, b0, c0, d0].map(v => [0, 8, 16, 24].map(s => ((v >>> s) & 255).toString(16).padStart(2, '0')).join('')).join('');
}
/* PayFast's encoding is PHP urlencode (spaces as +, upper-case hex). Their JS sample leaves !'()*~ as they are;
   the notice is accepted with either, the form we send never contains those characters. */
const pfEnc = v => encodeURIComponent(String(v ?? '').trim()).replace(/[!'()*~]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase()).replace(/%20/g, '+');
const pfEncJs = v => encodeURIComponent(String(v ?? '').trim()).replace(/%20/g, '+');
/* signature = MD5 of "key=value&key=value..." in PayFast's documented field order, then "&passphrase=..." */
export function pfSignature(pairs, passphrase, encode = pfEnc) {
  let s = pairs.map(([k, v]) => k + '=' + encode(v)).join('&');
  if (passphrase) s += '&passphrase=' + encode(passphrase);
  return pfMd5(s);
}
export const payfastReady = env => !!(env.PAYFAST_MERCHANT_ID && env.PAYFAST_MERCHANT_KEY && env.SUPABASE_URL && env.SUPABASE_SECRET);
const pfHost = env => (env.PAYFAST_SANDBOX === '1' || env.PAYFAST_SANDBOX === 'true') ? 'sandbox.payfast.co.za' : 'www.payfast.co.za';
const PF_MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const pfLabel = m => { const [y, mm] = String(m || '').split('-'); return ((PF_MONTHS[+mm - 1] || '') + ' ' + (y || '')).trim(); };
async function pfRpc(env, fn, args) {
  const r = await fetch(env.SUPABASE_URL + '/rest/v1/rpc/' + fn, { method: 'POST', headers: supaHeaders(env), body: JSON.stringify(args) });
  const t = await r.text(); let data = null; try { data = JSON.parse(t); } catch (e) { /* not json */ }
  return { ok: r.ok, status: r.status, data, text: t };
}
async function payStart(b, env, origin) {
  const id = String((b && b.intentId) || '');
  if (!/^pi[0-9a-f]{32}$/.test(id)) return [{ error: 'bad payment id' }, 400];
  const g = await pfRpc(env, 'pay_intent_get', { p_id: id });
  if (!g.ok) return [{ error: 'Could not read the payment (' + g.status + ')' }, 502];
  const it = g.data;
  if (!it || !it.id) return [{ error: 'Payment not found' }, 404];
  if (it.status === 'paid') return [{ error: 'This payment is already done', status: 'paid' }, 409];
  if (it.status !== 'pending' || it.method !== 'card') return [{ error: 'This payment was cancelled. Start a new one.', status: it.status }, 409];
  const app = String(env.APP_URL || 'https://cyiber069.github.io/Enivel/').split('#')[0];
  const fam = Number(it.families) || 0, kids = Number(it.kids) || 0;
  const fields = [
    ['merchant_id', env.PAYFAST_MERCHANT_ID], ['merchant_key', env.PAYFAST_MERCHANT_KEY],
    ['return_url', app + '#paid=' + id], ['cancel_url', app + '#paycancel=' + id], ['notify_url', origin + '/pay/itn'],
    ['m_payment_id', id], ['amount', Number(it.amount).toFixed(2)],
    ['item_name', 'Enivel Pays ' + pfLabel(it.month)],
    ['item_description', `School transport for ${fam} ${fam === 1 ? 'family' : 'families'}, ${kids} ${kids === 1 ? 'child' : 'children'}`]
  ].map(([k, v]) => [k, String(v ?? '').trim()]).filter(([, v]) => v !== '');
  const fieldsOut = Object.fromEntries(fields);
  fieldsOut.signature = pfSignature(fields, env.PAYFAST_PASSPHRASE);
  return [{ action: 'https://' + pfHost(env) + '/eng/process', fields: fieldsOut, sandbox: pfHost(env).startsWith('sandbox') }, 200];
}
async function payItn(req, env) {
  const all = [...new URLSearchParams(await req.text())];
  const at = all.findIndex(([k]) => k === 'signature');
  if (at < 0) return ['missing signature', 400];
  const sig = String(all[at][1] || '').toLowerCase();
  const signed = all.slice(0, at); // like PayFast's PHP sample: every field before the signature, in the order received
  if (new Set(signed.map(([k]) => k)).size !== signed.length) return ['duplicate fields', 400];
  if (![pfEnc, pfEncJs].some(enc => safeEqual(pfSignature(signed, env.PAYFAST_PASSPHRASE, enc), sig))) return ['bad signature', 400];
  const d = Object.fromEntries(signed);
  if (String(d.merchant_id || '') !== String(env.PAYFAST_MERCHANT_ID)) return ['wrong merchant', 400];
  const id = String(d.m_payment_id || '');
  if (!/^pi[0-9a-f]{32}$/.test(id)) return ['bad payment id', 400];
  const g = await pfRpc(env, 'pay_intent_get', { p_id: id });
  if (!g.ok) return ['lookup failed', 502];
  if (!g.data || !g.data.id) return ['unknown payment', 400];
  if (g.data.status === 'paid') return ['OK already paid', 200];
  if (d.payment_status !== 'COMPLETE') return ['OK not complete', 200];
  const gross = Number(d.amount_gross);
  if (!Number.isFinite(gross) || Math.abs(gross - Number(g.data.amount)) > 0.009) return ['amount mismatch', 400];
  const v = await fetch('https://' + pfHost(env) + '/eng/query/validate', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: signed.map(([k, val]) => k + '=' + pfEnc(val)).join('&') });
  if (!v.ok || (await v.text()).trim() !== 'VALID') return ['not confirmed by PayFast', 400];
  const c = await pfRpc(env, 'pay_intent_complete', { p_id: id, p_pf_payment_id: String(d.pf_payment_id || ''), p_amount: gross });
  if (!c.ok) return ['could not record the payment (' + c.status + ')', 500]; // PayFast sends the notice again later
  return ['OK ' + c.data, 200];
}
async function payRoute(req, env, url) {
  if (!payfastReady(env)) return json(env, { error: 'Card payments are not set up on the Enivel Worker yet (PayFast settings missing).' }, 503);
  if (url.pathname === '/pay/start') {
    if (env.LIMITS && !(await allow(env, 'pay:' + (req.headers.get('CF-Connecting-IP') || 'x'), 30, 600))) return json(env, { error: 'Too many attempts. Try again later.' }, 429);
    let b; try { b = await req.json(); } catch { return json(env, { error: 'bad json' }, 400); }
    const [out, st] = await payStart(b, env, url.origin);
    return json(env, out, st);
  }
  if (url.pathname === '/pay/itn') {
    let r; try { r = await payItn(req, env); } catch (e) { r = ['error', 500]; }
    return new Response(r[0], { status: r[1], headers: { 'Content-Type': 'text/plain' } });
  }
  return json(env, { error: 'not found' }, 404);
}
/* ===== end PayFast (pays) ===== */

export default {
  async fetch(req, env) {
    if (req.method === 'OPTIONS') return new Response(null, { headers: cors(env) });
    const url = new URL(req.url);
    if (req.method === 'GET' && url.pathname === '/health') return json(env, { ok: true, sms: !!env.BULKSMS_TOKEN, limits: !!env.LIMITS, reminders: !!(env.SUPABASE_SECRET && env.VAPID_PRIVATE_JWK), faceid: !!(env.SUPABASE_SECRET && env.OTP_SECRET), parentPush: pushReady(env), payfast: payfastReady(env) });
    if (req.method !== 'POST') return json(env, { error: 'POST only' }, 405);
    if (url.pathname.startsWith('/pay/')) return payRoute(req, env, url); // PayFast (pays)
    let body; try { body = await req.json(); } catch { return json(env, { error: 'bad json' }, 400); }
    if (url.pathname === '/passkey/challenge') return json(env, await passkeyChallenge(env));
    if (url.pathname === '/passkey/login') {
      if (env.LIMITS && !(await allow(env, 'pk:' + (req.headers.get('CF-Connecting-IP') || 'x'), 30, 600))) return json(env, { error: 'Too many attempts. Try again later.' }, 429);
      const r = await passkeyLogin(body, env); return json(env, r, r.error ? 400 : 200);
    }
    if (url.pathname === '/push/notify') {
      // no sign-in needed: it can only deliver a real, fresh notification once, to the person it is for
      const id = String((body && body.id) || '');
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) return json(env, { error: 'bad id' }, 400);
      if (!pushReady(env)) return json(env, { error: 'Pop-ups are not set up yet' }, 503);
      if (!env.LIMITS) return json(env, { error: 'Rate limiting is not set up (add the LIMITS KV binding)' }, 503);
      const ip = req.headers.get('CF-Connecting-IP') || 'unknown';
      if (!(await allow(env, 'pn:' + ip, 120, 600)) || !(await allow(env, 'pid:' + id, 3, 600))) return json(env, { error: 'Too many requests. Try again later.' }, 429);
      const r = await notifPush(id, env);
      return json(env, r, r.error ? 502 : 200);
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
  async scheduled(event, env, ctx) { ctx.waitUntil(Promise.all([runReminders(env), runNotifs(env)])); }
};
