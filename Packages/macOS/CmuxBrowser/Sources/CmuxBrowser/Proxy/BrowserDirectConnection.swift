public import Foundation
public import Network
public import WebKit

/// Forces the embedded browser onto a direct connection.
///
/// `WKWebsiteDataStore.proxyConfigurations` overrides the macOS system proxy
/// (HTTP, HTTPS, SOCKS, and PAC/WPAD) only when the array is non-empty. An
/// empty array clears that override and WebKit follows System Settings again
/// (`clearProxyConfigData` / `nw_context_clear_proxies`). Network.framework
/// has no "direct" proxy value, so the override is a stand-in SOCKS proxy
/// whose `matchDomains` is a single reserved `.invalid` name. WebKit installs
/// that list in place of the system proxies; hosts that do not suffix-match
/// the sentinel are dialed directly, which is every real page, including
/// loopback.
///
/// ```swift
/// let store = WKWebsiteDataStore.default()
/// BrowserDirectConnection.standard.applyIfUnconfigured(to: store)
/// ```
///
/// Intentional cmux proxies (a remote workspace tunnel, a Cloud browser
/// route, or a browser REPL proxy) are separate configurations. Apply this
/// only when the store has no such proxy. URL sessions that belong to the
/// browser feature use ``disableSystemProxy(on:)``, which sets
/// `connectionProxyDictionary` to an empty dictionary (URLSession's documented
/// no-proxy value) and the same stand-in list, because an empty
/// `proxyConfigurations` array on `URLSessionConfiguration` also means
/// "system settings".
public struct BrowserDirectConnection: Sendable, Equatable {
    /// Hostname suffix that selects the stand-in proxy.
    ///
    /// `.invalid` is reserved by RFC 2606, so public sites do not suffix-match
    /// it. Network.framework treats an entry as the domain plus its subdomains,
    /// so `foo.cmux-browser-direct.invalid` would use the stand-in and then
    /// fail over to a direct connection.
    public var sentinelMatchDomain: String

    /// Address of the stand-in proxy. It is contacted only for the sentinel.
    public var standInHost: String

    /// Port of the stand-in proxy. Port 9 is the discard service and is not a
    /// local proxy.
    public var standInPort: UInt16

    /// When the sentinel itself is requested, give up on the stand-in and
    /// connect directly instead of failing the load.
    public var allowsFailover: Bool

    /// The connection policy the embedded browser installs.
    public static let standard = BrowserDirectConnection()

    /// Creates a direct-connection policy.
    ///
    /// - Parameters:
    ///   - sentinelMatchDomain: Domain suffix routed at the stand-in proxy.
    ///     The default is an RFC 2606 `.invalid` name.
    ///   - standInHost: Host of the stand-in proxy. Unused for ordinary loads.
    ///   - standInPort: Port of the stand-in proxy.
    ///   - allowsFailover: Whether a sentinel request may fall back to a
    ///     direct connection when the stand-in is unreachable.
    public init(
        sentinelMatchDomain: String = "cmux-browser-direct.invalid",
        standInHost: String = "127.0.0.1",
        standInPort: UInt16 = 9,
        allowsFailover: Bool = true
    ) {
        self.sentinelMatchDomain = sentinelMatchDomain
        self.standInHost = standInHost
        self.standInPort = standInPort
        self.allowsFailover = allowsFailover
    }

    /// Whether `host` suffix-matches the stand-in and would be sent to it.
    ///
    /// Ordinary browser hosts, loopback names, and IP literals return false.
    /// Comparison is case-insensitive. A trailing DNS root dot is ignored.
    public func hostUsesStandInProxy(_ host: String) -> Bool {
        var normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("["), normalized.hasSuffix("]"), normalized.count >= 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        let sentinel = sentinelMatchDomain.lowercased()
        return normalized == sentinel || normalized.hasSuffix(".\(sentinel)")
    }

    /// The non-empty proxy list that replaces the system proxy on a data store.
    ///
    /// Returns an empty array only when the stand-in endpoint cannot be built.
    /// Callers must not install that empty array: WebKit would follow System
    /// Settings. ``apply(to:)`` refuses it.
    public func proxyConfigurations() -> [ProxyConfiguration] {
        guard let port = NWEndpoint.Port(rawValue: standInPort) else { return [] }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(standInHost), port: port)
        var configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        // Empty `matchDomains` means every host uses the proxy. The sentinel
        // must stay non-empty or the stand-in would capture all traffic.
        configuration.matchDomains = [sentinelMatchDomain]
        configuration.allowFailover = allowsFailover
        return [configuration]
    }

    /// Replaces the data store's proxy list with the direct-connection override.
    @MainActor
    public func apply(to store: WKWebsiteDataStore) {
        let configurations = proxyConfigurations()
        guard !configurations.isEmpty else { return }
        store.proxyConfigurations = configurations
    }

    /// Installs the override when the store has no explicit proxy.
    ///
    /// An empty list is WebKit's system-proxy fallback, not a direct
    /// connection. A store that already has a remote, Cloud, or REPL proxy is
    /// left alone.
    @MainActor
    public func applyIfUnconfigured(to store: WKWebsiteDataStore) {
        guard store.proxyConfigurations.isEmpty else { return }
        apply(to: store)
    }

    /// An ephemeral session configuration that does not use the system proxy.
    ///
    /// - Parameter ephemeral: Pass false to start from `.default` instead of
    ///   `.ephemeral`. Either way the proxy keys are replaced.
    /// - Returns: A configuration whose `connectionProxyDictionary` is an
    ///   empty dictionary and whose `proxyConfigurations` is the stand-in list.
    public func urlSessionConfiguration(ephemeral: Bool = true) -> URLSessionConfiguration {
        let configuration = ephemeral
            ? URLSessionConfiguration.ephemeral
            : URLSessionConfiguration.default
        disableSystemProxy(on: configuration)
        return configuration
    }

    /// Clears system-proxy use on a session configuration the caller already owns.
    ///
    /// Sets `connectionProxyDictionary` to `[:]` after `proxyConfigurations`,
    /// so a configuration that already carries cookies, timeouts, or protocol
    /// classes keeps those and still bypasses HTTP, HTTPS, SOCKS, and PAC.
    public func disableSystemProxy(on configuration: URLSessionConfiguration) {
        let configurations = proxyConfigurations()
        if !configurations.isEmpty {
            configuration.proxyConfigurations = configurations
        }
        configuration.connectionProxyDictionary = [AnyHashable: Any]()
    }

    /// A new session from ``urlSessionConfiguration(ephemeral:)``.
    ///
    /// The returned session has no delegate. The task retains the session
    /// until the request finishes.
    public func makeURLSession(ephemeral: Bool = true) -> URLSession {
        URLSession(configuration: urlSessionConfiguration(ephemeral: ephemeral))
    }
}
