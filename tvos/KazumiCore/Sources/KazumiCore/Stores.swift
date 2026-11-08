import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Entry in the KazumiRules catalog (index.json).
public struct RuleCatalogItem: Sendable, Hashable, Identifiable {
    public var id: String { name.lowercased() }
    public let name: String
    public let version: String
    public let antiCrawlerEnabled: Bool
    public let lastUpdate: Int
}

/// Downloads rules from Predidit/KazumiRules, the same repository the Kazumi
/// app uses, and keeps the installed set in UserDefaults.
public final class PluginStore: @unchecked Sendable {
    public static let defaultRepository = "https://raw.githubusercontent.com/Predidit/KazumiRules/main/"
    /// Mirror used by Kazumi for networks where raw.githubusercontent.com is slow.
    public static let mirrorRepository = "https://ghfast.top/https://raw.githubusercontent.com/Predidit/KazumiRules/main/"

    private let defaults: UserDefaults
    private let key = "kazumi.plugins.v1"
    private let disabledKey = "kazumi.plugins.disabled.v1"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var plugins: [Plugin] {
        lock.lock(); defer { lock.unlock() }
        let raw = (defaults.array(forKey: key) as? [Data]) ?? []
        return raw.compactMap { try? Plugin(jsonData: $0) }
    }

    public var disabled: Set<String> {
        get { Set((defaults.array(forKey: disabledKey) as? [String]) ?? []) }
        set { defaults.set(Array(newValue), forKey: disabledKey) }
    }

    public var enabledPlugins: [Plugin] {
        let off = disabled
        return plugins.filter { !off.contains($0.id) }
    }

    public func save(_ plugins: [Plugin]) {
        lock.lock(); defer { lock.unlock() }
        defaults.set(plugins.map(\.rawJSON), forKey: key)
    }

    public func install(_ plugin: Plugin) {
        var all = plugins.filter { $0.id != plugin.id }
        all.append(plugin)
        save(all.sorted { $0.name.lowercased() < $1.name.lowercased() })
    }

    public func remove(_ id: String) { save(plugins.filter { $0.id != id }) }

    public func catalog(repository: String = defaultRepository) async throws -> [RuleCatalogItem] {
        let data = try await fetch(repository + "index.json")
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw KazumiError.parse("规则目录格式错误")
        }
        return list.compactMap { o in
            guard let name = o["name"] as? String else { return nil }
            return RuleCatalogItem(name: name, version: stringify(o["version"]),
                                   antiCrawlerEnabled: (o["antiCrawlerEnabled"] as? NSNumber)?.boolValue ?? false,
                                   lastUpdate: (o["lastUpdate"] as? NSNumber)?.intValue ?? 0)
        }
    }

    public func download(_ name: String, repository: String = defaultRepository) async throws -> Plugin {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return try Plugin(jsonData: try await fetch(repository + encoded + ".json"))
    }

    /// Installs every rule in the catalog (first run) or updates installed
    /// rules whose catalog version changed. Returns the number changed.
    @discardableResult
    public func syncAll(repository: String = defaultRepository, installMissing: Bool) async throws -> Int {
        let items = try await catalog(repository: repository)
        let installed = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = 0
        try await withThrowingTaskGroup(of: Plugin?.self) { group in
            for item in items {
                if let have = installed[item.id], have.version == item.version { continue }
                if installed[item.id] == nil && !installMissing { continue }
                group.addTask { try? await self.download(item.name, repository: repository) }
            }
            for try await p in group {
                if let p { install(p); changed += 1 }
            }
        }
        return changed
    }

    private func fetch(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw KazumiError.invalidURL(url) }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw KazumiError.http(status, url) }
            return data
        } catch let e as KazumiError { throw e } catch { throw KazumiError.network(error.localizedDescription) }
    }
}

/// One watched episode. Keyed by subject + plugin so a show can be resumed
/// from the source it was last watched on.
public struct HistoryEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(subject.id)|\(pluginName)" }
    public var subject: BangumiSubject
    public var pluginName: String
    public var sourceURL: String
    public var roadIndex: Int
    public var episodeIndex: Int
    public var episodeName: String
    public var episodeURL: String
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public init(subject: BangumiSubject, pluginName: String, sourceURL: String, roadIndex: Int, episodeIndex: Int,
                episodeName: String, episodeURL: String, position: Double, duration: Double, updatedAt: Date = Date()) {
        self.subject = subject; self.pluginName = pluginName; self.sourceURL = sourceURL
        self.roadIndex = roadIndex; self.episodeIndex = episodeIndex; self.episodeName = episodeName
        self.episodeURL = episodeURL; self.position = position; self.duration = duration; self.updatedAt = updatedAt
    }
}

/// Watch history in UserDefaults (tvOS has no guaranteed persistent file
/// storage). Capped so it stays well inside the tvOS UserDefaults budget.
public final class HistoryStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "kazumi.history.v1"
    private let positionsKey = "kazumi.positions.v1"
    private let cap = 200
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var entries: [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func record(_ entry: HistoryEntry) {
        var list = entries.filter { $0.subject.id != entry.subject.id }
        list.insert(entry, at: 0)
        if list.count > cap { list = Array(list.prefix(cap)) }
        lock.lock(); defer { lock.unlock() }
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
        var positions = (defaults.dictionary(forKey: positionsKey) as? [String: Double]) ?? [:]
        positions[entry.episodeURL] = entry.position
        if positions.count > 2000 { positions = [entry.episodeURL: entry.position] }
        defaults.set(positions, forKey: positionsKey)
    }

    public func latest(forSubject id: Int) -> HistoryEntry? { entries.first { $0.subject.id == id } }

    /// Saved position for a specific episode page, used to resume.
    public func position(for episodeURL: String) -> Double {
        ((defaults.dictionary(forKey: positionsKey) as? [String: Double]) ?? [:])[episodeURL] ?? 0
    }

    public func remove(subjectID: Int) {
        let list = entries.filter { $0.subject.id != subjectID }
        lock.lock(); defer { lock.unlock() }
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: positionsKey)
    }
}

/// Followed shows ("追番").
public final class FavoritesStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "kazumi.favorites.v1"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var subjects: [BangumiSubject] {
        guard let d = defaults.data(forKey: key), let l = try? JSONDecoder().decode([BangumiSubject].self, from: d) else { return [] }
        return l
    }
    public func contains(_ id: Int) -> Bool { subjects.contains { $0.id == id } }
    public func toggle(_ s: BangumiSubject) {
        var l = subjects
        if let i = l.firstIndex(where: { $0.id == s.id }) { l.remove(at: i) } else { l.insert(s, at: 0) }
        defaults.set(try? JSONEncoder().encode(l), forKey: key)
    }
}
