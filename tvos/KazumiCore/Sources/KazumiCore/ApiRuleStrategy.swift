import Foundation

struct PreparedRuleRequest: Sendable {
    var method: String
    var url: String
    var headers: [String: String] = [:]
    var query: [(String, String)] = []
    /// none | json | form
    var bodyType: String = "none"
    var body: JSONValue? = nil
    var includeCookies = false
}

/// Port of `ApiRuleStrategy` (lib/services/plugin/api_rule_strategy.dart).
struct ApiRuleStrategy {
    func decode(_ raw: String) throws -> Any {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw KazumiError.parse("API 响应不是有效 JSON")
        }
        return obj
    }

    func prepareRequest(_ config: ApiRequestConfig, variables: [String: Any]) throws -> PreparedRuleRequest {
        let method = config.method.uppercased()
        guard method == "GET" || method == "POST" else { throw KazumiError.invalidRule("仅支持 GET/POST，当前为 \(method)") }
        let trimmed = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KazumiError.invalidRule("API 请求 URL 不能为空") }
        let url = try renderTemplate(trimmed, variables, encode: true)
        guard let u = URL(string: url), u.scheme != nil, !(u.host ?? "").isEmpty else { throw KazumiError.invalidURL(url) }
        let headers = try renderMap(config.headers, variables).mapValues { stringify($0) }
        let query = try renderMap(config.query, variables).map { ($0.key, stringify($0.value)) }.sorted { $0.0 < $1.0 }
        let hasBody = method == "POST" && config.bodyType != "none"
        let body: JSONValue? = hasBody ? try config.body.map { JSONValue(any: try renderValue($0.foundation, variables)) } : nil
        return PreparedRuleRequest(method: method, url: url, headers: headers, query: query, bodyType: config.bodyType, body: body, includeCookies: true)
    }

    func parseSearch(_ raw: String, config: ApiSearchConfig) throws -> [SearchItem] {
        try RestrictedJSONPath.validate(config.listPath)
        try RestrictedJSONPath.validate(config.namePath)
        try RestrictedJSONPath.validate(config.sourcePath)
        let doc = try decode(raw)
        var items: [SearchItem] = []
        for node in try RestrictedJSONPath.read(doc, config.listPath) {
            let name = stringValue(try RestrictedJSONPath.readFirst(node, config.namePath))
            let source = stringValue(try RestrictedJSONPath.readFirst(node, config.sourcePath))
            if name.isEmpty || source.isEmpty { continue }
            let src = config.sourceTemplate.isEmpty ? source : config.sourceTemplate.replacingOccurrences(of: "@source", with: encodeComponent(source))
            items.append(SearchItem(name: name, src: src))
        }
        return items
    }

    func parseChapters(_ raw: String, config: ApiChapterConfig, source: String, baseURL: String) throws -> [Road] {
        let doc = try decode(raw)
        var rootVars: [String: Any] = ["source": source]
        for (key, path) in config.variables {
            guard let v = try RestrictedJSONPath.readFirst(doc, path) else {
                throw KazumiError.parse("章节响应变量 \(key) 未匹配到值: \(path)")
            }
            rootVars[key] = v
        }
        return config.format == "delimited"
            ? try parseDelimited(doc, config, rootVars, baseURL)
            : try parseNested(doc, config, rootVars, baseURL)
    }

    private func parseNested(_ doc: Any, _ config: ApiChapterConfig, _ rootVars: [String: Any], _ baseURL: String) throws -> [Road] {
        let hasRoads = !config.roadsPath.trimmingCharacters(in: .whitespaces).isEmpty
        let roadNodes = hasRoads ? try RestrictedJSONPath.read(doc, config.roadsPath) : [doc]
        var roads: [Road] = []
        for (roadIndex, roadNode) in roadNodes.enumerated() {
            let roadName = hasRoads && !config.roadNamePath.trimmingCharacters(in: .whitespaces).isEmpty
                ? stringValue(try RestrictedJSONPath.readFirst(roadNode, config.roadNamePath)) : ""
            var urls: [String] = [], names: [String] = []
            for (episodeIndex, ep) in try RestrictedJSONPath.read(roadNode, config.episodesPath).enumerated() {
                let epName = stringValue(try RestrictedJSONPath.readFirst(ep, config.episodeNamePath))
                let rawURL = config.episodeUrlPath.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "" : stringValue(try RestrictedJSONPath.readFirst(ep, config.episodeUrlPath))
                let page = try resolveEpisodeURL(config, rootVars, rawURL: rawURL, roadIndex: roadIndex, episodeIndex: episodeIndex, baseURL: baseURL)
                if page.isEmpty { continue }
                urls.append(page)
                names.append(epName.isEmpty ? "第\(episodeIndex + 1)集" : epName)
            }
            if urls.isEmpty { continue }
            roads.append(Road(name: roadName.isEmpty ? "播放线路\(roads.count + 1)" : roadName, urls: urls, episodeNames: names))
        }
        return roads
    }

    private func parseDelimited(_ doc: Any, _ config: ApiChapterConfig, _ rootVars: [String: Any], _ baseURL: String) throws -> [Road] {
        let namesValue = stringValue(try RestrictedJSONPath.readFirst(doc, config.roadNamesPath))
        let episodesValue = stringValue(try RestrictedJSONPath.readFirst(doc, config.roadEpisodesPath))
        if episodesValue.isEmpty { return [] }
        let roadNames = namesValue.components(separatedBy: config.roadSeparator)
        var roads: [Road] = []
        for (roadIndex, group) in episodesValue.components(separatedBy: config.roadSeparator).enumerated() {
            var urls: [String] = [], names: [String] = []
            for (episodeIndex, rawEntry) in group.components(separatedBy: config.episodeSeparator).enumerated() {
                let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty, let sep = entry.range(of: config.fieldSeparator) else { continue }
                let name = entry[..<sep.lowerBound].trimmingCharacters(in: .whitespaces)
                let rawURL = entry[sep.upperBound...].trimmingCharacters(in: .whitespaces)
                let page = try resolveEpisodeURL(config, rootVars, rawURL: rawURL, roadIndex: roadIndex, episodeIndex: episodeIndex, baseURL: baseURL)
                if page.isEmpty { continue }
                urls.append(page)
                names.append(name.isEmpty ? "第\(episodeIndex + 1)集" : name)
            }
            if urls.isEmpty { continue }
            let configured = roadIndex < roadNames.count ? roadNames[roadIndex].trimmingCharacters(in: .whitespaces) : ""
            roads.append(Road(name: configured.isEmpty ? "播放线路\(roads.count + 1)" : configured, urls: urls, episodeNames: names))
        }
        return roads
    }

    private func resolveEpisodeURL(_ config: ApiChapterConfig, _ rootVars: [String: Any], rawURL: String,
                                   roadIndex: Int, episodeIndex: Int, baseURL: String) throws -> String {
        guard let page = config.episodePage else { return normalizeEpisodeURL(baseURL: baseURL, raw: rawURL) }
        guard !page.url.trimmingCharacters(in: .whitespaces).isEmpty else { throw KazumiError.invalidRule("播放页地址模板不能为空") }
        var vars = rootVars
        vars["episodeUrl"] = rawURL
        vars["roadIndex"] = roadIndex
        vars["roadNumber"] = roadIndex + 1
        vars["episodeIndex"] = episodeIndex
        vars["episodeNumber"] = episodeIndex + 1
        let path = try renderTemplate(page.url, vars, encode: true)
        guard var comps = URLComponents(string: path) else { throw KazumiError.invalidURL(path) }
        let rendered = try renderMap(page.query, vars).mapValues { stringify($0) }
        if !rendered.isEmpty {
            var merged: [String: String] = [:]
            for item in comps.queryItems ?? [] { merged[item.name] = item.value ?? "" }
            for (k, v) in rendered { merged[k] = v }
            comps.queryItems = merged.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return normalizeEpisodeURL(baseURL: baseURL, raw: comps.string ?? path)
    }

    // MARK: Templates

    private static let exactVar = try! NSRegularExpression(pattern: "^@([A-Za-z_][A-Za-z0-9_]*)$")
    private static let inlineVar = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])@([A-Za-z_][A-Za-z0-9_]*)")

    func renderMap(_ input: [String: JSONValue], _ vars: [String: Any]) throws -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in input { out[try renderTemplate(k, vars)] = try renderValue(v.foundation, vars) }
        return out
    }

    func renderValue(_ value: Any, _ vars: [String: Any]) throws -> Any {
        if let s = value as? String {
            let ns = s as NSString
            if let m = Self.exactVar.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                let name = ns.substring(with: m.range(at: 1))
                guard let v = vars[name] else { throw KazumiError.invalidRule("缺少模板变量 @\(name)") }
                return v
            }
            return try renderTemplate(s, vars)
        }
        if let a = value as? [Any] { return try a.map { try renderValue($0, vars) } }
        if let o = value as? [String: Any] { return try o.mapValues { try renderValue($0, vars) } }
        return value
    }

    func renderTemplate(_ template: String, _ vars: [String: Any], encode: Bool = false) throws -> String {
        let ns = template as NSString
        var out = ""
        var last = 0
        for m in Self.inlineVar.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            guard let v = vars[name] else { throw KazumiError.invalidRule("缺少模板变量 @\(name)") }
            let s = stringify(v)
            out += encode ? encodeComponent(s) : s
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private func stringValue(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "" }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return stringify(v)
    }
}
