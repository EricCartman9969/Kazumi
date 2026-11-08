import SwiftUI
import KazumiCore

struct TrendingView: View {
    @EnvironmentObject var model: AppModel
    @State private var subjects: [BangumiSubject] = []
    @State private var error: String?
    @State private var loadingMore = false
    @State private var exhausted = false

    var body: some View {
        ScrollView {
            if let error, subjects.isEmpty {
                ErrorView(message: error) { Task { await load(reset: true) } }
            } else if subjects.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 400)
            } else {
                SubjectGrid(subjects: subjects)
                if !exhausted {
                    Button(loadingMore ? "加载中…" : "加载更多") { Task { await load(reset: false) } }
                        .disabled(loadingMore)
                        .padding(.vertical, 40)
                }
            }
        }
        .navigationTitle("热门番剧")
        .subjectNavigation()
        .task { if subjects.isEmpty { await load(reset: true) } }
    }

    private func load(reset: Bool) async {
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await model.bangumi.trending(limit: 24, offset: reset ? 0 : subjects.count)
            let known = Set(subjects.map(\.id))
            subjects = reset ? page : subjects + page.filter { !known.contains($0.id) }
            exhausted = page.isEmpty
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CalendarView: View {
    @EnvironmentObject var model: AppModel
    @State private var days: [[BangumiSubject]] = []
    @State private var selected = (Calendar(identifier: .gregorian).component(.weekday, from: Date()) + 5) % 7
    @State private var error: String?
    private let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    var body: some View {
        ScrollView {
            Picker("星期", selection: $selected) {
                ForEach(0..<7, id: \.self) { Text(names[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.bottom, 40)

            if let error, days.isEmpty {
                ErrorView(message: error) { Task { await load() } }
            } else if days.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 400)
            } else {
                SubjectGrid(subjects: days[selected])
            }
        }
        .navigationTitle("每日放送")
        .subjectNavigation()
        .task { if days.isEmpty { await load() } }
    }

    private func load() async {
        do { days = try await model.bangumi.calendar(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var results: [BangumiSubject] = []
    @State private var searching = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            if searching {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            } else if let error {
                ErrorView(message: error) { run(query) }
            } else if results.isEmpty && !query.isEmpty {
                Text("没有找到「\(query)」").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 300)
            } else {
                SubjectGrid(subjects: results)
            }
        }
        .searchable(text: $query, prompt: "番剧名称")
        .onChange(of: query) { _, q in run(q) }
        .subjectNavigation()
    }

    private func run(_ q: String) {
        searchTask?.cancel()
        let keyword = q.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { results = []; error = nil; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            searching = true
            defer { searching = false }
            do {
                let r = try await model.bangumi.search(keyword)
                if !Task.isCancelled { results = r; error = nil }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                if !model.historyEntries.isEmpty {
                    Text("继续观看").font(.title3).padding(.horizontal, 20)
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 48) {
                            ForEach(model.historyEntries) { entry in
                                PosterCard(subject: entry.subject, subtitle: "\(entry.episodeName) · \(entry.pluginName)")
                                    .contextMenu {
                                        Button("删除记录", role: .destructive) { model.removeHistory(entry.subject.id) }
                                    }
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 30)
                    }
                }
                Text("追番").font(.title3).padding(.horizontal, 20)
                if model.favoriteSubjects.isEmpty {
                    Text("在番剧详情页点「追番」后会显示在这里").foregroundStyle(.secondary).padding(.horizontal, 20)
                } else {
                    SubjectGrid(subjects: model.favoriteSubjects)
                }
            }
        }
        .navigationTitle("追番与历史")
        .subjectNavigation()
        .onAppear { model.reload() }
    }
}
