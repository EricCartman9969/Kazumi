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

const VERSION = '0.2.0';
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

    if (!legacy) {
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

    // Some players only request the playlist after a play gesture. Nudge every
    // frame a few times: call play() on <video> and click common play buttons.
    const nudge = async () => {
      for (const f of page.frames()) {
        await f.evaluate(() => {
          document.querySelectorAll('video').forEach((v) => { try { v.muted = true; v.play().catch(() => {}); } catch (_) {} });
          const sel = '.dplayer-mobile-play, .dplayer-play-icon, .vjs-big-play-button, .art-control-play, .prism-big-play-btn, .xgplayer-start, .plyr__control--overlaid, .jw-display-icon-display, [aria-label="Play"]';
          const btn = document.querySelector(sel);
          if (btn) btn.click();
        }).catch(() => {});
      }
    };
    const nudges = [4000, 8000, 14000].filter((t) => t < timeoutMs).map((t) => setTimeout(() => { if (!settled) nudge(); }, t));
    const timer = new Promise((r) => setTimeout(() => r(null), timeoutMs));
    const out = await Promise.race([result, timer]);
    nudges.forEach(clearTimeout);
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

// ---------------------------------------------------------------------------
// Anti-crawler verification for rules with antiCrawlerConfig (Kazumi's
// CaptchaType: 1 image captcha typed by the user, 2 click a button, 3 custom
// script). The TV cannot run a browser, so verification happens here and the
// resulting cookies (bound to the User-Agent) are returned to the TV.

const captchaSessions = new Map(); // id -> { context, page, cfg, timer }
const CAPTCHA_TTL_MS = 3 * 60 * 1000;

const xpathCount = (page, xp) =>
  xp ? page.locator(`xpath=${xp}`).count().catch(() => 0) : Promise.resolve(0);

async function captchaPresent(page, cfg) {
  const detect = (cfg.detectValue || '').trim();
  if (detect) {
    if (cfg.detectType === 2) return (await page.content().catch(() => '')).includes(detect);
    if (cfg.detectType === 3) {
      try { return new RegExp(detect, 'is').test(await page.content()); } catch (_) { return false; }
    }
    return (await xpathCount(page, detect)) > 0;
  }
  for (const xp of [cfg.image, cfg.button]) if (xp && (await xpathCount(page, xp)) > 0) return true;
  return false;
}

async function waitUntilGone(page, cfg, timeoutMs) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    await page.waitForTimeout(700);
    await page.waitForLoadState('domcontentloaded').catch(() => {});
    if (!(await captchaPresent(page, cfg))) return true;
  }
  return false;
}

async function cookiesFor(context, url, userAgent) {
  const cookies = await context.cookies(url);
  return { done: true, cookie: cookies.map((c) => `${c.name}=${c.value}`).join('; '), userAgent };
}

async function captchaImage(page, cfg) {
  const loc = page.locator(`xpath=${cfg.image}`).first();
  await loc.waitFor({ state: 'visible', timeout: 15000 });
  await page.waitForTimeout(500);
  return (await loc.screenshot({ type: 'png' })).toString('base64');
}

function closeSession(id) {
  const s = captchaSessions.get(id);
  if (!s) return;
  captchaSessions.delete(id);
  clearTimeout(s.timer);
  s.context.close().catch(() => {});
  release();
}

async function captchaStart(cfg) {
  const userAgent = cfg.userAgent || DEFAULT_UA;
  await acquire();
  let keep = false;
  const browser = await getBrowser().catch((e) => { release(); throw e; });
  const context = await browser.newContext({ userAgent, ignoreHTTPSErrors: true, viewport: { width: 1280, height: 900 } });
  try {
    const page = await context.newPage();
    await page.goto(cfg.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(1500);
    if (!(await captchaPresent(page, cfg))) return await cookiesFor(context, cfg.url, userAgent);

    if (cfg.type === 2) {
      const btn = page.locator(`xpath=${cfg.button}`).first();
      await btn.waitFor({ state: 'visible', timeout: 15000 });
      await btn.click();
      if (await waitUntilGone(page, cfg, 20000)) return await cookiesFor(context, cfg.url, userAgent);
      throw Object.assign(new Error('点击验证按钮后验证页仍未消失'), { status: 422 });
    }

    if (cfg.type === 3) {
      await page.evaluate((script) => {
        window.__kazumiCaptchaDone = false;
        window.KazumiCaptcha = {
          log: () => {}, clicked: () => {}, fail: () => {},
          done: () => { window.__kazumiCaptchaDone = true; },
        };
        // eslint-disable-next-line no-new-func
        const r = new Function(script)();
        if (r === true) window.__kazumiCaptchaDone = true;
      }, cfg.script || '');
      const end = Date.now() + 30000;
      while (Date.now() < end) {
        await page.waitForTimeout(700);
        const flagged = await page.evaluate(() => window.__kazumiCaptchaDone === true).catch(() => false);
        if (flagged || !(await captchaPresent(page, cfg))) return await cookiesFor(context, cfg.url, userAgent);
      }
      throw Object.assign(new Error('验证脚本未完成'), { status: 422 });
    }

    // Image captcha: hand the picture to the TV and wait for the answer.
    const image = await captchaImage(page, cfg);
    const id = Math.random().toString(36).slice(2) + Date.now().toString(36);
    const timer = setTimeout(() => closeSession(id), CAPTCHA_TTL_MS);
    captchaSessions.set(id, { context, page, cfg, userAgent, timer });
    keep = true;
    return { session: id, image };
  } finally {
    if (!keep) { context.close().catch(() => {}); release(); }
  }
}

async function captchaSubmit({ session, answer }) {
  const s = captchaSessions.get(session);
  if (!s) throw Object.assign(new Error('验证会话已过期，请重新开始'), { status: 410 });
  const { page, cfg, context, userAgent } = s;
  const input = page.locator(`xpath=${cfg.input}`).first();
  await input.fill(String(answer || ''));
  await page.locator(`xpath=${cfg.button}`).first().click();
  if (await waitUntilGone(page, cfg, 15000)) {
    const out = await cookiesFor(context, cfg.url, userAgent);
    closeSession(session);
    return out;
  }
  // Wrong answer: the page usually shows a fresh captcha.
  const image = await captchaImage(page, cfg).catch(() => null);
  if (!image) { closeSession(session); throw Object.assign(new Error('验证失败'), { status: 422 }); }
  return { session, image, error: '验证码不正确，请重试' };
}

function send(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) });
  res.end(body);
}

const server = http.createServer((req, res) => {
  if (TOKEN && req.headers.authorization !== `Bearer ${TOKEN}`) return send(res, 401, { error: 'unauthorized' });
  if (req.method === 'GET' && req.url === '/health') return send(res, 200, { ok: true, version: VERSION });
  const routes = { '/resolve': true, '/captcha/start': true, '/captcha/submit': true };
  if (req.method !== 'POST' || !routes[req.url]) return send(res, 404, { error: 'not found' });
  let raw = '';
  req.on('data', (c) => { raw += c; if (raw.length > 1e5) req.destroy(); });
  req.on('end', async () => {
    let input;
    try { input = JSON.parse(raw || '{}'); } catch (_) { return send(res, 400, { error: 'invalid json' }); }
    if (req.url === '/captcha/start' || req.url === '/captcha/submit') {
      try {
        if (req.url === '/captcha/start') {
          if (!input.url || !/^https?:\/\//i.test(input.url)) return send(res, 400, { error: 'url required' });
          const cfg = { ...input, type: Number(input.type) || 1, detectType: Number(input.detectType) || 1 };
          const out = await captchaStart(cfg);
          console.log(`[captcha] start ${input.url} -> ${out.done ? 'done' : 'needs answer'}`);
          return send(res, 200, out);
        }
        const out = await captchaSubmit(input);
        console.log(`[captcha] submit -> ${out.done ? 'done' : 'retry'}`);
        return send(res, 200, out);
      } catch (e) {
        console.log(`[captcha] fail: ${e.message}`);
        return send(res, e.status || 502, { error: e.message });
      }
    }
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
  server.listen(PORT, HOST, () => {
    console.log(`Kazumi TV resolver ${VERSION} listening on http://${HOST}:${PORT}`);
    // Advertise on the LAN so the TV finds the resolver without typing an IP.
    if (process.env.BONJOUR !== '0') {
      try {
        const { Bonjour } = require('bonjour-service');
        const bonjour = new Bonjour();
        bonjour.publish({ name: `Kazumi Resolver (${require('os').hostname()})`, type: 'kazumi-resolver', port: PORT,
                          txt: { version: VERSION, auth: TOKEN ? '1' : '0' } });
        console.log('Advertising _kazumi-resolver._tcp via Bonjour');
        process.on('exit', () => bonjour.unpublishAll());
      } catch (e) {
        console.log(`Bonjour disabled: ${e.message}`);
      }
    }
  });
  const shutdown = async () => { server.close(); if (browserPromise) (await browserPromise).close().catch(() => {}); process.exit(0); };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

module.exports = { resolve, decodeVideoSource, isMediaUrl, server };
