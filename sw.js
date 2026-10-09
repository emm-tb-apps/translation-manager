/* Translation Manager service worker.
   - Page loads are network-first, so a new deploy shows up on the next open; the cached
     copy is the offline fallback.
   - Static assets (icons, manifest, fonts, supabase-js) are stale-while-revalidate.
   - Supabase API and auth traffic is never cached.
   Bump VERSION whenever the list of shell files changes. */
const VERSION = "tm-v3";
const SHELL = [
  "./",
  "./signin.html",
  "./config.js",
  "./manifest.webmanifest",
  "./icons/icon.svg",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/maskable-512.png",
  "./icons/apple-touch-icon.png"
];
const CDN = [
  "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/dist/umd/supabase.min.js"
];
const STATIC_HOSTS = ["fonts.googleapis.com", "fonts.gstatic.com", "cdn.jsdelivr.net"];
const APP_PAGE = new URL("./", self.registration.scope).href;

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(VERSION);
    await cache.addAll(SHELL);
    // the CDN copy is a nice-to-have; a failure here mustn't block installing
    await Promise.allSettled(CDN.map((u) => cache.add(new Request(u, { mode: "cors" }))));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.hostname.endsWith(".supabase.co")) return;          // live data + auth: always network

  if (req.mode === "navigate") {
    event.respondWith(networkFirstPage(req));
    return;
  }
  if (url.origin === self.location.origin || STATIC_HOSTS.includes(url.hostname)) {
    event.respondWith(staleWhileRevalidate(event, req));
  }
});

async function networkFirstPage(req) {
  const cache = await caches.open(VERSION);
  const url = new URL(req.url);
  const key = url.origin + url.pathname;                       // one copy per page, whatever the query/hash
  try {
    const res = await fetch(req);
    if (res.ok && !res.redirected) cache.put(key, res.clone());
    return res;
  } catch (err) {
    return (await cache.match(key)) || (await cache.match(APP_PAGE)) || Response.error();
  }
}

async function staleWhileRevalidate(event, req) {
  const cache = await caches.open(VERSION);
  const cached = await cache.match(req);
  const update = fetch(req).then((res) => {
    if (res.ok || res.type === "opaque") cache.put(req, res.clone());
    return res;
  }).catch(() => cached);
  if (cached) {
    event.waitUntil(update);
    return cached;
  }
  return update;
}
