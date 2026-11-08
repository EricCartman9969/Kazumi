import SwiftUI
import KazumiCore

/// What the player needs to play one episode and move to the next.
struct PlayRequest: Identifiable {
    let id = UUID()
    let subject: BangumiSubject
    let plugin: Plugin
    let sourceURL: String
    let roads: [Road]
    var roadIndex: Int
    var episodeIndex: Int
}

enum SourceSearchState {
    case searching
    case found([SearchItem])
    case failed(String)
    /// The rule's site showed an anti-crawler check.
    case captcha
}

@MainActor
struct SubjectDetailView: View {
    @EnvironmentObject var model: AppModel
    @State var subject: BangumiSubject
    let autoResume: Bool

    @State private var sourceStates: [String: SourceSearchState] = [:]
    @State private var selection: (plugin: Plugin, item: SearchItem)?
    @State private var roads: [Road] = []
    @State private var roadIndex = 0
    @State private var loadingRoads = false
    @State private var roadsError: String?
    @State private var playRequest: PlayRequest?
    @State private var searchStarted = false
    @State private var searchTask: Task<Void, Never>?
    @State private var autoStatus: String?
    @State private var autoTask: Task<Void, Never>?
    @State private var captchaPlugin: Plugin?

    init(subject: BangumiSubject, autoResume: Bool = false) {
        _subject = State(initialValue: subject)
        self.autoResume = autoResume
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                header
                HStack(spacing: 30) {
                    if let entry = model.historyEntries.first(where: { $0.subject.id == subject.id }) {
                        resumeButton(entry)
                    }
                    Button {
                        startAutoPlay()
                    } label: {
                        Label(autoTask == nil ? "自动选源播放" : "停止自动选源", systemImage: "wand.and.stars")
                    }
                }
                if let autoStatus {
                    Text(autoStatus).foregroundStyle(.secondary)
                }
                if let selection {
                    episodesSection(selection.plugin, selection.item)
                }
                sourcesSection
            }
            .padding(.horizontal, 40)
        }
        .task {
            if subject.summary.isEmpty, let full = try? await model.bangumi.subject(subject.id) {
                subject = full
            }
        }
        .task {
            guard !searchStarted else { return }
            searchStarted = true
            if autoResume, let entry = model.historyEntries.first(where: { $0.subject.id == subject.id }) {
                Task { await resume(entry) }
            }
            startSearch()
        }
        .onDisappear { autoTask?.cancel(); autoTask = nil }
        .fullScreenCover(item: $playRequest) { request in
            PlayerScreen(request: request, model: model)
        }
        .sheet(item: $captchaPlugin) { plugin in
            CaptchaSheet(plugin: plugin, keyword: keyword) {
                captchaPlugin = nil
                Task { await searchOne(plugin) }
            }
            .environmentObject(model)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 50) {
            CoverImage(url: subject.image)
                .frame(width: 300, height: 425)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 16) {
                Text(subject.displayName).font(.title2).bold()
                if !subject.nameCN.isEmpty && subject.name != subject.nameCN {
                    Text(subject.name).foregroundStyle(.secondary)
                }
                HStack(spacing: 24) {
                    if subject.score > 0 { Text(String(format: "★ %.1f", subject.score)) }
                    if subject.rank > 0 { Text("排名 #\(subject.rank)") }
                    if subject.eps > 0 { Text("\(subject.eps) 话") }
                }
                .font(.callout).foregroundStyle(.secondary)
                if !subject.tags.isEmpty {
                    Text(subject.tags.prefix(6).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Text(subject.summary.isEmpty ? subject.info : subject.summary)
                    .font(.callout)
                    .lineLimit(6)
                Button {
                    model.toggleFavorite(subject)
                } label: {
                    let followed = model.favoriteSubjects.contains { $0.id == subject.id }
                    Label(followed ? "已追番" : "追番", systemImage: followed ? "heart.fill" : "heart")
                }
            }
        }
        .padding(.top, 20)
    }

    private func resumeButton(_ entry: HistoryEntry) -> some View {
        Button {
            Task { await resume(entry) }
        } label: {
            Label("继续观看 \(entry.episodeName)（\(entry.pluginName)）", systemImage: "play.fill")
        }
    }

    // MARK: Episodes

    @ViewBuilder
    private func episodesSection(_ plugin: Plugin, _ item: SearchItem) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("\(plugin.name) · \(item.name)").font(.title3)
            if loadingRoads {
                ProgressView()
            } else if let roadsError {
                Text(roadsError).foregroundStyle(.secondary)
            } else if !roads.isEmpty {
                if roads.count > 1 {
                    Picker("线路", selection: $roadIndex) {
                        ForEach(roads.indices, id: \.self) { Text(roads[$0].name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                let road = roads[min(roadIndex, roads.count - 1)]
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 30)], alignment: .leading, spacing: 30) {
                    ForEach(road.urls.indices, id: \.self) { i in
                        Button {
                            playRequest = PlayRequest(subject: subject, plugin: plugin, sourceURL: item.src,
                                                      roads: roads, roadIndex: roadIndex, episodeIndex: i)
                        } label: {
                            Text(road.episodeNames[i]).lineLimit(1).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("片源").font(.title3)
                Spacer()
                Button("重新搜索") { startSearch() }
            }
            if model.enabledPlugins.isEmpty {
                Text(model.isSyncingRules ? "正在下载规则…" : "还没有可用的规则，请到 设置 > 规则 中更新")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.enabledPlugins) { plugin in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 16) {
                        Text(plugin.name).font(.headline)
                        switch sourceStates[plugin.id] {
                        case .searching, nil: ProgressView()
                        case .found(let items): Text("\(items.count) 个结果").font(.caption).foregroundStyle(.secondary)
                        case .failed(let msg): Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        case .captcha:
                            Text("需要人机验证").font(.caption).foregroundStyle(.secondary)
                            Button("去验证") { captchaPlugin = plugin }
                        }
                    }
                    if case .found(let items) = sourceStates[plugin.id] {
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 24) {
                                ForEach(items) { item in
                                    Button {
                                        Task { await select(plugin, item) }
                                    } label: {
                                        Text(item.name).lineLimit(1)
                                    }
                                }
                            }
                            .padding(.vertical, 20)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 60)
    }

    // MARK: Actions

    private var keyword: String { subject.nameCN.isEmpty ? subject.name : subject.nameCN }

    private func startSearch() {
        searchTask?.cancel()
        searchTask = Task { await searchSources() }
    }

    private func searchSources() async {
        let plugins = model.enabledPlugins
        for p in plugins { sourceStates[p.id] = .searching }
        await withTaskGroup(of: Void.self) { group in
            for p in plugins {
                group.addTask { await searchOne(p) }
            }
        }
    }

    private func searchOne(_ p: Plugin) async {
        sourceStates[p.id] = .searching
        let engine = model.engine
        let keyword = self.keyword
        let state: SourceSearchState
        do {
            state = .found(try await engine.search(p, keyword: keyword))
        } catch {
            if let ke = error as? KazumiError, case .captchaRequired = ke {
                state = .captcha
            } else {
                state = .failed(error.localizedDescription)
            }
        }
        sourceStates[p.id] = state
    }

    // MARK: Automatic source selection

    private func startAutoPlay() {
        if let t = autoTask { t.cancel(); autoTask = nil; autoStatus = nil; return }
        autoTask = Task {
            await autoPlay()
            autoTask = nil
        }
    }

    /// Tries sources in order of likelihood until one resolves: the source
    /// this show last played from, then rules ranked by past success, picking
    /// the result whose title best matches the show.
    private func autoPlay() async {
        let titles = [subject.nameCN, subject.name]
        var tried = Set<String>()

        if let pref = model.prefs.preferredSource(subjectID: subject.id), let plugin = model.plugin(named: pref.pluginName),
           !model.disabledPlugins.contains(plugin.id) {
            tried.insert(plugin.id)
            if await tryCandidate(plugin, SearchItem(name: pref.itemName, src: pref.sourceURL)) { return }
        }

        // Wait for searches to finish (or 25 s) before ranking the rest.
        autoStatus = "正在等待片源搜索结果…"
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, sourceStates.values.contains(where: { if case .searching = $0 { return true }; return false }) {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        let ranked = model.enabledPlugins
            .filter { !tried.contains($0.id) }
            .compactMap { p -> (Plugin, SearchItem)? in
                guard case .found(let items) = sourceStates[p.id], let best = SourceMatcher.best(items, titles: titles) else { return nil }
                return (p, best)
            }
            .sorted { model.prefs.score(for: $0.0.name) > model.prefs.score(for: $1.0.name) }

        for (plugin, item) in ranked {
            if Task.isCancelled { return }
            if await tryCandidate(plugin, item) { return }
        }
        if !Task.isCancelled { autoStatus = "没有找到能直接播放的片源，可以在下方手动选择。" }
    }

    private func tryCandidate(_ plugin: Plugin, _ item: SearchItem) async -> Bool {
        autoStatus = "正在尝试 \(plugin.name) · \(item.name)…"
        guard let roads = try? await model.engine.chapters(plugin, source: item.src), let road = roads.first, !road.urls.isEmpty else {
            return false
        }
        // Resume within this source if there is history for it.
        var roadIndex = 0, episodeIndex = 0
        if let entry = model.historyEntries.first(where: { $0.subject.id == subject.id && $0.pluginName == plugin.name && $0.sourceURL == item.src }) {
            roadIndex = min(entry.roadIndex, roads.count - 1)
            episodeIndex = roads[roadIndex].urls.firstIndex(of: entry.episodeURL) ?? min(entry.episodeIndex, roads[roadIndex].urls.count - 1)
        }
        let url = roads[roadIndex].urls[episodeIndex]
        do {
            // The cache keeps the result, so the player starts immediately.
            _ = try await model.resolver.resolve(episodeURL: url, plugin: plugin)
        } catch {
            model.prefs.recordResolve(pluginName: plugin.name, success: false)
            return false
        }
        if Task.isCancelled { return false }
        selection = (plugin, item)
        self.roads = roads
        self.roadIndex = roadIndex
        autoStatus = nil
        playRequest = PlayRequest(subject: subject, plugin: plugin, sourceURL: item.src, roads: roads,
                                  roadIndex: roadIndex, episodeIndex: episodeIndex)
        return true
    }

    private func select(_ plugin: Plugin, _ item: SearchItem) async {
        selection = (plugin, item)
        roads = []
        roadIndex = 0
        roadsError = nil
        loadingRoads = true
        defer { loadingRoads = false }
        do {
            roads = try await model.engine.chapters(plugin, source: item.src)
        } catch {
            roadsError = error.localizedDescription
        }
    }

    private func resume(_ entry: HistoryEntry) async {
        guard let plugin = model.plugin(named: entry.pluginName) else {
            roadsError = "规则 \(entry.pluginName) 已不存在"
            return
        }
        let item = SearchItem(name: entry.subject.displayName, src: entry.sourceURL)
        await select(plugin, item)
        guard !roads.isEmpty else { return }
        let r = min(entry.roadIndex, roads.count - 1)
        roadIndex = r
        // Prefer the stored episode URL in case the list shifted.
        let e = roads[r].urls.firstIndex(of: entry.episodeURL) ?? min(entry.episodeIndex, roads[r].urls.count - 1)
        playRequest = PlayRequest(subject: subject, plugin: plugin, sourceURL: entry.sourceURL, roads: roads, roadIndex: r, episodeIndex: e)
    }
}
