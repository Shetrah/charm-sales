const CACHE = 'charm-hub-shell-v2-2-0-notifications';
const SHELL = '/';

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE).map(key => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  if (['/auth/', '/rest/', '/storage/', '/functions/'].some(prefix => url.pathname.startsWith(prefix))) return;

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then(response => {
          if (response.ok) {
            const copy = response.clone();
            caches.open(CACHE).then(cache => cache.put(SHELL, copy)).catch(() => {});
          }
          return response;
        })
        .catch(async () => (await caches.match(SHELL)) || Response.error()),
    );
    return;
  }

  event.respondWith(
    caches.match(request).then(cached => cached || fetch(request).then(response => {
      if (response.ok && response.type === 'basic') {
        const copy = response.clone();
        caches.open(CACHE).then(cache => cache.put(request, copy)).catch(() => {});
      }
      return response;
    })),
  );
});

self.addEventListener('push', event => {
  let payload = {};
  try { payload = event.data ? event.data.json() : {}; } catch { payload = { body: event.data?.text() || '' }; }
  const title = payload.title || 'Charm Company Hub';
  const options = {
    body: payload.body || 'You have a new work update.',
    icon: '/assets/icon-192.png',
    badge: '/assets/icon-192.png',
    tag: payload.tag || 'charm-work-update',
    data: { url: payload.url || '/' },
    renotify: false,
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || '/', self.location.origin).href;
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(clients => {
    const existing = clients.find(client => client.url.startsWith(self.location.origin));
    return existing ? existing.navigate(target).then(() => existing.focus()) : self.clients.openWindow(target);
  }));
});
