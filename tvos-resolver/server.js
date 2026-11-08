#!/usr/bin/env node
// Kazumi TV companion resolver.
//
// Apple TV has no WebView, so pages whose video address is produced by
// JavaScript cannot be resolved on the TV itself. This small service loads the
// episode page in headless Chromium, using the same detection hooks as the
// Kazumi app, and returns the media URL to the TV.
//
//   POST /resolve  {"url": "...", "legacy": false, "userAgent": "...", "timeoutMs": 30000}
//   -> 200 {"url": "https://.../index.m3u8", "kind": "m3u8", "frame": "https://...", "userAgent": "..."}
//   GET  /health   -> {"ok": true, "version": "..."}
//
// Environment: PORT (default 8787), HOST (default 0.0.0.0), RESOLVER_TOKEN
// (optional shared secret, sent by the TV as "Authorization: Bearer <token>"),
// MAX_PAGES (default 3), CHROMIUM_PATH (optional browser binary).

'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const VERSION = '0.1.0';
const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || '0.0.0.0';
const TOKEN = process.env.RESOLVER_TOKEN || '';
const MAX_PAGES = Math.max(1, Number(process.env.MAX_PAGES || 3));
const INJECT = fs.readFileSync(path.join(__dirname, 'inject.js'), 'utf8');

const DEFAULT_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

// Same blocklist as Kazumi's content blockers.
const BLOCKED = [/devtools-detector\.js/i, /googleads/i, /googlesyndication\.com/i, /prestrain(\.|%2E)html/i, /adtrafficquality/i];

let browserPromise = null;
function getBrowser() {
  if (!browserPromise) {
    const opts = { headless: true, args: ['--autoplay-policy=no-user-gesture-required', '--mute-audio'] };
    if (process.env.CHROMIUM_PATH) opts.executablePath = process.env.CHROMIUM_PATH;
    browserPromise = chromium.launch(opts).then((b) => {
      b.on('disconnected', () => { browserPromise = null; });
      return b;
    }, (e) => { browserPromise = null; throw e; });
  }
  return browserPromise;
}

let active = 0;
const waiters = [];
async function acquire() {
  if (active < MAX_PAGES) { active++; return; }
  await new Promise((r) => waiters.push(r));
  active++;
}
function release() { active--; const w = waiters.shift(); if (w) w(); }

// Port of decodeVideoSource() from lib/utils/media.dart: pull a direct media
// URL out of an iframe's query string when the player passes it through.
function decodeVideoSource(iframeUrl) {
  const re = /(https?:\/\/.*?\.m3u8)|(https?:\/\/.*?\.mp4)/i;
  try {
    const u = new URL(decodeURI(iframeUrl));
    for (const [, v] of u.searchParams) if (re.test(v)) return v;
  } catch (_) {}
  return null;
}

const isMediaUrl = (u) => /\.m3u8(\?|#|$)|\.mp4(\?|#|$)/i.test(u);

async function resolve({ url, legacy = false, userAgent, timeoutMs = 30000 }) {
  const ua = userAgent || DEFAULT_UA;
  await acquire();
  const browser = await getBrowser().catch((e) => { release(); throw e; });
  const context = await browser.newContext({ userAgent: ua, ignoreHTTPSErrors: true, viewport: { width: 1280, height: 720 } });
  try {
    let done;
    const result = new Promise((r) => { done = r; });
    let settled = false;
    const finish = (kind, mediaUrl, frame) => {
      if (settled || !mediaUrl || !/^https?:/i.test(mediaUrl) && !mediaUrl.startsWith('//')) return;
      settled = true;
      if (mediaUrl.startsWith('//')) mediaUrl = 'https:' + mediaUrl;
      done({ url: mediaUrl, kind, frame, userAgent: ua });
    };

    await context.route('**/*', (route) => {
      const req = route.request();
      const t = req.resourceType();
      if (t === 'image' || t === 'font' || BLOCKED.some((re) => re.test(req.url()))) return route.abort();
      return route.continue();
    });

    if (legacy) {
      // Legacy rules: the playable address is an iframe src (possibly with the
      // media URL in its query string).
      context.on('page', () => {});
    } else {
      await context.exposeBinding('__kazumiReport', (source, kind, mediaUrl, frameUrl) => {
        if (String(mediaUrl).includes('about:blank')) return;
        finish(kind, mediaUrl, frameUrl);
      });
      await context.addInitScript({ content: INJECT });
    }

    const page = await context.newPage();
    if (!legacy) {
      // Network-level fallback: playlists fetched by <video> or by workers do not
      // pass through the JS hooks.
      page.on('response', async (resp) => {
        try {
          const ct = (resp.headers()['content-type'] || '').toLowerCase();
          const u = resp.url();
          if (ct.includes('mpegurl') || /\.m3u8(\?|#|$)/i.test(u)) {
            const body = await resp.text().catch(() => '');
            if (body.trim().startsWith('#EXTM3U')) finish('m3u8', u, resp.frame()?.url());
          } else if (ct.startsWith('video/mp4') && resp.request().resourceType() === 'media') {
            finish('video', u, resp.frame()?.url());
          }
        } catch (_) {}
      });
    } else {
      const scanFrames = () => {
        for (const f of page.frames()) {
          const src = f.url();
          if (f === page.mainFrame() || !src || src === 'about:blank') continue;
          if (BLOCKED.some((re) => re.test(src))) continue;
          const decoded = decodeVideoSource(src);
          if (decoded) finish('iframe', decoded, src);
        }
      };
      page.on('frameattached', scanFrames);
      page.on('framenavigated', scanFrames);
    }

    page.goto(url, { waitUntil: 'domcontentloaded', timeout: timeoutMs }).catch(() => {});
    const timer = new Promise((r) => setTimeout(() => r(null), timeoutMs));
    const out = await Promise.race([result, timer]);
    if (!out) {
      const err = new Error('Timed out without finding a video source');
      err.status = 504;
      throw err;
    }
    return out;
  } finally {
    context.close().catch(() => {});
    release();
  }
}

function send(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

const server = http.createServer((req, res) => {
  if (TOKEN && req.headers.authorization !== `Bearer ${TOKEN}`) return send(res, 401, { error: 'unauthorized' });
  if (req.method === 'GET' && req.url === '/health') return send(res, 200, { ok: true, version: VERSION });
  if (req.method !== 'POST' || req.url !== '/resolve') return send(res, 404, { error: 'not found' });
  let raw = '';
  req.on('data', (c) => { raw += c; if (raw.length > 1e5) req.destroy(); });
  req.on('end', async () => {
    let input;
    try { input = JSON.parse(raw || '{}'); } catch (_) { return send(res, 400, { error: 'invalid json' }); }
    if (!input.url || !/^https?:\/\//i.test(input.url)) return send(res, 400, { error: 'url required' });
    const timeoutMs = Math.min(Math.max(Number(input.timeoutMs) || 30000, 3000), 90000);
    const started = Date.now();
    try {
      const out = await resolve({ url: input.url, legacy: !!input.legacy, userAgent: input.userAgent, timeoutMs });
      console.log(`[resolve] ok ${Date.now() - started}ms ${input.url} -> ${out.url}`);
      send(res, 200, out);
    } catch (e) {
      console.log(`[resolve] fail ${Date.now() - started}ms ${input.url}: ${e.message}`);
      send(res, e.status || 502, { error: e.message });
    }
  });
});

if (require.main === module) {
  server.listen(PORT, HOST, () => console.log(`Kazumi TV resolver ${VERSION} listening on http://${HOST}:${PORT}`));
  const shutdown = async () => { server.close(); if (browserPromise) (await browserPromise).close().catch(() => {}); process.exit(0); };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

module.exports = { resolve, decodeVideoSource, isMediaUrl, server };
