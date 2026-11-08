import Foundation

/// Runs search and chapter queries for a rule. Port of `RuleEngine`
/// (lib/services/plugin/rule_engine.dart) and its default request executor.
public struct RuleEngine: Sendable {
    let http: HTTPClient
    let cookies: PluginCookieStore?

    public init(http: HTTPClient = URLSessionHTTPClient(), cookies: PluginCookieStore? = nil) {
        self.http = http
        self.cookies = cookies
    }

    public func search(_ plugin: Plugin, keyword: String) async throws -> [SearchItem] {
        let request = plugin.searchMode == .api
            ? try ApiRuleStrategy().prepareRequest(plugin.searchApiConfig.request, variables: ["keyword": keyword])
            : try XPathRuleStrategy().prepareSearchRequest(plugin, keyword: keyword)
        let raw: String
        do {
            raw = try await execute(request, plugin: plugin)
        } catch let e as HTTPStatusError {
            if plugin.searchMode == .xpath, plugin.antiCrawlerConfig.enabled {
                if e.response.headers["cf-mitigated"]?.lowercased() == "challenge"
                    || XPathRuleStrategy().detectsCaptcha(e.response.text, config: plugin.antiCrawlerConfig) {
                    throw KazumiError.captchaRequired(plugin.name)
                }
            }
            throw KazumiError.http(e.response.status, request.url)
        }
        let items = plugin.searchMode == .api
            ? try ApiRuleStrategy().parseSearch(raw, config: plugin.searchApiConfig)
            : try XPathRuleStrategy().parseSearch(raw, plugin: plugin)
        if items.isEmpty { throw KazumiError.noResult(plugin.name) }
        return items
    }

    public func chapters(_ plugin: Plugin, source: String) async throws -> [Road] {
        let request = plugin.chapterMode == .api
            ? try ApiRuleStrategy().prepareRequest(plugin.chapterApiConfig.request, variables: ["source": source])
            : try XPathRuleStrategy().prepareChapterRequest(plugin, source: source)
        let raw: String
        do {
            raw = try await execute(request, plugin: plugin)
        } catch let e as HTTPStatusError {
            throw KazumiError.http(e.response.status, request.url)
        }
        let roads = plugin.chapterMode == .api
            ? try ApiRuleStrategy().parseChapters(raw, config: plugin.chapterApiConfig, source: source, baseURL: plugin.baseURL)
            : try XPathRuleStrategy().parseChapters(raw, plugin: plugin)
        if roads.isEmpty { throw KazumiError.parse("\(plugin.name) 没有找到剧集") }
        return roads
    }

    func execute(_ request: PreparedRuleRequest, plugin: Plugin) async throws -> String {
        // Header names are lowercased so a rule-supplied 'User-Agent' replaces ours.
        var headers: [String: String] = ["referer": "\(plugin.baseURL)/", "user-agent": randomUserAgent()]
        let stored = request.includeCookies ? cookies?.cookie(for: plugin.name) : nil
        if let stored { headers["cookie"] = stored.cookie }
        for (k, v) in request.headers { headers[k.lowercased()] = v }
        // Clearance cookies only work with the User-Agent they were issued to.
        if let stored { headers["user-agent"] = stored.userAgent }
        var body: Data?
        if request.method == "POST", let b = request.body {
            switch request.bodyType {
            case "json":
                if headers["content-type"] == nil { headers["content-type"] = "application/json" }
                body = try? JSONSerialization.data(withJSONObject: b.foundation, options: [.fragmentsAllowed])
            case "form":
                if headers["content-type"] == nil { headers["content-type"] = "application/x-www-form-urlencoded" }
                if case .object(let o) = b {
                    body = o.sorted { $0.key < $1.key }
                        .map { "\(encodeQueryComponent($0.key))=\(encodeQueryComponent(stringify($0.value.foundation)))" }
                        .joined(separator: "&").data(using: .utf8)
                } else if case .string(let s) = b {
                    body = s.data(using: .utf8)
                }
            default: break
            }
        }
        var req = HTTPRequest(url: request.url, method: request.method, headers: headers)
        req.query = request.query
        req.body = body
        return try await http.send(req).text
    }
}
