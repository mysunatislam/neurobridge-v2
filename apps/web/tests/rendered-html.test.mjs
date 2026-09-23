import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(new Request("http://localhost/", { headers: { accept: "text/html" } }), {
    ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) },
  }, { waitUntil() {}, passThroughOnException() {} });
}

test("server-renders the finished FingerSpeak application", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /<title>FingerSpeak/);
  assert.match(html, /You’re not alone\. Asha is right here/);
  assert.match(html, /asha-avatar-(?:face\.webp|new\.png)/);
  assert.match(html, /Pi Display/);
  assert.match(html, /Caregiver/);
  assert.match(html, /PATIENT COMPANION/);
  assert.doesNotMatch(html, /codex-preview|Building your site|react-loading-skeleton/);
  assert.match(response.headers.get("content-security-policy") ?? "", /default-src 'self'/);
  assert.equal(response.headers.get("permissions-policy"), "camera=(self), microphone=(self), geolocation=()");
});

test("production service worker updates navigation HTML and keeps an offline shell", async () => {
  const source = await readFile(new URL("../dist/client/sw.js", import.meta.url), "utf8");
  assert.match(source, /fingerspeak-edge-v6/);
  assert.match(source, /asha-avatar-face\.webp/);
  assert.match(source, /models\/hand_landmarker\.task/);
  assert.match(source, /request\.mode === "navigate"/);
  assert.match(source, /cache\.put\("\/", response\.clone\(\)\)/);
  assert.match(source, /caches\.match\("\/"\)/);
  assert.match(source, /isPinnedEdgeAsset \|\| isVersionedBuildAsset/);
  assert.match(source, /API, auth, profile/);
});
