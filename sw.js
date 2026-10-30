/* Enivel service worker: pop-ups even when the app is closed.
   - driver pickup reminders (tag = reminder key, url = route id) with Start trip / Open buttons
   - parent & kid alerts (tag 'n-<notification id>', url = app screen): driver nearby, picked up,
     dropped off, driver outside, running late, emergency */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
const isAlert = d => typeof d.tag === 'string' && d.tag.startsWith('n-');
self.addEventListener('push', e => {
  e.waitUntil((async () => {
    let d = {};
    try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: 'Enivel', body: e.data ? e.data.text() : '' }; }
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // App open on screen: it shows its own card / pop-up (and syncs at once).
    if (wins.some(w => w.visibilityState === 'visible')) { wins.forEach(w => w.postMessage({ enivel: 'reminder', d })); return; }
    const alert = isAlert(d);
    const actions = alert ? [{ action: 'open', title: 'Open Enivel' }]
      : d.url ? [{ action: 'start', title: 'Start trip' }, { action: 'open', title: 'Open Enivel' }] : [{ action: 'open', title: 'Open Enivel' }];
    await self.registration.showNotification(d.title || 'Enivel', {
      body: d.body || '', tag: d.tag || 'enivel', renotify: true, requireInteraction: !alert || /🚨/.test(d.title || ''),
      vibrate: alert && /🚨/.test(d.title || '') ? [300, 100, 300, 100, 300] : [200, 100, 200],
      data: { url: d.url || '', go: alert }, actions
    });
  })());
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const data = e.notification.data || {};
  const route = data.url || '';
  const target = new URL(self.registration.scope);
  if (route) target.hash = data.go ? 'go-' + route : (e.action === 'start' ? 'start-' : 'trip-') + route;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) {
      if (w.url.startsWith(self.registration.scope)) { await w.focus(); w.postMessage({ enivel: 'open', hash: target.hash }); return; }
    }
    await self.clients.openWindow(target.href);
  })());
});
