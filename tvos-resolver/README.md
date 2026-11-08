# Kazumi TV companion resolver

Loads episode pages in headless Chromium with the same hooks the Kazumi app injects into its WebView
(fetch/XHR responses starting with `#EXTM3U`, `<video>` sources, iframe query strings for legacy
rules) and returns the media URL to the Apple TV app.

## Run with Docker (NAS, server, Mac)

```sh
cd tvos-resolver
docker compose up -d --build
```

## Run with Node (Mac)

```sh
cd tvos-resolver
npm install
npx playwright install chromium
node server.js          # listens on 0.0.0.0:8787
```

Then on the Apple TV: Settings > 伴随解析器 > enter `http://<this machine's LAN IP>:8787` > 测试连接.

Environment variables: `PORT` (8787), `HOST` (0.0.0.0), `RESOLVER_TOKEN` (optional shared secret,
enter the same value on the TV), `MAX_PAGES` (3 concurrent pages), `CHROMIUM_PATH`.

## API

```
GET  /health  -> {"ok":true,"version":"0.1.0"}
POST /resolve {"url":"<episode page>","legacy":false,"userAgent":"...","timeoutMs":30000}
  -> 200 {"url":"https://.../index.m3u8","kind":"m3u8|video|iframe","frame":"<frame url>","userAgent":"..."}
  -> 504 {"error":"Timed out without finding a video source"}
```

Keep it on your LAN or behind a token: it will open any URL it is given.
