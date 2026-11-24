/* JALEO · service worker per a les notificacions dels avisos */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'JALEO', {
    body: d.body || '',
    icon: '/img/icon-192.png',
    badge: '/img/badge-96.png',
    data: { url: d.url || '/?v=avisos' }
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || '/?v=avisos';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(ws => {
    for (const w of ws) { if ('focus' in w) { if ('navigate' in w) w.navigate(url); return w.focus(); } }
    return self.clients.openWindow(url);
  }));
});
