import Foundation
import Network

/// Finds companion resolvers on the LAN. tvos-resolver advertises
/// `_kazumi-resolver._tcp` over Bonjour.
@MainActor
final class ResolverDiscovery: ObservableObject {
    struct Found: Identifiable, Hashable {
        var id: String { url }
        let name: String
        let url: String
    }

    @Published private(set) var found: [Found] = []
    @Published private(set) var isBrowsing = false
    private var browser: NWBrowser?

    func start() {
        stop()
        found = []
        isBrowsing = true
        let browser = NWBrowser(for: .bonjour(type: "_kazumi-resolver._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                Self.resolve(result.endpoint) { url in
                    guard let url else { return }
                    Task { @MainActor in
                        guard let self, !self.found.contains(where: { $0.url == url }) else { return }
                        self.found.append(Found(name: name, url: url))
                    }
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
    }

    /// Browses for up to `timeout` seconds and returns the first resolver found.
    func discoverOnce(timeout: TimeInterval) async -> Found? {
        start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let first = found.first { stop(); return first }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        stop()
        return nil
    }

    /// Turns a Bonjour service endpoint into http://ip:port by connecting once.
    nonisolated private static func resolve(_ endpoint: NWEndpoint, completion: @escaping @Sendable (String?) -> Void) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        let done = OnceFlag()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var url: String?
                if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    if h.contains(":") { h = "[\(h)]" }
                    url = "http://\(h):\(port.rawValue)"
                }
                if done.set() { completion(url) }
                connection.cancel()
            case .failed, .cancelled:
                if done.set() { completion(nil) }
            default: break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if done.set() { completion(nil) }
            connection.cancel()
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
