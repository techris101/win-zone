// WIN ZONE service worker: shows tournament notifications on the phone, even when the site is closed.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { title: "WIN ZONE", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "WIN ZONE", {
    body: d.body || "",
    tag: d.id || d.tag || "winzone",
    data: { url: d.url || "/me.html", tid: d.tid || null },
    icon: "/assets/icon-192.png",
    badge: "/assets/badge-72.png",
    actions: (d.actions || []).slice(0, 2),
  }));
});

self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const { url, tid } = e.notification.data || {};
  let target = url || "/me.html";
  if ((e.action === "follow" || e.action === "stop") && tid) {
    target = `/me.html?t=${encodeURIComponent(tid)}&follow=${e.action === "follow" ? 1 : 0}#notifications`;
  }
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const w of wins) {
      if ("focus" in w) { try { await w.navigate(target); } catch (_) {} return w.focus(); }
    }
    return self.clients.openWindow(target);
  })());
});
