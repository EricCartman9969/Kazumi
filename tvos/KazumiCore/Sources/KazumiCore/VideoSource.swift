import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct VideoSource: Sendable, Equatable {
    public let url: String
    /// Headers the player must send (User-Agent, Referer).
    public let headers: [String: String]
    /// Which resolver found it ("static" or "companion").
    public let resolvedBy: String
}

public protocol VideoSourceResolver: Sendable {
    var name: String { get }
    func resolve(episodeURL: String, plugin: Plugin) async throws -> VideoSource
}

/// Playback headers, as Kazumi sets them in lib/pages/video/video_controller.dart:
/// the rule's User-Agent (or a random one) and the rule's Referer if set.
public func playbackHeaders(for plugin: Plugin, userAgent: String? = nil) -> [String: String] {
    var h = ["User-Agent": plugin.userAgent.isEmpty ? (userAgent ?? randomUserAgent()) : plugin.userAgent]
    if !plugin.referer.isEmpty { h["Referer"] = plugin.referer }
    return h
}

/// Tries resolvers in order and returns the first success.
public struct ChainVideoResolver: VideoSourceResolver {
    public let name = "chain"
    let resolvers: [VideoSourceResolver]
    public init(_ resolvers: [VideoSourceResolver]) { self.resolvers = resolvers }

    public func resolve(episodeURL: String, plugin: Plugin) async throws -> VideoSource {
        var errors: [String] = []
        for r in resolvers {
            try Task.checkCancellation()
            do {
                return try await r.resolve(episodeURL: episodeURL, plugin: plugin)
            } catch is CancellationError {
                throw KazumiError.cancelled
            } catch KazumiError.cancelled {
                throw KazumiError.cancelled
            } catch {
                errors.append("\(r.name)：\(error.localizedDescription)")
            }
        }
        throw KazumiError.videoSourceNotFound(errors.joined(separator: "；"))
    }
}

/// A1: resolve on the TV without a browser. Fetches the episode page and looks
/// for the media address in the places sites commonly put it: MacCMS
/// `player_aaaa` data, literal m3u8/mp4 URLs, iframe query strings, and the
/// pages of nested iframes. Pages that compute the address in JavaScript are
/// left to the companion resolver.
public struct StaticVideoResolver: VideoSourceResolver {
    public let name = "static"
    let http: HTTPClient
    let maxDepth: Int
    let maxFetches: Int

    public init(http: HTTPClient = URLSessionHTTPClient(), maxDepth: Int = 3, maxFetches: Int = 8) {
        self.http = http
        self.maxDepth = maxDepth
        self.maxFetches = maxFetches
    }

    final class Budget: @unchecked Sendable {
        var fetches = 0
        var visited = Set<String>()
    }

    public func resolve(episodeURL: String, plugin: Plugin) async throws -> VideoSource {
        let headers = playbackHeaders(for: plugin)
        let budget = Budget()
        if let url = try await visit(episodeURL, referer: plugin.baseURL, plugin: plugin, headers: headers, depth: 0, budget: budget) {
            return VideoSource(url: url, headers: headers, resolvedBy: name)
        }
        throw KazumiError.videoSourceNotFound("页面中没有可直接提取的视频地址")
    }

    private func visit(_ pageURL: String, referer: String, plugin: Plugin, headers: [String: String],
                       depth: Int, budget: Budget) async throws -> String? {
        try Task.checkCancellation()
        guard depth <= maxDepth, budget.fetches < maxFetches, !budget.visited.contains(pageURL) else { return nil }
        budget.visited.insert(pageURL)

        // Some API rules hand out the media file itself as the episode URL.
        if depth == 0, VideoPageScanner.isMediaURL(pageURL) { return pageURL }
        // The page URL itself may carry the media address (?url=...m3u8).
        if let direct = mediaURLInQuery(pageURL) { return try await validated(direct, headers: headers, budget: budget) ?? direct }

        budget.fetches += 1
        var reqHeaders = ["User-Agent": headers["User-Agent"] ?? randomUserAgent()]
        if !referer.isEmpty { reqHeaders["Referer"] = referer }
        guard let res = try? await http.get(pageURL, headers: reqHeaders, timeout: 12) else { return nil }
        let html = res.text
        let base = res.url

        // 1. MacCMS player data.
        if let player = VideoPageScanner.macCMSPlayer(in: html) {
            if VideoPageScanner.isMediaURL(player.url) {
                let abs = absolute(player.url, base: base)
                if let ok = try await validated(abs, headers: headers, budget: budget) { return ok }
            } else if player.url.lowercased().hasPrefix("http") {
                // The "address" is another site's play page.
                if let found = try await visit(player.url, referer: pageURL, plugin: plugin, headers: headers, depth: depth + 1, budget: budget) {
                    return found
                }
            } else if !player.url.isEmpty, !player.from.isEmpty,
                      let parse = try await macCMSParseURL(from: player.from, base: base, headers: reqHeaders, budget: budget) {
                let next = parse + player.url
                if let found = try await visit(absolute(next, base: base), referer: pageURL, plugin: plugin, headers: headers, depth: depth + 1, budget: budget) {
                    return found
                }
            }
        }

        // 2. Literal media URLs in the page or its inline scripts.
        for candidate in VideoPageScanner.mediaURLs(in: html, base: base) {
            if let ok = try await validated(candidate, headers: headers, budget: budget) { return ok }
        }

        // 3. Iframes: media in the query string (Kazumi's legacy parser), or
        //    a nested player page.
        let iframes = VideoPageScanner.iframeSources(in: html, base: base)
        for src in iframes {
            if let direct = mediaURLInQuery(src) {
                if let ok = try await validated(direct, headers: headers, budget: budget) { return ok }
            }
        }
        for src in iframes {
            if let found = try await visit(src, referer: pageURL, plugin: plugin, headers: headers, depth: depth + 1, budget: budget) {
                return found
            }
        }
        return nil
    }

    /// Confirms a candidate is playable: m3u8 must start with #EXTM3U; mp4 is
    /// accepted as is. Returns nil for dead or ad links.
    private func validated(_ url: String, headers: [String: String], budget: Budget) async throws -> String? {
        guard url.lowercased().contains(".m3u8") else { return url }
        guard budget.fetches < maxFetches + 4 else { return url }
        budget.fetches += 1
        guard let res = try? await http.get(url, headers: headers, timeout: 10) else { return nil }
        return res.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") ? url : nil
    }

    private func macCMSParseURL(from: String, base: URL, headers: [String: String], budget: Budget) async throws -> String? {
        guard budget.fetches < maxFetches else { return nil }
        budget.fetches += 1
        let configURL = absolute("/static/js/playerconfig.js", base: base)
        guard let res = try? await http.get(configURL, headers: headers, timeout: 10) else { return nil }
        return VideoPageScanner.macCMSParse(for: from, configJS: res.text)
    }

    private func absolute(_ s: String, base: URL) -> String {
        if s.hasPrefix("//") { return (base.scheme ?? "https") + ":" + s }
        return lenientURL(s, relativeTo: base)?.absoluteString ?? s
    }
}

/// Port of `decodeVideoSource` (lib/utils/media.dart): a query parameter that
/// holds an http(s) m3u8/mp4 address.
public func mediaURLInQuery(_ url: String) -> String? {
    let decoded = url.removingPercentEncoding ?? url
    guard let comps = URLComponents(string: decoded) ?? lenientURL(decoded).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
    for item in comps.queryItems ?? [] {
        guard let v = item.value else { continue }
        if v.range(of: #"https?://.*?\.(m3u8|mp4)"#, options: [.regularExpression, .caseInsensitive]) != nil { return v }
    }
    return nil
}

enum VideoPageScanner {
    static let adPatterns = ["googleads", "googlesyndication.com", "prestrain.html", "prestrain%2Ehtml", "adtrafficquality", "devtools-detector"]

    static func isMediaURL(_ s: String) -> Bool {
        s.range(of: #"\.(m3u8|mp4)(\?|#|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Undoes the escaping inline scripts apply to URLs (`\/`, `/`, `&amp;`).
    static func unescape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
        let re = try! NSRegularExpression(pattern: #"\\u([0-9a-fA-F]{4})"#)
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if let code = UInt32(ns.substring(with: m.range(at: 1)), radix: 16), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        out = result
        return out
    }

    struct MacCMSPlayer { let url: String; let from: String }

    /// MacCMS themes embed `var player_aaaa={...,"url":"...","encrypt":0,"from":"..."}`.
    static func macCMSPlayer(in html: String) -> MacCMSPlayer? {
        guard let marker = html.range(of: #"player_[A-Za-z0-9_]+\s*=\s*\{"#, options: .regularExpression) else { return nil }
        // Brace-match the object literal: it nests vod_data, so a lazy regex stops too early.
        let chars = html[html.index(before: marker.upperBound)...]
        var depth = 0
        var inString = false
        var escaped = false
        var endIndex: String.Index?
        for idx in chars.indices {
            let c = chars[idx]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                continue
            }
            if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { endIndex = idx; break } }
        }
        guard let endIndex,
              let data = String(chars[chars.startIndex...endIndex]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var url = stringify(obj["url"])
        let encrypt = Int(stringify(obj["encrypt"])) ?? 0
        if encrypt == 1 {
            url = url.removingPercentEncoding ?? url
        } else if encrypt == 2 {
            var b64 = url.removingPercentEncoding ?? url
            while b64.count % 4 != 0 { b64 += "=" }
            if let d = Data(base64Encoded: b64), let s = String(data: d, encoding: .utf8) {
                url = s.removingPercentEncoding ?? s
            }
        }
        return MacCMSPlayer(url: unescape(url), from: stringify(obj["from"]))
    }

    /// Reads the parse (解析) prefix for a player from MacCMS playerconfig.js.
    static func macCMSParse(for from: String, configJS: String) -> String? {
        let ns = configJS as NSString
        let listRe = try! NSRegularExpression(pattern: #"player_list\s*=\s*(\{.*?\})\s*,\s*MacPlayerConfig\."#, options: [.dotMatchesLineSeparators])
        if let m = listRe.firstMatch(in: configJS, range: NSRange(location: 0, length: ns.length)),
           let data = ns.substring(with: m.range(at: 1)).data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entry = list[from] as? [String: Any] {
            let parse = unescape(stringify(entry["parse"]))
            if !parse.isEmpty { return parse }
        }
        let parseRe = try! NSRegularExpression(pattern: #"MacPlayerConfig\.parse\s*=\s*['"]([^'"]+)['"]"#)
        if let m = parseRe.firstMatch(in: configJS, range: NSRange(location: 0, length: ns.length)) {
            return unescape(ns.substring(with: m.range(at: 1)))
        }
        return nil
    }

    static func mediaURLs(in html: String, base: URL) -> [String] {
        let text = unescape(html)
        let ns = text as NSString
        var found: [String] = []
        let absRe = try! NSRegularExpression(pattern: #"(?:https?:)?//[^\s"'<>()\\]+?\.(?:m3u8|mp4)(?:\?[^\s"'<>()\\]*)?"#, options: [.caseInsensitive])
        let relRe = try! NSRegularExpression(pattern: #"["'](/[^\s"'<>()\\]+?\.m3u8(?:\?[^\s"'<>()\\]*)?)["']"#, options: [.caseInsensitive])
        for m in absRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var u = ns.substring(with: m.range)
            if u.hasPrefix("//") { u = (base.scheme ?? "https") + ":" + u }
            found.append(u)
        }
        for m in relRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let u = URL(string: ns.substring(with: m.range(at: 1)), relativeTo: base)?.absoluteString { found.append(u) }
        }
        var seen = Set<String>()
        let filtered = found.filter { u in
            !adPatterns.contains(where: { u.contains($0) }) && seen.insert(u).inserted
        }
        // Prefer HLS over mp4 (mp4 hits are often ad or preview clips).
        return filtered.filter { $0.lowercased().contains(".m3u8") } + filtered.filter { !$0.lowercased().contains(".m3u8") }
    }

    static func iframeSources(in html: String, base: URL) -> [String] {
        let re = try! NSRegularExpression(pattern: #"<iframe[^>]+?src\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive])
        let ns = html as NSString
        var out: [String] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            var src = unescape(ns.substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespaces)
            if src.isEmpty || src.hasPrefix("about:") || src.hasPrefix("javascript:") { continue }
            if adPatterns.contains(where: { src.contains($0) }) { continue }
            if src.hasPrefix("//") { src = (base.scheme ?? "https") + ":" + src }
            if let abs = lenientURL(src, relativeTo: base)?.absoluteString { out.append(abs) }
        }
        return out
    }
}

/// A2: asks the companion resolver (tvos-resolver/, headless Chromium running
/// on a Mac, NAS or server) to load the page the way the Kazumi app does.
public struct CompanionVideoResolver: VideoSourceResolver {
    public let name = "companion"
    let endpoint: String
    let token: String?
    let timeout: TimeInterval

    public init(endpoint: String, token: String?, timeout: TimeInterval = 40) {
        self.endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.token = token
        self.timeout = timeout
    }

    private func request(path: String, method: String, body: Data?, timeout: TimeInterval) async throws -> (Int, Data) {
        guard let url = URL(string: endpoint + path), url.scheme != nil else { throw KazumiError.resolverUnavailable("地址无效：\(endpoint)") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch {
            throw KazumiError.resolverUnavailable(error.localizedDescription)
        }
    }

    public func health() async throws -> String {
        let (status, data) = try await request(path: "/health", method: "GET", body: nil, timeout: 5)
        guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KazumiError.resolverUnavailable(status == 401 ? "令牌不正确" : "HTTP \(status)")
        }
        return stringify(obj["version"])
    }

    public func resolve(episodeURL: String, plugin: Plugin) async throws -> VideoSource {
        var payload: [String: Any] = ["url": episodeURL, "legacy": plugin.useLegacyParser, "timeoutMs": Int((timeout - 5) * 1000)]
        if !plugin.userAgent.isEmpty { payload["userAgent"] = plugin.userAgent }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let (status, data) = try await request(path: "/resolve", method: "POST", body: body, timeout: timeout)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200, let url = obj["url"] as? String, !url.isEmpty else {
            let msg = (obj["error"] as? String) ?? "HTTP \(status)"
            if status == 401 { throw KazumiError.resolverUnavailable("令牌不正确") }
            throw KazumiError.videoSourceNotFound(msg)
        }
        return VideoSource(url: url, headers: playbackHeaders(for: plugin, userAgent: obj["userAgent"] as? String), resolvedBy: name)
    }
}
