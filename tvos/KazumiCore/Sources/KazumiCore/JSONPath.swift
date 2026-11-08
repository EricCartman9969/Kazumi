import Foundation

/// Restricted JSONPath used by API rules: `$`, `.name`, `[n]`, `[*]`,
/// `['name']`. Port of `RestrictedJsonPath` (lib/services/plugin/api_rule_strategy.dart).
enum RestrictedJSONPath {
    enum Segment { case key(String), index(Int), wildcard }

    static func parse(_ expression: String) throws -> [Segment] {
        guard expression.hasPrefix("$") else {
            throw KazumiError.invalidRule("JSONPath 必须以 $ 开头: \(expression)")
        }
        let chars = Array(expression)
        var i = 1
        var segments: [Segment] = []
        let keyChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$-")
        while i < chars.count {
            let c = chars[i]
            if c == "." {
                i += 1
                let start = i
                while i < chars.count, chars[i].unicodeScalars.allSatisfy({ keyChars.contains($0) }) { i += 1 }
                if i == start { throw KazumiError.invalidRule("不支持的 JSONPath: \(expression)") }
                segments.append(.key(String(chars[start..<i])))
                continue
            }
            if c == "[" {
                var j = i + 1
                var quote: Character?
                var escaped = false
                var end = -1
                while j < chars.count {
                    let ch = chars[j]
                    if escaped { escaped = false } else if ch == "\\" { escaped = true }
                    else if let q = quote { if ch == q { quote = nil } }
                    else if ch == "'" || ch == "\"" { quote = ch }
                    else if ch == "]" { end = j; break }
                    j += 1
                }
                if end < 0 { throw KazumiError.invalidRule("JSONPath 缺少 ]: \(expression)") }
                let content = String(chars[(i + 1)..<end]).trimmingCharacters(in: .whitespaces)
                if content == "*" {
                    segments.append(.wildcard)
                } else if let n = Int(content), content.allSatisfy(\.isNumber) {
                    segments.append(.index(n))
                } else if content.count >= 2,
                          (content.hasPrefix("'") && content.hasSuffix("'")) || (content.hasPrefix("\"") && content.hasSuffix("\"")) {
                    let inner = String(content.dropFirst().dropLast())
                        .replacingOccurrences(of: "\\'", with: "'")
                        .replacingOccurrences(of: "\\\"", with: "\"")
                        .replacingOccurrences(of: "\\\\", with: "\\")
                    segments.append(.key(inner))
                } else {
                    throw KazumiError.invalidRule("不支持的 JSONPath 片段: [\(content)]")
                }
                i = end + 1
                continue
            }
            throw KazumiError.invalidRule("不支持的 JSONPath: \(expression)")
        }
        return segments
    }

    static func validate(_ expression: String) throws { _ = try parse(expression) }

    static func read(_ document: Any, _ expression: String) throws -> [Any] {
        var current: [Any] = [document]
        for seg in try parse(expression) {
            var next: [Any] = []
            for node in current {
                switch seg {
                case .key(let k):
                    if let o = node as? [String: Any], let v = o[k] { next.append(v) }
                case .index(let n):
                    if let a = node as? [Any], n < a.count { next.append(a[n]) }
                case .wildcard:
                    if let a = node as? [Any] { next.append(contentsOf: a) }
                    else if let o = node as? [String: Any] { next.append(contentsOf: o.values) }
                }
            }
            current = next
        }
        return current
    }

    static func readFirst(_ document: Any, _ expression: String) throws -> Any? {
        try read(document, expression).first
    }
}
