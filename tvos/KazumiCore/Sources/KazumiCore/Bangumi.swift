import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Bangumi (bgm.tv) anime subject; the catalog Kazumi browses and searches.
public struct BangumiSubject: Sendable, Hashable, Identifiable, Codable {
    public let id: Int
    public let name: String
    public let nameCN: String
    public let image: String
    public let score: Double
    public let rank: Int
    public let info: String
    public var summary: String
    public var tags: [String]
    public var eps: Int

    public var displayName: String { nameCN.isEmpty ? name : nameCN }

    public init(id: Int, name: String, nameCN: String, image: String, score: Double, rank: Int,
                info: String, summary: String = "", tags: [String] = [], eps: Int = 0) {
        self.id = id; self.name = name; self.nameCN = nameCN; self.image = image
        self.score = score; self.rank = rank; self.info = info
        self.summary = summary; self.tags = tags; self.eps = eps
    }

    /// Parses both the next.bgm.tv (`nameCN`, `metaTags`) and the v0 API
    /// (`name_cn`, `tags`) shapes.
    init?(json: [String: Any]) {
        guard let id = (json["id"] as? NSNumber)?.intValue else { return nil }
        self.id = id
        name = (json["name"] as? String) ?? ""
        nameCN = (json["nameCN"] as? String) ?? (json["name_cn"] as? String) ?? ""
        let images = json["images"] as? [String: Any]
        image = (images?["common"] as? String) ?? (images?["large"] as? String) ?? (json["image"] as? String) ?? ""
        let rating = json["rating"] as? [String: Any]
        score = (rating?["score"] as? NSNumber)?.doubleValue ?? 0
        rank = (rating?["rank"] as? NSNumber)?.intValue ?? 0
        info = (json["info"] as? String) ?? [json["date"] as? String, json["platform"] as? String].compactMap { $0 }.joined(separator: " / ")
        summary = (json["summary"] as? String) ?? ""
        if let meta = json["metaTags"] as? [String] { tags = meta }
        else if let meta = json["meta_tags"] as? [String], !meta.isEmpty { tags = meta }
        else { tags = ((json["tags"] as? [[String: Any]]) ?? []).prefix(8).compactMap { $0["name"] as? String } }
        eps = (json["total_episodes"] as? NSNumber)?.intValue ?? (json["eps"] as? NSNumber)?.intValue ?? 0
    }
}

public struct BangumiAPI: Sendable {
    public static let userAgent = "EricCartman9969/KazumiTV/0.1 (https://github.com/EricCartman9969/Kazumi)"
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    private func json(_ url: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any {
        guard let u = URL(string: url) else { throw KazumiError.invalidURL(url) }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) } catch { throw KazumiError.network(error.localizedDescription) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw KazumiError.http(status, url) }
        return try JSONSerialization.jsonObject(with: data)
    }

    public func trending(limit: Int = 24, offset: Int = 0) async throws -> [BangumiSubject] {
        let obj = try await json("https://next.bgm.tv/p1/trending/subjects?type=2&limit=\(limit)&offset=\(offset)")
        let list = ((obj as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return list.compactMap { ($0["subject"] as? [String: Any]).flatMap(BangumiSubject.init(json:)) }
    }

    /// Weekly airing calendar, index 0 = Monday.
    public func calendar() async throws -> [[BangumiSubject]] {
        let obj = (try await json("https://next.bgm.tv/p1/calendar") as? [String: Any]) ?? [:]
        return (1...7).map { day in
            ((obj["\(day)"] as? [[String: Any]]) ?? []).compactMap { ($0["subject"] as? [String: Any]).flatMap(BangumiSubject.init(json:)) }
        }
    }

    public func search(_ keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [BangumiSubject] {
        let obj = try await json("https://api.bgm.tv/v0/search/subjects?limit=\(limit)&offset=\(offset)", method: "POST",
                                 body: ["keyword": keyword, "sort": "match", "filter": ["type": [2]]])
        let list = ((obj as? [String: Any])?["data"] as? [[String: Any]]) ?? []
        return list.compactMap(BangumiSubject.init(json:))
    }

    public func subject(_ id: Int) async throws -> BangumiSubject {
        let obj = try await json("https://api.bgm.tv/v0/subjects/\(id)")
        guard let dict = obj as? [String: Any], let s = BangumiSubject(json: dict) else { throw KazumiError.parse("Bangumi 条目 \(id)") }
        return s
    }
}
