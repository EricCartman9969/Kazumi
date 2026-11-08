import Foundation
import Kanna

/// Makes a Kazumi rule XPath behave as it does in the app.
///
/// Kazumi evaluates rules with `xpath_selector`, where every expression is
/// relative to the context element: `//a` means "descendants of the current
/// node" and `/div` means "children of the current node", and document-level
/// queries start from the `<html>` element. libxml2 follows the XPath spec, in
/// which a leading `/` always means the document root, so each union branch
/// that starts with `/` gets a `.` prefix.
func relativeXPath(_ expression: String) -> String {
    var branches: [String] = []
    var depthBracket = 0, depthParen = 0
    var quote: Character?
    var current = ""
    for ch in expression {
        if let q = quote {
            current.append(ch)
            if ch == q { quote = nil }
            continue
        }
        switch ch {
        case "'", "\"": quote = ch
        case "[": depthBracket += 1
        case "]": depthBracket -= 1
        case "(": depthParen += 1
        case ")": depthParen -= 1
        case "|" where depthBracket == 0 && depthParen == 0:
            branches.append(current)
            current = ""
            continue
        default: break
        }
        current.append(ch)
    }
    branches.append(current)
    return branches.map { b -> String in
        let t = b.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("/") ? "." + t : t
    }.joined(separator: " | ")
}

final class ParsedHTML {
    let document: HTMLDocument
    let root: Kanna.XMLElement

    init(_ raw: String) throws {
        do {
            document = try HTML(html: raw.isEmpty ? "<html></html>" : raw, encoding: .utf8)
        } catch {
            throw KazumiError.parse("HTML 响应解析失败")
        }
        guard let html = document.at_xpath("/html") ?? document.at_xpath("/*") else {
            throw KazumiError.parse("HTML 响应没有根节点")
        }
        root = html
    }
}

extension Kanna.XMLElement {
    func query(_ expression: String) -> [Kanna.XMLElement] {
        Array(xpath(relativeXPath(expression)))
    }
    func queryFirst(_ expression: String) -> Kanna.XMLElement? {
        xpath(relativeXPath(expression)).first
    }
}

struct XPathRuleStrategy {
    func prepareSearchRequest(_ plugin: Plugin, keyword: String) throws -> PreparedRuleRequest {
        let encoded = encodeQueryComponent(keyword)
        let queryURL = plugin.searchURL.replacingOccurrences(of: "@keyword", with: encoded)
        guard let comps = URLComponents(string: queryURL), comps.scheme != nil, !(comps.host ?? "").isEmpty else {
            throw KazumiError.invalidURL(queryURL)
        }
        if !plugin.usePost {
            return PreparedRuleRequest(method: "GET", url: queryURL, includeCookies: true)
        }
        var bare = comps
        let items = comps.queryItems ?? []
        bare.query = nil
        var body: [String: JSONValue] = [:]
        for item in items { body[item.name] = .string(item.value ?? "") }
        return PreparedRuleRequest(method: "POST", url: bare.string ?? queryURL, bodyType: "form", body: .object(body), includeCookies: true)
    }

    func prepareChapterRequest(_ plugin: Plugin, source: String) throws -> PreparedRuleRequest {
        let url = normalizeEpisodeURL(baseURL: plugin.baseURL, raw: source)
        guard let u = URL(string: url), u.scheme != nil, !(u.host ?? "").isEmpty else {
            throw KazumiError.invalidURL(url)
        }
        return PreparedRuleRequest(method: "GET", url: url)
    }

    func parseSearch(_ raw: String, plugin: Plugin) throws -> [SearchItem] {
        let html = try ParsedHTML(raw)
        if detectsCaptcha(raw, config: plugin.antiCrawlerConfig, root: html.root) {
            throw KazumiError.captchaRequired(plugin.name)
        }
        guard !plugin.searchList.isEmpty, !plugin.searchName.isEmpty, !plugin.searchResult.isEmpty else {
            throw KazumiError.invalidRule("搜索 XPath 不能为空")
        }
        var items: [SearchItem] = []
        for node in html.root.query(plugin.searchList) {
            let name = node.queryFirst(plugin.searchName)?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let src = node.queryFirst(plugin.searchResult)?["href"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty || src.isEmpty { continue }
            items.append(SearchItem(name: name, src: src))
        }
        return items
    }

    func parseChapters(_ raw: String, plugin: Plugin) throws -> [Road] {
        let html = try ParsedHTML(raw)
        guard !plugin.chapterRoads.isEmpty, !plugin.chapterResult.isEmpty else {
            throw KazumiError.invalidRule("选集 XPath 不能为空")
        }
        var roads: [Road] = []
        for roadNode in html.root.query(plugin.chapterRoads) {
            var urls: [String] = []
            var names: [String] = []
            for (i, ep) in roadNode.query(plugin.chapterResult).enumerated() {
                let src = ep["href"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if src.isEmpty { continue }
                let name = (ep.text ?? "").components(separatedBy: .whitespacesAndNewlines).joined()
                urls.append(normalizeEpisodeURL(baseURL: plugin.baseURL, raw: src))
                names.append(name.isEmpty ? "第\(i + 1)集" : name)
            }
            if urls.isEmpty { continue }
            roads.append(Road(name: "播放线路\(roads.count + 1)", urls: urls, episodeNames: names))
        }
        return roads
    }

    func detectsCaptcha(_ raw: String, config: AntiCrawlerConfig, root: Kanna.XMLElement? = nil) -> Bool {
        guard config.enabled else { return false }
        let value = config.captchaDetectValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            switch config.captchaDetectType {
            case 2: return raw.contains(value)
            case 3: return raw.range(of: value, options: [.regularExpression, .caseInsensitive]) != nil
            default:
                guard let root = root ?? (try? ParsedHTML(raw))?.root else { return false }
                return root.queryFirst(value) != nil
            }
        }
        guard let root = root ?? (try? ParsedHTML(raw))?.root else { return false }
        for expr in [config.captchaImage, config.captchaButton] where !expr.trimmingCharacters(in: .whitespaces).isEmpty {
            if root.queryFirst(expr) != nil { return true }
        }
        return false
    }
}

/// Dart's `Uri.encodeQueryComponent`: spaces become '+', everything outside
/// the unreserved set is percent-encoded.
func encodeQueryComponent(_ s: String) -> String {
    var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~*")
    allowed.insert(" ")
    return (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: " ", with: "+")
}

/// Dart's `Uri.encodeComponent`.
func encodeComponent(_ s: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
