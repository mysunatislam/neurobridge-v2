const CACHE = "fingerspeak-v2-edge-v9";
const EDGE_ASSETS = [
  "/neurobridge-v2/",
  "/neurobridge-v2/favicon.svg",
  "/neurobridge-v2/asha-avatar-face.webp",
  "/neurobridge-v2/og.png",
  "/neurobridge-v2/manifest.webmanifest",
  "/neurobridge-v2/models/hand_landmarker.task",
  "/neurobridge-v2/mediapipe/wasm/vision_wasm_internal.js",
  "/neurobridge-v2/mediapipe/wasm/vision_wasm_internal.wasm",
  "/neurobridge-v2/mediapipe/wasm/vision_wasm_nosimd_internal.js",
  "/neurobridge-v2/mediapipe/wasm/vision_wasm_nosimd_internal.wasm"
];

function isVersionedBuildAsset(pathname) {
  return pathname.startsWith("/neurobridge-v2/assets/") || pathname.startsWith("/neurobridge-v2/_next/static/");
}

async function precacheApplicationShell() {
  const cache = await caches.open(CACHE);
  const shellResponse = await fetch("/neurobridge-v2/", { cache: "reload" });
  if (!shellResponse.ok) throw new Error("Could not fetch the FingerSpeak application shell.");
  const html = await shellResponse.clone().text();
  await cache.put("/neurobridge-v2/", shellResponse);
  const buildAssets = new Set();
  for (const match of html.matchAll(/(?:src|href)=["']([^"'#]+)["']/g)) {
    const url = new URL(match[1], self.location.origin);
    if (url.origin === self.location.origin && isVersionedBuildAsset(url.pathname)) buildAssets.add(url.pathname);
  }
  await cache.addAll([...EDGE_ASSETS.filter((path) => path !== "/neurobridge-v2/"), ...buildAssets]);
}

self.addEventListener("install", (event) => {
  event.waitUntil(precacheApplicationShell().then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)))));
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const request = event.request;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // Navigation HTML is network-first so a newly deployed client bundle never
  // hydrates against an older cached shell. The last verified shell remains an
  // offline fallback for the wheelchair's local-first communication surface.
  if (request.mode === "navigate") {
    event.respondWith(fetch(request).then(async (response) => {
      if (response.ok && response.type === "basic") {
        await caches.open(CACHE).then((cache) => cache.put("/neurobridge-v2/", response.clone()));
      }
      return response;
    }).catch(() => caches.match("/neurobridge-v2/").then((cached) => cached || Response.error())));
    return;
  }

  const isPinnedEdgeAsset = EDGE_ASSETS.includes(url.pathname);
  if (isPinnedEdgeAsset || isVersionedBuildAsset(url.pathname)) {
    event.respondWith(caches.match(request).then((cached) => cached || fetch(request).then(async (response) => {
      if (response.ok && response.type === "basic") {
        await caches.open(CACHE).then((cache) => cache.put(request, response.clone()));
      }
      return response;
    })));
    return;
  }

  // API, auth, profile, and other user-specific responses are always handled
  // by the network and are never written to shared service-worker storage.
});
