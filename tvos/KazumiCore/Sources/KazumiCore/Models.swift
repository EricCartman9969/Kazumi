import Foundation

/// Rule modes, mirroring `RuleMode` in lib/plugins/api_rule_config.dart.
public enum RuleMode: String, Codable, Sendable {
    case xpath
    case api

    static func normalize(_ value: Any?) -> RuleMode {
        (value as? String) == "api" ? .api : .xpath
    }
}

public struct ApiRequestConfig: Sendable, Equatable {
    public var method: String = "GET"
    public var url: String = ""
    public var headers: [String: JSONValue] = [:]
    public var query: [String: JSONValue] = [:]
    /// none | json | form
    public var bodyType: String = "none"
    public var body: JSONValue? = nil

    public init() {}

    init(json: [String: Any]) {
        method = ((json["method"] as? String) ?? "GET").uppercased()
        url = (json["url"] as? String) ?? ""
        headers = JSONValue.object(from: json["headers"])
        query = JSONValue.object(from: json["query"])
        switch json["bodyType"] as? String {
        case "json": bodyType = "json"
        case "form": bodyType = "form"
        default: bodyType = "none"
        }
        body = json["body"].map(JSONValue.init(any:))
    }
}

public struct ApiSearchConfig: Sendable, Equatable {
    public var request = ApiRequestConfig()
    public var listPath = "$.data[*]"
    public var namePath = "$.name"
    public var sourcePath = "$.url"
    public var sourceTemplate = ""

    public init() {}

    init(json: [String: Any]) {
        request = ApiRequestConfig(json: (json["request"] as? [String: Any]) ?? [:])
        listPath = (json["listPath"] as? String) ?? "$.data[*]"
        namePath = (json["namePath"] as? String) ?? "$.name"
        sourcePath = (json["sourcePath"] as? String) ?? "$.url"
        sourceTemplate = ((json["sourceTemplate"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct ApiEpisodePageConfig: Sendable, Equatable {
    public var url = ""
    public var query: [String: JSONValue] = [:]

    init(json: [String: Any]) {
        url = (json["url"] as? String) ?? ""
        query = JSONValue.object(from: json["query"])
    }
}

public struct ApiChapterConfig: Sendable, Equatable {
    public var request = ApiRequestConfig()
    /// nested | delimited
    public var format = "nested"
    public var roadsPath = "$.data.roads[*]"
    public var roadNamePath = "$.name"
    public var episodesPath = "$.episodes[*]"
    public var episodeNamePath = "$.name"
    public var episodeUrlPath = "$.url"
    public var roadNamesPath = ""
    public var roadEpisodesPath = ""
    public var roadSeparator = "$$$"
    public var episodeSeparator = "#"
    public var fieldSeparator = "$"
    public var variables: [String: String] = [:]
    public var episodePage: ApiEpisodePageConfig? = nil

    public init() {}

    init(json: [String: Any]) {
        request = ApiRequestConfig(json: (json["request"] as? [String: Any]) ?? [:])
        format = (json["format"] as? String) == "delimited" ? "delimited" : "nested"
        roadsPath = (json["roadsPath"] as? String) ?? "$.data.roads[*]"
        roadNamePath = (json["roadNamePath"] as? String) ?? "$.name"
        episodesPath = (json["episodesPath"] as? String) ?? "$.episodes[*]"
        episodeNamePath = (json["episodeNamePath"] as? String) ?? "$.name"
        episodeUrlPath = (json["episodeUrlPath"] as? String) ?? "$.url"
        roadNamesPath = (json["roadNamesPath"] as? String) ?? ""
        roadEpisodesPath = (json["roadEpisodesPath"] as? String) ?? ""
        roadSeparator = (json["roadSeparator"] as? String) ?? "$$$"
        episodeSeparator = (json["episodeSeparator"] as? String) ?? "#"
        fieldSeparator = (json["fieldSeparator"] as? String) ?? "$"
        if let vars = json["variables"] as? [String: Any] {
            variables = vars.mapValues { "\($0)" }
        }
        if let page = json["episodePage"] as? [String: Any] {
            episodePage = ApiEpisodePageConfig(json: page)
        }
    }
}

/// Subset of the anti-crawler config used to detect challenge pages. Solving
/// challenges needs a WebView, which tvOS lacks; the TV reports them instead.
public struct AntiCrawlerConfig: Sendable, Equatable {
    public var enabled = false
    /// 1 = xpath, 2 = text, 3 = regex
    public var captchaDetectType = 1
    public var captchaDetectValue = ""
    public var captchaImage = ""
    public var captchaButton = ""
    /// 1 = image captcha typed by the user, 2 = click a button, 3 = custom script
    public var captchaType = 1
    public var captchaInput = ""
    public var captchaScript = ""

    public init() {}

    init(json: [String: Any]) {
        enabled = (json["enabled"] as? NSNumber)?.boolValue ?? false
        captchaDetectType = (json["captchaDetectType"] as? NSNumber)?.intValue ?? 1
        captchaDetectValue = (json["captchaDetectValue"] as? String) ?? ""
        captchaImage = (json["captchaImage"] as? String) ?? ""
        captchaButton = (json["captchaButton"] as? String) ?? ""
        captchaType = (json["captchaType"] as? NSNumber)?.intValue ?? 1
        captchaInput = (json["captchaInput"] as? String) ?? ""
        captchaScript = (json["captchaScript"] as? String) ?? ""
    }
}

/// A Kazumi source rule. Field names and defaults follow `Plugin.fromJson`
/// in lib/plugins/plugins.dart so rule files are shared with the Kazumi app.
public struct Plugin: Sendable, Equatable, Identifiable {
    public var id: String { name.lowercased() }
    public var api: String
    public var type: String
    public var name: String
    public var version: String
    public var muliSources: Bool
    public var useWebview: Bool
    public var useNativePlayer: Bool
    public var usePost: Bool
    public var useLegacyParser: Bool
    public var adBlocker: Bool
    public var userAgent: String
    public var baseURL: String
    public var searchURL: String
    public var searchList: String
    public var searchName: String
    public var searchResult: String
    public var chapterRoads: String
    public var chapterResult: String
    public var referer: String
    public var searchMode: RuleMode
    public var chapterMode: RuleMode
    public var searchApiConfig: ApiSearchConfig
    public var chapterApiConfig: ApiChapterConfig
    public var antiCrawlerConfig: AntiCrawlerConfig
    /// The raw rule JSON, kept so it can be stored and re-parsed unchanged.
    public var rawJSON: Data

    public init(jsonData: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw KazumiError.invalidRule("规则不是 JSON 对象")
        }
        func str(_ key: String, _ def: String = "") -> String {
            if let s = json[key] as? String { return s }
            if let n = json[key] as? NSNumber, !isBoolNumber(n) { return stringify(n) }
            return def
        }
        func bool(_ key: String, _ def: Bool) -> Bool {
            if let n = json[key] as? NSNumber { return n.boolValue }
            return def
        }
        api = str("api", "1")
        type = str("type", "anime")
        name = str("name")
        version = str("version")
        muliSources = bool("muliSources", true)
        useWebview = bool("useWebview", true)
        useNativePlayer = bool("useNativePlayer", true)
        usePost = bool("usePost", false)
        useLegacyParser = bool("useLegacyParser", false)
        adBlocker = bool("adBlocker", false)
        userAgent = str("userAgent")
        baseURL = str("baseURL")
        searchURL = str("searchURL")
        searchList = str("searchList")
        searchName = str("searchName")
        searchResult = str("searchResult")
        chapterRoads = str("chapterRoads")
        chapterResult = str("chapterResult")
        referer = str("referer")
        searchMode = RuleMode.normalize(json["searchMode"])
        chapterMode = RuleMode.normalize(json["chapterMode"])
        searchApiConfig = (json["searchApiConfig"] as? [String: Any]).map(ApiSearchConfig.init(json:)) ?? ApiSearchConfig()
        chapterApiConfig = (json["chapterApiConfig"] as? [String: Any]).map(ApiChapterConfig.init(json:)) ?? ApiChapterConfig()
        antiCrawlerConfig = (json["antiCrawlerConfig"] as? [String: Any]).map(AntiCrawlerConfig.init(json:)) ?? AntiCrawlerConfig()
        rawJSON = jsonData
        if name.isEmpty { throw KazumiError.invalidRule("规则缺少 name") }
    }
}

public struct SearchItem: Sendable, Hashable, Identifiable {
    public var id: String { src }
    public let name: String
    public let src: String
    public init(name: String, src: String) {
        self.name = name
        self.src = src
    }
}

/// A playback line ("线路") with its episodes.
public struct Road: Sendable, Hashable, Identifiable {
    public var id: String { name + (urls.first ?? "") }
    public let name: String
    public let urls: [String]
    public let episodeNames: [String]
    public init(name: String, urls: [String], episodeNames: [String]) {
        self.name = name
        self.urls = urls
        self.episodeNames = episodeNames
    }
}

public enum KazumiError: Error, LocalizedError, Sendable, Equatable {
    case invalidRule(String)
    case invalidURL(String)
    case http(Int, String)
    case network(String)
    case captchaRequired(String)
    case noResult(String)
    case parse(String)
    case videoSourceNotFound(String)
    case resolverUnavailable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidRule(let m): return "规则无效：\(m)"
        case .invalidURL(let u): return "URL 无效：\(u)"
        case .http(let code, let u): return "HTTP \(code)：\(u)"
        case .network(let m): return "网络错误：\(m)"
        case .captchaRequired(let p): return "\(p) 需要人机验证，Apple TV 上暂不支持"
        case .noResult(let p): return "\(p) 没有搜索结果"
        case .parse(let m): return "解析失败：\(m)"
        case .videoSourceNotFound(let m): return "未找到视频地址：\(m)"
        case .resolverUnavailable(let m): return "伴随解析器不可用：\(m)"
        case .cancelled: return "已取消"
        }
    }
}
