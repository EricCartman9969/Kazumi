import Foundation

/// Cookies obtained by solving a rule's anti-crawler check (through the
/// companion resolver). Like Kazumi's PluginCookieManager they are bound to
/// the User-Agent they were issued to, so both are stored together.
public struct PluginCookie: Codable, Sendable, Equatable {
    public let cookie: String
    public let userAgent: String
    public let savedAt: Date
    public init(cookie: String, userAgent: String, savedAt: Date = Date()) {
        self.cookie = cookie; self.userAgent = userAgent; self.savedAt = savedAt
    }
}

public final class PluginCookieStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "kazumi.pluginCookies.v1"
    private let lock = NSLock()
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var all: [String: PluginCookie] {
        guard let d = defaults.data(forKey: key), let m = try? JSONDecoder().decode([String: PluginCookie].self, from: d) else { return [:] }
        return m
    }

    public func cookie(for pluginName: String) -> PluginCookie? {
        lock.lock(); defer { lock.unlock() }
        return all[pluginName.lowercased()]
    }

    public func set(_ cookie: PluginCookie?, for pluginName: String) {
        lock.lock(); defer { lock.unlock() }
        var m = all
        m[pluginName.lowercased()] = cookie
        defaults.set(try? JSONEncoder().encode(m), forKey: key)
    }
}

/// The source a show was last played from, so it can be picked automatically.
public struct PreferredSource: Codable, Sendable, Equatable {
    public let pluginName: String
    public let sourceURL: String
    public let itemName: String
    public init(pluginName: String, sourceURL: String, itemName: String) {
        self.pluginName = pluginName; self.sourceURL = sourceURL; self.itemName = itemName
    }
}

/// Per-show preferred source and per-rule
/// playback success counts used to rank sources.
public final class PlaybackPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let sourcesKey = "kazumi.preferredSources.v1"
    private let statsKey = "kazumi.pluginStats.v1"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func store<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    public func preferredSource(subjectID: Int) -> PreferredSource? {
        lock.lock(); defer { lock.unlock() }
        let m: [String: PreferredSource] = load(sourcesKey) ?? [:]
        return m[String(subjectID)]
    }

    public func setPreferredSource(_ s: PreferredSource, subjectID: Int) {
        lock.lock(); defer { lock.unlock() }
        var m: [String: PreferredSource] = load(sourcesKey) ?? [:]
        m[String(subjectID)] = s
        if m.count > 500 { m = [String(subjectID): s] }
        store(m, sourcesKey)
    }

    public struct Stats: Codable, Sendable { public var success = 0; public var failure = 0 }

    public func stats(for pluginName: String) -> Stats {
        lock.lock(); defer { lock.unlock() }
        let m: [String: Stats] = load(statsKey) ?? [:]
        return m[pluginName.lowercased()] ?? Stats()
    }

    public func recordResolve(pluginName: String, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        var m: [String: Stats] = load(statsKey) ?? [:]
        var s = m[pluginName.lowercased()] ?? Stats()
        if success { s.success += 1 } else { s.failure += 1 }
        m[pluginName.lowercased()] = s
        store(m, statsKey)
    }

    /// Higher is better: smoothed success rate.
    public func score(for pluginName: String) -> Double {
        let s = stats(for: pluginName)
        return (Double(s.success) + 1) / (Double(s.success + s.failure) + 2)
    }
}

/// Picks the search result that best matches a Bangumi title.
public enum SourceMatcher {
    static func normalize(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        return String(String.UnicodeScalarView(s.lowercased().unicodeScalars.filter { !drop.contains($0) }))
    }

    private static let seasonMarkers = ["第二季", "第三季", "第四季", "第五季", "第2季", "第3季", "第4季", "第5季",
                                        "season2", "season3", "s2", "s3", "2nd", "3rd", "续篇", "剧场版", "电影", "ova", "oad", "sp"]

    /// 0...1; 1 for an exact match after normalization.
    public static func score(item: String, titles: [String]) -> Double {
        let n = normalize(item)
        var best = 0.0
        for t in titles where !t.isEmpty {
            let k = normalize(t)
            if k.isEmpty { continue }
            var s: Double
            if n == k { s = 1 }
            else if n.hasPrefix(k) || k.hasPrefix(n) || n.contains(k) { s = 0.8 - min(0.3, Double(abs(n.count - k.count)) * 0.03) }
            else {
                let common = Set(n).intersection(Set(k)).count
                s = 0.5 * Double(common) / Double(max(n.count, k.count))
            }
            // A sequel/movie marker present on one side only is a different work.
            let markersItem = seasonMarkers.filter { n.contains($0) }
            let markersTitle = seasonMarkers.filter { k.contains($0) }
            if Set(markersItem) != Set(markersTitle) { s -= 0.35 }
            best = max(best, s)
        }
        return best
    }

    public static func best(_ items: [SearchItem], titles: [String], threshold: Double = 0.45) -> SearchItem? {
        let ranked = items.map { ($0, score(item: $0.name, titles: titles)) }.sorted { $0.1 > $1.1 }
        guard let top = ranked.first, top.1 >= threshold else { return nil }
        return top.0
    }
}

/// Remembers resolved video addresses for a short time so reopening an
/// episode, or a prefetched next episode, starts without resolving again.
/// Entries expire quickly because many CDNs sign URLs for a few minutes.
public actor CachingVideoResolver: VideoSourceResolver {
    public nonisolated let name = "cache"
    private let inner: VideoSourceResolver
    private let ttl: TimeInterval
    private var cache: [String: (VideoSource, Date)] = [:]
    private var inflight: [String: Task<VideoSource, Error>] = [:]

    public init(_ inner: VideoSourceResolver, ttl: TimeInterval = 240) {
        self.inner = inner
        self.ttl = ttl
    }

    public func resolve(episodeURL: String, plugin: Plugin) async throws -> VideoSource {
        if let (source, at) = cache[episodeURL], Date().timeIntervalSince(at) < ttl { return source }
        if let task = inflight[episodeURL] { return try await task.value }
        let inner = self.inner
        let task = Task { try await inner.resolve(episodeURL: episodeURL, plugin: plugin) }
        inflight[episodeURL] = task
        defer { inflight[episodeURL] = nil }
        let source = try await task.value
        cache[episodeURL] = (source, Date())
        if cache.count > 50 {
            let cutoff = Date().addingTimeInterval(-ttl)
            cache = cache.filter { $0.value.1 > cutoff }
        }
        return source
    }

    /// Resolves in the background and keeps the result; errors are ignored.
    public func prefetch(episodeURL: String, plugin: Plugin) async {
        _ = try? await resolve(episodeURL: episodeURL, plugin: plugin)
    }

    public func invalidate(_ episodeURL: String) { cache[episodeURL] = nil }
}
