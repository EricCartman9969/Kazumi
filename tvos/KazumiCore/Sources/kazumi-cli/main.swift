import Foundation
import KazumiCore

// Small CLI to exercise the core against live rules:
//   kazumi-cli search <rule.json> <keyword>
//   kazumi-cli chapters <rule.json> <detail-url>
//   kazumi-cli resolve <rule.json> <episode-url> [resolver-url]
let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: kazumi-cli search|chapters|resolve <rule.json> <arg> [resolver]")
    exit(2)
}
let plugin = try Plugin(jsonData: Data(contentsOf: URL(fileURLWithPath: args[2])))
let engine = RuleEngine()
do {
    switch args[1] {
    case "search":
        for item in try await engine.search(plugin, keyword: args[3]) { print("\(item.name)\t\(item.src)") }
    case "chapters":
        for road in try await engine.chapters(plugin, source: args[3]) {
            print("== \(road.name) (\(road.urls.count))")
            for (n, u) in zip(road.episodeNames, road.urls).prefix(3) { print("  \(n)\t\(u)") }
        }
    case "resolve":
        var resolvers: [VideoSourceResolver] = [StaticVideoResolver()]
        if args.count > 4 { resolvers.append(CompanionVideoResolver(endpoint: args[4], token: nil)) }
        let source = try await ChainVideoResolver(resolvers).resolve(episodeURL: args[3], plugin: plugin)
        print("\(source.resolvedBy)\t\(source.url)")
    default:
        print("unknown command")
    }
} catch {
    print("ERROR: \(error.localizedDescription)")
    exit(1)
}
