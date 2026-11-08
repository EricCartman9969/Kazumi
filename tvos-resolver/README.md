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

The resolver advertises itself over Bonjour (`_kazumi-resolver._tcp`), so the TV finds it on its own
(Settings > 伴随解析器 > 自动查找局域网解析器). Otherwise enter `http://<this machine's LAN IP>:8787`.
Bonjour from Docker needs host networking (`network_mode: host`, Linux hosts such as most NAS);
with Docker Desktop on a Mac, enter the address by hand or run with Node.

Environment variables: `PORT` (8787), `HOST` (0.0.0.0), `RESOLVER_TOKEN` (optional shared secret,
enter the same value on the TV), `MAX_PAGES` (3 concurrent pages), `CHROMIUM_PATH`, `BONJOUR=0` to
stop advertising.

## API

```
GET  /health  -> {"ok":true,"version":"0.2.0"}
POST /resolve {"url":"<episode page>","legacy":false,"userAgent":"...","timeoutMs":30000}
  -> 200 {"url":"https://.../index.m3u8","kind":"m3u8|video|iframe","frame":"<frame url>","userAgent":"..."}
  -> 504 {"error":"Timed out without finding a video source"}

POST /captcha/start   {"url","type","image","input","button","script","detectType","detectValue","userAgent"}
POST /captcha/submit  {"session","answer"}
  -> {"done":true,"cookie":"a=b; ...","userAgent":"..."}  or  {"session","image":"<png base64>","error"?}
```

Keep it on your LAN or behind a token: it will open any URL it is given.
