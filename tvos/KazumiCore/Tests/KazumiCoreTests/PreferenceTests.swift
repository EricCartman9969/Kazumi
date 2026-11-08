import XCTest
@testable import KazumiCore

final class PreferenceTests: XCTestCase {
    func testSourceMatcherPrefersSameSeason() {
        let items = [SearchItem(name: "葬送的芙莉莲 第二季", src: "a"), SearchItem(name: "葬送的芙莉莲", src: "b"),
                     SearchItem(name: "芙莉莲剧场版", src: "c")]
        XCTAssertEqual(SourceMatcher.best(items, titles: ["葬送的芙莉莲", "葬送のフリーレン"])?.src, "b")
        XCTAssertEqual(SourceMatcher.best(items, titles: ["葬送的芙莉莲 第二季"])?.src, "a")
        XCTAssertNil(SourceMatcher.best([SearchItem(name: "完全无关", src: "x")], titles: ["葬送的芙莉莲"]))
    }

    func testPreferencesRoundTrip() {
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        let p = PlaybackPreferences(defaults: d)
        p.recordResolve(pluginName: "A", success: true)
        p.recordResolve(pluginName: "B", success: false)
        XCTAssertGreaterThan(p.score(for: "A"), p.score(for: "B"))
        p.setPreferredSource(PreferredSource(pluginName: "A", sourceURL: "/x", itemName: "n"), subjectID: 2)
        XCTAssertEqual(p.preferredSource(subjectID: 2)?.sourceURL, "/x")
        let c = PluginCookieStore(defaults: d)
        c.set(PluginCookie(cookie: "a=b", userAgent: "UA"), for: "MuteFun")
        XCTAssertEqual(c.cookie(for: "mutefun")?.cookie, "a=b")
    }

    struct CountingResolver: VideoSourceResolver {
        let name = "count"
        let counter: Counter
        final class Counter: @unchecked Sendable { var n = 0 }
        func resolve(episodeURL: String, plugin: Plugin) async throws -> VideoSource {
            counter.n += 1
            return VideoSource(url: episodeURL + ".m3u8", headers: [:], resolvedBy: name)
        }
    }

    func testCachingResolver() async throws {
        let plugin = try Plugin(jsonData: #"{"name":"p"}"#.data(using: .utf8)!)
        let counter = CountingResolver.Counter()
        let cache = CachingVideoResolver(CountingResolver(counter: counter))
        _ = try await cache.resolve(episodeURL: "u", plugin: plugin)
        await cache.prefetch(episodeURL: "u", plugin: plugin)
        _ = try await cache.resolve(episodeURL: "v", plugin: plugin)
        XCTAssertEqual(counter.n, 2)
    }

    func testRuleEngineSendsStoredCookies() async throws {
        final class Spy: HTTPClient, @unchecked Sendable {
            var last: HTTPRequest?
            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                last = request
                return HTTPResponse(status: 200, url: URL(string: request.url)!, headers: [:],
                                    data: Data(#"<html><body><div class="i"><a href="/1">A</a></div></body></html>"#.utf8))
            }
        }
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        let cookies = PluginCookieStore(defaults: d)
        cookies.set(PluginCookie(cookie: "cf=1", userAgent: "VerifiedUA"), for: "p")
        let spy = Spy()
        let json = #"{"name":"p","baseURL":"https://s.com","searchURL":"https://s.com/s?q=@keyword","searchList":"//div[@class='i']","searchName":"//a","searchResult":"//a"}"#
        let plugin = try Plugin(jsonData: json.data(using: .utf8)!)
        let items = try await RuleEngine(http: spy, cookies: cookies).search(plugin, keyword: "x")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(spy.last?.headers["cookie"], "cf=1")
        XCTAssertEqual(spy.last?.headers["user-agent"], "VerifiedUA")
    }
}
