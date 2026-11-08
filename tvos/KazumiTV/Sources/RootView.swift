import SwiftUI
import KazumiCore

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { TrendingView() }
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
