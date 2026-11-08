import Foundation
import SwiftUI
import KazumiCore
import TVServices

/// How the TV gets the video address out of an episode page.
enum ResolveMode: String, CaseIterable, Identifiable {
    /// Try on-device extraction first, then the companion resolver.
    case auto
    case staticOnly
    case companionOnly

    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "自动（先本机，失败后用伴随解析器）"
        case .staticOnly: return "仅本机解析"
        case .companionOnly: return "仅伴随解析器"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let pluginStore = PluginStore()
    let history = HistoryStore()
    let favorites = FavoritesStore()
    let cookies = PluginCookieStore()
    let prefs = PlaybackPreferences()
    let engine: RuleEngine
    let bangumi = BangumiAPI()
    let discovery = ResolverDiscovery()
    /// Shared resolver with a short-lived cache; rebuilt when settings change.
    private(set) var resolver: CachingVideoResolver

    init() {
        engine = RuleEngine(cookies: cookies)
        resolver = CachingVideoResolver(StaticVideoResolver())
        rebuildResolver()
    }

    @Published var plugins: [Plugin] = []
    @Published var disabledPlugins: Set<String> = []
    @Published var historyEntries: [HistoryEntry] = []
    @Published var favoriteSubjects: [BangumiSubject] = []
    @Published var ruleSyncMessage: String?
    @Published var isSyncingRules = false

    @Published var resolverURL: String = UserDefaults.standard.string(forKey: "resolver.url") ?? "" {
        didSet { UserDefaults.standard.set(resolverURL, forKey: "resolver.url"); rebuildResolver() }
    }
    @Published var resolverToken: String = UserDefaults.standard.string(forKey: "resolver.token") ?? "" {
        didSet { UserDefaults.standard.set(resolverToken, forKey: "resolver.token"); rebuildResolver() }
    }
    @Published var resolveMode: ResolveMode = ResolveMode(rawValue: UserDefaults.standard.string(forKey: "resolver.mode") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(resolveMode.rawValue, forKey: "resolver.mode"); rebuildResolver() }
    }
    @Published var globalAdFilter: Bool = UserDefaults.standard.object(forKey: "player.adFilter") as? Bool ?? true {
        didSet { UserDefaults.standard.set(globalAdFilter, forKey: "player.adFilter") }
    }
    @Published var autoNext: Bool = UserDefaults.standard.object(forKey: "player.autoNext") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoNext, forKey: "player.autoNext") }
    }
    @Published var useRuleMirror: Bool = UserDefaults.standard.bool(forKey: "rules.mirror") {
        didSet { UserDefaults.standard.set(useRuleMirror, forKey: "rules.mirror") }
    }

    var ruleRepository: String { useRuleMirror ? PluginStore.mirrorRepository : PluginStore.defaultRepository }

    var enabledPlugins: [Plugin] { plugins.filter { !disabledPlugins.contains($0.id) } }

    var companion: CompanionVideoResolver? {
        let url = resolverURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return nil }
        return CompanionVideoResolver(endpoint: url.hasPrefix("http") ? url : "http://" + url, token: resolverToken)
    }

    private func rebuildResolver() {
        var chain: [VideoSourceResolver] = []
        if resolveMode != .companionOnly { chain.append(StaticVideoResolver()) }
        if resolveMode != .staticOnly, let companion { chain.append(companion) }
        if chain.isEmpty { chain.append(StaticVideoResolver()) }
        resolver = CachingVideoResolver(ChainVideoResolver(chain))
    }

    /// Extra context appended to "video not found" errors.
    var resolveFailureHint: String? {
        if resolveMode == .staticOnly { return "当前设置为仅本机解析，可以在设置里改为自动并配置伴随解析器。" }
        if companion == nil { return "还没有配置伴随解析器，很多片源需要它才能解析。可在 设置 > 伴随解析器 中配置。" }
        return nil
    }

    func bootstrap() async {
        reload()
        publishTopShelf()
        // Pick up a resolver on the LAN automatically when none is configured.
        if resolverURL.isEmpty {
            Task {
                if let found = await discovery.discoverOnce(timeout: 6), resolverURL.isEmpty {
                    resolverURL = found.url
                }
            }
        }
        if plugins.isEmpty {
            await syncRules(installMissing: true)
        } else {
            // Quietly pick up rule updates on launch.
            Task { await syncRules(installMissing: false, quiet: true) }
        }
    }

    func reload() {
        plugins = pluginStore.plugins
        disabledPlugins = pluginStore.disabled
        historyEntries = history.entries
        favoriteSubjects = favorites.subjects
    }

    func syncRules(installMissing: Bool, quiet: Bool = false) async {
        isSyncingRules = true
        defer { isSyncingRules = false }
        do {
            let n = try await pluginStore.syncAll(repository: ruleRepository, installMissing: installMissing)
            if !quiet { ruleSyncMessage = n == 0 ? "规则已是最新" : "已更新 \(n) 条规则" }
        } catch {
            if !quiet { ruleSyncMessage = "规则同步失败：\(error.localizedDescription)" }
        }
        reload()
    }

    func setPlugin(_ id: String, enabled: Bool) {
        var d = pluginStore.disabled
        if enabled { d.remove(id) } else { d.insert(id) }
        pluginStore.disabled = d
        disabledPlugins = d
    }

    func removePlugin(_ id: String) {
        pluginStore.remove(id)
        reload()
    }

    func plugin(named name: String) -> Plugin? { plugins.first { $0.name == name } }

    func toggleFavorite(_ s: BangumiSubject) {
        favorites.toggle(s)
        favoriteSubjects = favorites.subjects
    }

    func record(_ entry: HistoryEntry) {
        let changedShow = historyEntries.first?.subject.id != entry.subject.id
        history.record(entry)
        historyEntries = history.entries
        if changedShow { publishTopShelf() }
    }

    func removeHistory(_ subjectID: Int) {
        history.remove(subjectID: subjectID)
        historyEntries = history.entries
        publishTopShelf()
    }

    /// Shares the recent history with the Top Shelf extension via the app group.
    func publishTopShelf() {
        TopShelfShared.write(historyEntries.prefix(10).map {
            TopShelfShared.Item(subjectID: $0.subject.id, title: $0.subject.displayName,
                                subtitle: $0.episodeName, image: $0.subject.image)
        })
        TVTopShelfContentProvider.topShelfContentDidChange()
    }
}
