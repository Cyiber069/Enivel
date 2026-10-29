/* Enivel service worker: pickup reminders with buttons, even when the app is closed. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('push', e => {
  e.waitUntil((async () => {
    let d = {};
    try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: 'Enivel', body: e.data ? e.data.text() : '' }; }
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // App open on screen: it already shows its own reminder card.
    if (wins.some(w => w.visibilityState === 'visible')) { wins.forEach(w => w.postMessage({ enivel: 'reminder', d })); return; }
    const actions = d.url ? [{ action: 'start', title: 'Start trip' }, { action: 'open', title: 'Open Enivel' }] : [{ action: 'open', title: 'Open Enivel' }];
    await self.registration.showNotification(d.title || 'Enivel', {
      body: d.body || '', tag: d.tag || 'enivel', renotify: true, requireInteraction: true,
      vibrate: [200, 100, 200], data: { url: d.url || '' }, actions
    });
  })());
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const route = (e.notification.data || {}).url || '';
  const target = new URL(self.registration.scope);
  if (route) target.hash = (e.action === 'start' ? 'start-' : 'trip-') + route;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) {
      if (w.url.startsWith(self.registration.scope)) { await w.focus(); w.postMessage({ enivel: 'open', hash: target.hash }); return; }
    }
    await self.clients.openWindow(target.href);
  })());
});
