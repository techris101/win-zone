#!/usr/bin/env python3
"""Packs web/ into one Pages script (dist/_worker.js) that serves every file itself.
Used when uploading straight to Cloudflare Pages without the Git connection."""
import base64, json, os, sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "web")
TYPES = {"html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
         "css": "text/css; charset=utf-8", "json": "application/json", "webmanifest": "application/manifest+json",
         "svg": "image/svg+xml", "png": "image/png", "ico": "image/x-icon", "txt": "text/plain; charset=utf-8", "xml": "application/xml"}
files = {}
for root, _, names in os.walk(ROOT):
    for n in names:
        if n in ("_headers", "_redirects") or n.endswith(".test.mjs"):
            continue
        p = os.path.join(root, n)
        rel = "/" + os.path.relpath(p, ROOT).replace(os.sep, "/")
        ext = n.rsplit(".", 1)[-1].lower()
        data = open(p, "rb").read()
        files[rel] = [TYPES.get(ext, "application/octet-stream"), base64.b64encode(data).decode()]

# security headers: same as web/_headers
csp = None
for line in open(os.path.join(ROOT, "_headers")):
    if line.strip().startswith("Content-Security-Policy:"):
        csp = line.split(":", 1)[1].strip()

js = """const FILES = %s;
const SEC = {"X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Referrer-Policy": "strict-origin-when-cross-origin",
  "Permissions-Policy": "camera=(), microphone=(), geolocation=()", "Content-Security-Policy": %s};
const cache = new Map();
function body(p) { if (!cache.has(p)) cache.set(p, Uint8Array.from(atob(FILES[p][1]), c => c.charCodeAt(0))); return cache.get(p); }
function find(path) {
  if (FILES[path]) return path;
  if (path.endsWith("/") && FILES[path + "index.html"]) return path + "index.html";
  if (FILES[path + ".html"]) return path + ".html";
  if (FILES[path + "/index.html"]) return path + "/index.html";
  if (path.startsWith("/t/")) return "/t/index.html";
  if (path.startsWith("/p/")) return "/p/index.html";
  return null;
}
export default {
  async fetch(req) {
    const url = new URL(req.url);
    let path; try { path = decodeURIComponent(url.pathname); } catch { path = url.pathname; }
    const hit = find(path);
    const p = hit || "/404.html";
    const h = new Headers(SEC);
    h.set("Content-Type", FILES[p][0]);
    if (/^\\/(js|css)\\//.test(p)) h.set("Cache-Control", "public, max-age=300");
    else if (p.endsWith(".html") || p === "/sw.js") h.set("Cache-Control", "no-cache");
    else h.set("Cache-Control", "public, max-age=86400");
    return new Response(req.method === "HEAD" ? null : body(p), { status: hit ? 200 : 404, headers: h });
  }
};
""" % (json.dumps(files, separators=(",", ":")), json.dumps(csp))
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "..", "dist", "_worker.js")
os.makedirs(os.path.dirname(out), exist_ok=True)
open(out, "w").write(js)
print(out, len(js), "bytes,", len(files), "files")
