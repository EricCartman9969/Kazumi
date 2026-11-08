import XCTest
@testable import KazumiCore

final class CoreTests: XCTestCase {
    func testRelativeXPath() {
        XCTAssertEqual(relativeXPath("//div/a"), ".//div/a")
        XCTAssertEqual(relativeXPath("/body/div"), "./body/div")
        XCTAssertEqual(relativeXPath(".//a[contains(@href, '/play/')]"), ".//a[contains(@href, '/play/')]")
        XCTAssertEqual(relativeXPath("//a[@x='a|b'] | //b"), ".//a[@x='a|b'] | .//b")
    }

    func testXPathParsingIsRelativeToNode() throws {
        let html = """
        <html><body><div class="list"><div class="item"><h5><a href="/v/1">One</a></h5></div>
        <div class="item"><h5><a href="/v/2">Two</a></h5></div></div><h5><a href="/x">Outside</a></h5></body></html>
        """
        var json: [String: Any] = ["name": "t", "baseURL": "https://ex.com/", "searchURL": "https://ex.com/s?wd=@keyword",
                                   "searchList": "//div[@class='item']", "searchName": "//h5/a", "searchResult": "//h5/a",
                                   "chapterRoads": "//div[@class='list']", "chapterResult": "//a"]
        let plugin = try Plugin(jsonData: JSONSerialization.data(withJSONObject: json))
        let items = try XPathRuleStrategy().parseSearch(html, plugin: plugin)
        XCTAssertEqual(items, [SearchItem(name: "One", src: "/v/1"), SearchItem(name: "Two", src: "/v/2")])
        let roads = try XPathRuleStrategy().parseChapters(html, plugin: plugin)
        XCTAssertEqual(roads.first?.urls, ["https://ex.com/v/1", "https://ex.com/v/2"])
        json["usePost"] = true
        let post = try XPathRuleStrategy().prepareSearchRequest(try Plugin(jsonData: JSONSerialization.data(withJSONObject: json)), keyword: "a b")
        XCTAssertEqual(post.method, "POST")
        XCTAssertEqual(post.url, "https://ex.com/s")
    }

    func testNormalizeEpisodeURL() {
        XCTAssertEqual(normalizeEpisodeURL(baseURL: "https://a.com/", raw: "/play/1-1/"), "https://a.com/play/1-1")
        XCTAssertEqual(normalizeEpisodeURL(baseURL: "https://a.com/", raw: "http://a.com/x?"), "https://a.com/x")
        XCTAssertEqual(normalizeEpisodeURL(baseURL: "https://a.com/", raw: "http://b.com/x/"), "http://b.com/x")
        XCTAssertEqual(normalizeEpisodeURL(baseURL: "https://a.com/", raw: "  "), "")
        let once = normalizeEpisodeURL(baseURL: "https://a.com/", raw: "v/2/")
        XCTAssertEqual(normalizeEpisodeURL(baseURL: "https://a.com/", raw: once), once)
    }

    func testJSONPathAndApiSearch() throws {
        let raw = #"{"list":[{"name":"Frieren","id":6067},{"name":"","id":1},{"name":"B","id":"x y"}]}"#
        var config = ApiSearchConfig()
        config.listPath = "$.list[*]"
        config.namePath = "$.name"
        config.sourcePath = "$.id"
        config.sourceTemplate = "https://s.com/detail/@source.html"
        let items = try ApiRuleStrategy().parseSearch(raw, config: config)
        XCTAssertEqual(items, [SearchItem(name: "Frieren", src: "https://s.com/detail/6067.html"),
                               SearchItem(name: "B", src: "https://s.com/detail/x%20y.html")])
        XCTAssertThrowsError(try RestrictedJSONPath.validate("$..name"))
        XCTAssertEqual(try RestrictedJSONPath.read(["a": [["b": 1], ["b": 2]]], "$.a[*]['b']").count, 2)
    }

    func testTemplates() throws {
        let s = ApiRuleStrategy()
        XCTAssertEqual(try s.renderTemplate("https://x/@keyword?q=me@site", ["keyword": "a b"], encode: true), "https://x/a%20b?q=me@site")
        XCTAssertThrowsError(try s.renderTemplate("@missing", [:]))
        XCTAssertEqual(try s.renderValue("@n", ["n": 3]) as? Int, 3)
    }

    func testDelimitedChapters() throws {
        var c = ApiChapterConfig()
        c.format = "delimited"
        c.roadNamesPath = "$.from"
        c.roadEpisodesPath = "$.url"
        let raw = #"{"from":"A$$$B","url":"第1集$/p/1#第2集$/p/2$$$01$https://cdn/1.m3u8"}"#
        let roads = try ApiRuleStrategy().parseChapters(raw, config: c, source: "1", baseURL: "https://s.com/")
        XCTAssertEqual(roads.map(\.name), ["A", "B"])
        XCTAssertEqual(roads[0].urls, ["https://s.com/p/1", "https://s.com/p/2"])
        XCTAssertEqual(roads[1].urls, ["https://cdn/1.m3u8"])
    }

    func testMacCMSPlayer() {
        let page = #"<script>var player_aaaa={"flag":"play","encrypt":2,"vod_data":{"vod_name":"x"},"url":"JTY4JTc0JTc0JTcwJTczJTNBJTJGJTJGJTYxJTJFJTYzJTZGJTZEJTJGJTc4JTJFJTZEJTMzJTc1JTM4","from":"lmm"}</script>"#
        let p = VideoPageScanner.macCMSPlayer(in: page)
        XCTAssertEqual(p?.url, "https://a.com/x.m3u8")
        XCTAssertEqual(p?.from, "lmm")
        let plain = #"var player_abc={"url":"https:\/\/cdn.com\/a\/index.m3u8","encrypt":0,"from":"x"};"#
        XCTAssertEqual(VideoPageScanner.macCMSPlayer(in: plain)?.url, "https://cdn.com/a/index.m3u8")
    }

    func testMediaURLScanning() {
        let base = URL(string: "https://site.com/play/1")!
        let html = #"<script>var a="https:\/\/cdn.x.com\/v\/index.m3u8?t=1"; var ad="https://googleads.g.doubleclick.net/x.mp4"; var r='/hls/2/index.m3u8';</script><iframe src="//p.com/?url=https://c.com/v.mp4"></iframe>"#
        let urls = VideoPageScanner.mediaURLs(in: html, base: base)
        XCTAssertEqual(urls.first, "https://cdn.x.com/v/index.m3u8?t=1")
        XCTAssertTrue(urls.contains("https://site.com/hls/2/index.m3u8"))
        XCTAssertFalse(urls.contains { $0.contains("googleads") })
        let iframes = VideoPageScanner.iframeSources(in: html, base: base)
        XCTAssertEqual(iframes, ["https://p.com/?url=https://c.com/v.mp4"])
        XCTAssertEqual(mediaURLInQuery(iframes[0]), "https://c.com/v.mp4")
    }

    func testM3U8AdFilter() {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:10", "#EXT-X-MEDIA-SEQUENCE:0"]
        for i in 0..<60 { lines += ["#EXTINF:10.0,", "seg\(i).ts"] }
        lines += ["#EXT-X-DISCONTINUITY", "#EXTINF:5.0,", "https://ad.com/ad1.ts", "#EXTINF:3.0,", "https://ad.com/ad2.ts", "#EXT-X-DISCONTINUITY"]
        for i in 60..<120 { lines += ["#EXTINF:10.0,", "seg\(i).ts"] }
        lines.append("#EXT-X-ENDLIST")
        let text = lines.joined(separator: "\n")
        let base = URL(string: "https://cdn.com/v/index.m3u8")!
        XCTAssertEqual(M3U8.removedSegmentCount(text, baseURL: base), 2)
        let out = M3U8.rewrite(text, baseURL: base, filterAds: true)
        XCTAssertTrue(out.contains("https://cdn.com/v/seg0.ts"))
        XCTAssertFalse(out.contains("ad.com"))
        XCTAssertTrue(out.hasSuffix("#EXT-X-ENDLIST\n"))
    }
}
