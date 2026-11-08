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
}

struct SubjectDetailView: View {
    @EnvironmentObject var model: AppModel
    @State var subject: BangumiSubject

    @State private var sourceStates: [String: SourceSearchState] = [:]
    @State private var selection: (plugin: Plugin, item: SearchItem)?
    @State private var roads: [Road] = []
    @State private var roadIndex = 0
    @State private var loadingRoads = false
    @State private var roadsError: String?
    @State private var playRequest: PlayRequest?
    @State private var searchStarted = false

    init(subject: BangumiSubject) {
        _subject = State(initialValue: subject)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 50) {
                header
                if let entry = model.historyEntries.first(where: { $0.subject.id == subject.id }) {
                    resumeButton(entry)
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
        .task { if !searchStarted { searchStarted = true; await searchSources() } }
        .fullScreenCover(item: $playRequest) { request in
            PlayerScreen(request: request, model: model)
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
                Button("重新搜索") { Task { await searchSources() } }
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

    private func searchSources() async {
        let keyword = subject.nameCN.isEmpty ? subject.name : subject.nameCN
        let plugins = model.enabledPlugins
        let engine = model.engine
        for p in plugins { sourceStates[p.id] = .searching }
        await withTaskGroup(of: (String, SourceSearchState).self) { group in
            for p in plugins {
                group.addTask {
                    do {
                        let items = try await engine.search(p, keyword: keyword)
                        return (p.id, .found(items))
                    } catch {
                        return (p.id, .failed(error.localizedDescription))
                    }
                }
            }
            for await (id, state) in group { sourceStates[id] = state }
        }
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
