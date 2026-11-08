import SwiftUI
import KazumiCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var trendingPath = NavigationPath()
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $trendingPath) { TrendingView() }
                .tag(0)
                .tabItem { Label("推荐", systemImage: "flame") }
            NavigationStack { CalendarView() }
                .tag(1)
                .tabItem { Label("时间表", systemImage: "calendar") }
            NavigationStack { SearchView() }
                .tag(2)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            NavigationStack { LibraryView() }
                .tag(3)
                .tabItem { Label("追番与历史", systemImage: "play.rectangle.on.rectangle") }
            NavigationStack { SettingsView() }
                .tag(4)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .task { await openSubjectFromLaunchArguments() }
        .onOpenURL { url in
            // From the Top Shelf: kazumitv://subject/<id>?resume=1
            guard let target = TopShelfShared.parse(url) else { return }
            Task {
                var subject = model.historyEntries.first(where: { $0.subject.id == target.subjectID })?.subject
                if subject == nil { subject = try? await model.bangumi.subject(target.subjectID) }
                guard let s = subject else { return }
                tab = 0
                trendingPath = NavigationPath()
                trendingPath.append(SubjectRoute(subject: s, autoResume: target.resume))
            }
        }
    }

    /// `-openSubject <bangumi id>` opens a show on launch (used for CI screenshots).
    private func openSubjectFromLaunchArguments() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-openSubject"), i + 1 < args.count, let id = Int(args[i + 1]),
              let subject = try? await model.bangumi.subject(id) else { return }
        trendingPath.append(SubjectRoute(subject: subject))
    }
}

/// Destination value for navigating to a show.
struct SubjectRoute: Hashable {
    let subject: BangumiSubject
    var autoResume = false
}

extension View {
    func subjectNavigation() -> some View {
        navigationDestination(for: SubjectRoute.self) { route in
            SubjectDetailView(subject: route.subject, autoResume: route.autoResume)
        }
    }
}
