import Foundation

/// A JSON value that can be stored in Sendable structs and rendered back to
/// Foundation objects for templating.
public indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(any: Any) {
        switch any {
        case let n as NSNumber:
            if isBoolNumber(n) { self = .bool(n.boolValue) }
            else if n.doubleValue == Double(n.intValue) { self = .int(n.intValue) }
            else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    static func object(from any: Any?) -> [String: JSONValue] {
        guard let dict = any as? [String: Any] else { return [:] }
        return dict.mapValues(JSONValue.init(any:))
    }

    public var foundation: Any {
        switch self {
        case .string(let s): return s
        case .number(let d): return d
        case .int(let i): return i
        case .bool(let b): return b
        case .array(let a): return a.map(\.foundation)
        case .object(let o): return o.mapValues(\.foundation)
        case .null: return NSNull()
        }
    }
}

/// String form used when a JSON value lands in a URL, header or template,
/// mirroring Dart's `toString()` for the values rules use.
func stringify(_ value: Any?) -> String {
    switch value {
    case nil: return ""
    case is NSNull: return "null"
    case let s as String: return s
    case let n as NSNumber:
        if isBoolNumber(n) { return n.boolValue ? "true" : "false" }
        if n.doubleValue == Double(n.int64Value) { return String(n.int64Value) }
        return n.stringValue
    case let i as Int: return String(i)
    case let d as Double:
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    case let b as Bool: return b ? "true" : "false"
    case let other?:
        if JSONSerialization.isValidJSONObject(other),
           let data = try? JSONSerialization.data(withJSONObject: other),
           let s = String(data: data, encoding: .utf8) { return s }
        return "\(other)"
    }
}

/// True when an NSNumber produced by JSONSerialization holds a boolean.
func isBoolNumber(_ n: NSNumber) -> Bool {
    String(cString: n.objCType) == "c"
}
