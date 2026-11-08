import Foundation

/// Data shared between the app and its Top Shelf extension through an App Group.
enum TopShelfShared {
    static let appGroup = "group.io.github.ericcartman9969.kazumitv"
    static let urlScheme = "kazumitv"
    private static let key = "topshelf.items.v1"

    struct Item: Codable {
        let subjectID: Int
        let title: String
        let subtitle: String
        let image: String
    }

    static func write(_ items: [Item]) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }

    static func read() -> [Item] {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items
    }

    /// kazumitv://subject/<id>?resume=1
    static func url(subjectID: Int, resume: Bool) -> URL {
        URL(string: "\(urlScheme)://subject/\(subjectID)\(resume ? "?resume=1" : "")")!
    }

    static func parse(_ url: URL) -> (subjectID: Int, resume: Bool)? {
        guard url.scheme == urlScheme, url.host == "subject", let id = Int(url.lastPathComponent) else { return nil }
        return (id, url.query?.contains("resume=1") == true)
    }
}
