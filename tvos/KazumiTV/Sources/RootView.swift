import SwiftUI
import KazumiCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var trendingPath = NavigationPath()

    var body: some View {
        TabView {
            NavigationStack(path: $trendingPath) { TrendingView() }
                .tabItem { Label("推荐", systemImage: "flame") }
            NavigationStack { CalendarView() }
                .tabItem { Label("时间表", systemImage: "calendar") }
            NavigationStack { SearchView() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            NavigationStack { LibraryView() }
                .tabItem { Label("追番与历史", systemImage: "play.rectangle.on.rectangle") }
            NavigationStack { SettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .task { await openSubjectFromLaunchArguments() }
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
}

extension View {
    func subjectNavigation() -> some View {
        navigationDestination(for: SubjectRoute.self) { route in
            SubjectDetailView(subject: route.subject)
        }
    }
}
