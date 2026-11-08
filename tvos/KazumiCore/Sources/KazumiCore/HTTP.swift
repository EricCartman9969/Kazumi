import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// User agents from lib/utils/constants.dart (`userAgentsList`).
public let kazumiUserAgents = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.1",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36 Edg/136.0.0.0",
]

public func randomUserAgent() -> String { kazumiUserAgents.randomElement()! }

public struct HTTPRequest: Sendable {
    public var method: String = "GET"
    public var url: String
    public var headers: [String: String] = [:]
    public var query: [(String, String)] = []
    public var body: Data? = nil
    public var timeout: TimeInterval = 20

    public init(url: String, method: String = "GET", headers: [String: String] = [:]) {
        self.url = url
        self.method = method
        self.headers = headers
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let url: URL
    public let headers: [String: String]
    public let data: Data

    /// Decodes the body using the charset from Content-Type or the page's
    /// <meta charset>, falling back to UTF-8 and then GB18030 (common on
    /// Chinese sites).
    public var text: String {
        decodeText(data, contentType: headers["content-type"])
    }
}

func decodeText(_ data: Data, contentType: String?) -> String {
    func charset(from s: String) -> String? {
        guard let r = s.range(of: #"charset\s*=\s*["']?([A-Za-z0-9_\-]+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let m = String(s[r])
        return m.split(separator: "=").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() }
    }
    var cs = contentType.flatMap(charset(from:))
    if cs == nil, let head = String(data: data.prefix(2048), encoding: .isoLatin1) { cs = charset(from: head) }
    #if canImport(Darwin)
    if let cs, ["gbk", "gb2312", "gb18030"].contains(cs) {
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: enc) { return s }
    }
    #endif
    if let s = String(data: data, encoding: .utf8) { return s }
    return String(decoding: data, as: UTF8.self)
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public extension HTTPClient {
    func get(_ url: String, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> HTTPResponse {
        var r = HTTPRequest(url: url, headers: headers)
        r.timeout = timeout
        return try await send(r)
    }
}

public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieStorage = HTTPCookieStorage.shared
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard var comps = lenientURL(request.url).flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: true) }) else {
            throw KazumiError.invalidURL(request.url)
        }
        if !request.query.isEmpty {
            var items = comps.queryItems ?? []
            items.append(contentsOf: request.query.map { URLQueryItem(name: $0.0, value: $0.1) })
            comps.queryItems = items
            // URLComponents leaves '+' unescaped, which servers read as a space.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = comps.url else { throw KazumiError.invalidURL(request.url) }
        var req = URLRequest(url: url, timeoutInterval: request.timeout)
        req.httpMethod = request.method
        var hasUA = false
        for (k, v) in request.headers {
            req.setValue(v, forHTTPHeaderField: k)
            if k.lowercased() == "user-agent" { hasUA = true }
        }
        if !hasUA { req.setValue(randomUserAgent(), forHTTPHeaderField: "User-Agent") }
        req.httpBody = request.body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    let task = session.dataTask(with: req) { data, resp, err in
                        if let err { cont.resume(throwing: err) }
                        else { cont.resume(returning: (data ?? Data(), resp!)) }
                    }
                    task.resume()
                }
            } onCancel: {}
        } catch {
            if Task.isCancelled { throw KazumiError.cancelled }
            throw KazumiError.network(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            headers[String(describing: k).lowercased()] = String(describing: v)
        }
        let res = HTTPResponse(status: http?.statusCode ?? 0, url: http?.url ?? url, headers: headers, data: data)
        if !(200..<300).contains(res.status) {
            throw HTTPStatusError(response: res)
        }
        return res
    }
}

/// Thrown for non-2xx responses; keeps the body so challenge pages can be detected.
public struct HTTPStatusError: Error, LocalizedError, Sendable {
    public let response: HTTPResponse
    public var errorDescription: String? { "HTTP \(response.status)：\(response.url.absoluteString)" }
}
