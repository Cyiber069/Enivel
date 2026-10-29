/**
 * Enivel OTP SMS Worker (Cloudflare Workers, free tier)
 * Sends one-time codes by SMS through BulkSMS (https://www.bulksms.com, South Africa).
 *
 * Secrets to set in the Worker (Settings → Variables → Secrets):
 *   BULKSMS_TOKEN   = base64 of "username:password" from your BulkSMS account (or an API token id:secret)
 *   OTP_SECRET      = any long random string (signs the codes so the Worker needs no database)
 * Variables:
 *   ALLOWED_ORIGIN  = the exact origin of the hosted Enivel app, e.g. https://enivel.netlify.app
 *   SENDER          = optional sender id (BulkSMS may need approval), default "Enivel"
 *
 * Endpoints:
 *   POST /send   {phone:"+27721234567"}                    → {token, exp}
 *   POST /check  {phone, code:"123456", token, exp}        → {ok:true|false}
 */
const CODE_TTL_MS = 5 * 60 * 1000;

async function hmac(secret, msg) {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map(b => b.toString(16).padStart(2, '0')).join('');
}
function cors(env, extra = {}) {
  return { 'Access-Control-Allow-Origin': env.ALLOWED_ORIGIN || '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type', 'Content-Type': 'application/json', ...extra };
}
const json = (env, obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: cors(env) });
const validZA = p => /^\+27[6-8]\d{8}$/.test(p);

export default {
  async fetch(req, env) {
    if (req.method === 'OPTIONS') return new Response(null, { headers: cors(env) });
    if (req.method !== 'POST') return json(env, { error: 'POST only' }, 405);
    const url = new URL(req.url);
    let body; try { body = await req.json(); } catch { return json(env, { error: 'bad json' }, 400); }
    const phone = String(body.phone || '').replace(/[\s\-()]/g, '');
    if (!validZA(phone)) return json(env, { error: 'South African cellphone in +27 format required' }, 400);

    if (url.pathname === '/send') {
      const code = String(Math.floor(100000 + Math.random() * 900000));
      const exp = Date.now() + CODE_TTL_MS;
      const token = await hmac(env.OTP_SECRET, `${phone}|${code}|${exp}`);
      const r = await fetch('https://api.bulksms.com/v1/messages', {
        method: 'POST',
        headers: { Authorization: 'Basic ' + env.BULKSMS_TOKEN, 'Content-Type': 'application/json' },
        body: JSON.stringify({ to: phone, from: env.SENDER || 'Enivel', body: `Enivel code: ${code}. It expires in 5 minutes. Never share it.` })
      });
      if (!r.ok) return json(env, { error: 'SMS provider error ' + r.status, detail: await r.text() }, 502);
      return json(env, { token, exp });
    }
    if (url.pathname === '/check') {
      const { code, token, exp } = body;
      if (!/^\d{6}$/.test(String(code || ''))) return json(env, { ok: false, reason: 'format' });
      if (Date.now() > Number(exp)) return json(env, { ok: false, reason: 'expired' });
      const expect = await hmac(env.OTP_SECRET, `${phone}|${code}|${exp}`);
      return json(env, { ok: expect === token });
    }
    return json(env, { error: 'not found' }, 404);
  }
};
