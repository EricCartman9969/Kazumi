# Kazumi for Apple TV

A native tvOS (SwiftUI) client for [Kazumi](https://github.com/Predidit/Kazumi). It reuses Kazumi's rule
format and the [KazumiRules](https://github.com/Predidit/KazumiRules) catalog, Bangumi metadata, and
plays through AVPlayer with the Siri Remote.

```
tvos/
  KazumiCore/      Swift package: rules, XPath/JSON-API search and episodes, video source resolvers,
                   Bangumi API, history/favorites, HLS ad filter. Builds on macOS/Linux; `swift test`.
  KazumiTV/        The tvOS app (SwiftUI).
  project.yml      XcodeGen spec for the Xcode project.
tvos-resolver/     Companion resolver (Node + headless Chromium), see its README.
```

## Why there is a companion resolver

The Kazumi app finds the video address by loading the episode page in a hidden WebView and catching
the HLS playlist the page's JavaScript requests. tvOS has no WebView, so the TV app resolves in two steps:

1. **On the TV** (`StaticVideoResolver`): fetch the page and pull the address out of MacCMS
   `player_aaaa` data, literal m3u8/mp4 links, iframe query strings and nested iframes.
   This works for sources whose pages contain the address in plain form.
2. **Companion** (`CompanionVideoResolver`): if that fails, ask `tvos-resolver` running on a Mac,
   NAS or server to load the page in headless Chromium with Kazumi's own detection hooks.

The mode is chosen in Settings: auto (default), TV only, or companion only.

## Build and install

Requirements: a Mac with Xcode 16 or newer, an Apple TV on tvOS 17+, and an Apple developer account.

```sh
brew install xcodegen
cd tvos
xcodegen                 # creates KazumiTV.xcodeproj
open KazumiTV.xcodeproj
```

In Xcode: select the KazumiTV target > Signing & Capabilities > choose your Team (change the bundle
identifier if it is taken). Pair the Apple TV in Window > Devices and Simulators (Apple TV: Settings >
Remotes and Devices > Remote App and Devices), pick it as the run destination and press Run.

Builds installed from Xcode with a paid account stay valid for a year; TestFlight builds expire after 90 days.

## Status

Working: Bangumi trending / weekly calendar / search, per-source search across all installed rules,
episode lists (XPath and API rules), on-device and companion resolving, AVPlayer playback with
User-Agent/Referer, HLS ad filtering, resume, next episode, watch history and favorites.

Not yet: danmaku, Bangumi account sync, captcha-protected rules (need a WebView to solve),
WebDAV sync, Anime4K shaders and formats AVPlayer cannot play (for example FLV, MKV).

## License

GPL-3.0, same as Kazumi. Portions are ports of Kazumi's Dart code; see the source comments.
