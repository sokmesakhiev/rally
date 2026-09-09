/* Rally service worker — web push only.
 *
 * Deliberately NOT a caching/offline service worker. It registers no fetch
 * handler at all, so it never intercepts navigation or asset requests. That
 * matters: this app is a prerendered SPA served from CloudFront, and a caching
 * service worker here would add a second, independent cache layer in front of
 * one we already have to reason about — with its own invalidation story and
 * its own way of pinning users to a stale bundle.
 *
 * Lives in public/ so Vite copies it verbatim to the root of dist/client/. It
 * MUST be served from the origin root: a service worker's default scope is its
 * own directory, so /assets/sw.js could only control /assets/*.
 *
 * DEPLOYMENT: this file must be served with `Cache-Control: no-cache`. It is
 * the one file CloudFront must always revalidate — browsers re-fetch the
 * worker to check for updates, and a cached copy means a worker that can never
 * be replaced. See docs/PUSH-NOTIFICATIONS.md.
 */

// Take over immediately rather than waiting for every existing tab to close.
// Safe here precisely because there's no fetch handler: there is no in-flight
// request whose semantics could change mid-session.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  if (!event.data) return;

  // A malformed or non-JSON payload must not throw here — an uncaught error in
  // a push handler can get the whole worker torn down, taking future
  // notifications with it.
  let payload;
  try {
    payload = event.data.json();
  } catch {
    payload = { title: "Rally", body: event.data.text() };
  }

  const title = payload.title || "Rally";

  // Tell any open tab that something arrived, so the header bell updates now
  // rather than on its next poll. This is the whole "real time" story for the
  // badge: the push already travels server → browser, so a tab that's open
  // just needs to hear about it.
  //
  // Best-effort by design. A tab that's closed, or a user who never granted
  // notification permission, simply falls back to the 60s poll — which is why
  // the poll exists rather than being replaced by this.
  event.waitUntil(
    self.clients
      .matchAll({ type: "window", includeUncontrolled: true })
      .then((clients) => {
        for (const client of clients) {
          client.postMessage({ type: "rally:notification", tag: payload.tag });
        }
      })
      .catch(() => {}),
  );

  event.waitUntil(
    self.registration.showNotification(title, {
      body: payload.body || "",
      icon: "/icon-192.png",
      badge: "/icon-192.png",
      // Collapses repeats: a second notification with the same tag replaces
      // the first instead of stacking. Set server-side per registration.
      tag: payload.tag,
      data: { url: payload.url || "/" },
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = new URL(event.notification.data?.url || "/", self.location.origin).href;

  // Focus an existing tab rather than opening a duplicate — someone who
  // already has Rally open should not end up with two copies of it.
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if (client.url === target && "focus" in client) return client.focus();
      }
      return self.clients.openWindow(target);
    }),
  );
});

// Chrome can rotate a subscription without the page being open. Without this
// the old endpoint keeps 410-ing server-side and the user silently stops
// receiving anything. We can't call our own authenticated API from here (no
// session), so the page re-syncs on next load — see usePushNotifications.
self.addEventListener("pushsubscriptionchange", () => {
  self.registration.unregister();
});
