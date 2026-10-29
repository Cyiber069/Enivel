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
    if (req.method === 'GET' && url.pathname === '/health') return json(env, { ok: true, sms: !!env.BULKSMS_TOKEN, reminders: !!(env.SUPABASE_SECRET && env.VAPID_PRIVATE_JWK) });
    if (req.method !== 'POST') return json(env, { error: 'POST only' }, 405);
    let body; try { body = await req.json(); } catch { return json(env, { error: 'bad json' }, 400); }
    const phone = String(body.phone || '').replace(/[\s\-()]/g, '');
    if (!validZA(phone)) return json(env, { error: 'South African cellphone in +27 format required' }, 400);
    if (url.pathname === '/send') {
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
      if (!/^\d{6}$/.test(String(code || ''))) return json(env, { ok: false, reason: 'format' });
      if (Date.now() > Number(exp)) return json(env, { ok: false, reason: 'expired' });
      return json(env, { ok: (await hmac(env.OTP_SECRET, `${phone}|${code}|${exp}`)) === token });
    }
    return json(env, { error: 'not found' }, 404);
  },
  async scheduled(event, env, ctx) { ctx.waitUntil(runReminders(env)); }
};
