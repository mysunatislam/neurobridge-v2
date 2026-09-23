/**
 * Prerender the single-route FingerSpeak PWA (`/`) to a static bundle for
 * hosts without a server runtime (e.g. GitHub Pages project sites).
 *
 * Usage:
 *   npm run build
 *   node ./prerender-pages.mjs [outDir] [--base=/neurobridge-asha-face] [--serve-check]
 *
 * Output: <outDir>/index.html (+ client assets, 404.html, .nojekyll).
 *
 * --base rewrites root-absolute references (/_next, /models, /mediapipe,
 * /sw.js, manifest, service-worker cache keys) so the bundle works under a
 * Pages project subpath. --serve-check serves the bundle strictly under the
 * base path and fails if any local reference does not resolve (mimics Pages).
 *
 * The app is a single `/` route; all views switch client-side, so one
 * prerendered document plus the client bundle is a complete static site.
 */
import { cp, mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const flags = Object.fromEntries(
  process.argv.slice(2).filter((a) => a.startsWith("--")).map((a) => {
    const [key, value] = a.slice(2).split("=");
    return [key, value ?? true];
  }),
);
const outDir = path.resolve(here, args[0] ?? "./pages-dist");
const base = typeof flags.base === "string" && flags.base.startsWith("/") ? flags.base.replace(/\/$/, "") : "";

const workerUrl = new URL("./dist/server/index.js", import.meta.url);
workerUrl.searchParams.set("prerender", `${process.pid}-${Date.now()}`);

const { default: worker } = await import(workerUrl.href);
const response = await worker.fetch(
  new Request("http://localhost/", { headers: { accept: "text/html" } }),
  { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
  { waitUntil() {}, passThroughOnException() {} },
);
if (response.status !== 200) {
  throw new Error(`Prerender failed with status ${response.status}`);
}
let html = await response.text();
if (!html.includes("<title>FingerSpeak")) {
  throw new Error("Prerendered HTML is missing the FingerSpeak shell.");
}

await mkdir(outDir, { recursive: true });
await cp(path.join(here, "dist", "client"), outDir, { recursive: true });

/** Rewrite root-absolute "/..." refs to "{base}/..." (skips //external, />, and prose "/ "). */
const prefixRootAbsolute = (text) => text.replace(/(["'`(\s])\/(?=[a-zA-Z0-9_.~-])/g, `$1${base}/`);

async function collectFiles(dir, exts, out = []) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) await collectFiles(full, exts, out);
    else if (exts.some((ext) => entry.name.endsWith(ext))) out.push(full);
  }
  return out;
}

if (base) {
  html = prefixRootAbsolute(html);
  html = html.replace("<head>", `<head><base href="${base}/"/><script>if(location.pathname==="${base}")location.replace("${base}/"+location.search+location.hash);</script>`);
  html = html.replaceAll("css:/_next/", `css:${base}/_next/`);
  html = html.replaceAll('"pathname":"/"', `"pathname":"${base}/"`);

  // Service worker: cache keys, precache list, and path gates.
  const swPath = path.join(outDir, "sw.js");
  let sw = await readFile(swPath, "utf8");
  sw = prefixRootAbsolute(sw);
  sw = sw.replace(/(["'`])\/([\"'`])/g, `$1${base}/$2`);
  sw = sw.replace(/const CACHE = "[^"]+";/, `const CACHE = "fingerspeak-v2-edge-v8";`);
  sw = sw.replace('pathname.startsWith("/_next/static/")', `pathname.startsWith("${base}/_next/static/")`);
  sw = sw.replace('pathname.startsWith("/assets/")', `pathname.startsWith("${base}/assets/")`);
  await writeFile(swPath, sw);

  // App chunks reference /sw.js, /mediapipe/wasm, /models/*.task, and _next/static chunk arrays.
  for (const file of await collectFiles(path.join(outDir, "_next"), [".js", ".css"])) {
    let chunk = await readFile(file, "utf8");
    chunk = prefixRootAbsolute(chunk);
    chunk = chunk.replace(/(["'`])_next\//g, `$1${base}/_next/`);
    chunk = chunk.replaceAll('"pathname":"/"', `"pathname":"${base}/"`);
    await writeFile(file, chunk);
  }

  // Web manifest icons + start_url/scope.
  for (const file of await collectFiles(outDir, [".webmanifest"])) {
    let manifest = await readFile(file, "utf8");
    manifest = prefixRootAbsolute(manifest);
    manifest = manifest.replace(/"start_url":\s*"\/"/g, `"start_url": "${base}/"`);
    manifest = manifest.replace(/"scope":\s*"\/"/g, `"scope": "${base}/"`);
    await writeFile(file, manifest);
  }
}

await writeFile(path.join(outDir, "index.html"), html);
await writeFile(path.join(outDir, "404.html"), html);
await writeFile(path.join(outDir, ".nojekyll"), "");
console.log(`Pages bundle ready: ${outDir} (${html.length} bytes HTML, base="${base || "/"}")`);

// Residual root-absolute refs (excluding externals AND our own base prefix)
// must be zero for subpaths.
const baseName = base ? base.replace(/^\//, "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&") : null;
const residualPattern = baseName
  ? new RegExp(`(["'\`(\\s])\\/(?=[a-zA-Z0-9_.~-])(?!${baseName}\\/)`, "g")
  : /(["'`(\s])\/(?=[a-zA-Z0-9_.~-])/g;
const leftovers = new Set();
for (const file of [path.join(outDir, "index.html"), path.join(outDir, "sw.js")]) {
  const text = await readFile(file, "utf8");
  for (const match of text.matchAll(residualPattern)) {
    const start = match.index ?? 0;
    const snippet = text.slice(start + 1, start + 40).split(/["'`\s)]/)[0];
    if (snippet && !snippet.startsWith("http")) leftovers.add(`${path.basename(file)}: ${snippet}`);
  }
}
if (base && leftovers.size > 0) {
  console.log("WARNING: residual root-absolute references (break under subpath):");
  for (const ref of [...leftovers].slice(0, 20)) console.log(`  ${ref}`);
} else {
  console.log("No residual root-absolute references: subpath-safe.");
}

if (flags["serve-check"]) {
  const root = outDir;
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      let pathname = decodeURIComponent(url.pathname);
      if (base && !pathname.startsWith(`${base}/`) && pathname !== base) {
        res.writeHead(404); res.end("outside base");
        return;
      }
      if (base) pathname = pathname.slice(base.length) || "/";
      const file = path.join(root, pathname === "/" ? "index.html" : pathname);
      const data = await readFile(file);
      const type = file.endsWith(".html") ? "text/html" : file.endsWith(".js") ? "text/javascript"
        : file.endsWith(".css") ? "text/css" : file.endsWith(".json") ? "application/json" : "application/octet-stream";
      res.writeHead(200, { "content-type": type });
      res.end(data);
    } catch {
      res.writeHead(404); res.end("missing");
    }
  });
  await new Promise((resolve) => server.listen(8911, "127.0.0.1", resolve));
  const failures = [];
  async function check(urlPath) {
    const res = await fetch(`http://127.0.0.1:8911${urlPath}`);
    if (!res.ok) failures.push(`${urlPath} -> ${res.status}`);
    return res;
  }
  const index = await check(`${base}/`);
  const text = await index.text();
  const refs = new Set();
  for (const match of text.matchAll(/\s(?:src|href)="([^"]+)"/g)) {
    const ref = match[1];
    if (ref.startsWith(`${base}/`)) refs.add(ref);
    else if (!ref.startsWith("http") && !ref.startsWith("data:")) failures.push(`non-base ref: ${ref}`);
  }
  for (const ref of refs) await check(ref);
  // Service worker + manifest + hand models (camera needs these).
  for (const extra of ["sw.js", "manifest.webmanifest", "models/hand_landmarker.task"]) {
    await check(`${base}/${extra}`);
  }
  server.close();
  if (failures.length > 0) {
    console.log("SERVE-CHECK FAILED:");
    for (const failure of failures) console.log(`  ${failure}`);
    process.exit(1);
  }
  console.log(`SERVE-CHECK OK: index + ${refs.size} refs + shell assets resolve under ${base || "/"}.`);
}
