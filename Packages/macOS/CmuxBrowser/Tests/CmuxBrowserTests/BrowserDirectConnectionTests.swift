import CmuxBrowser
import Foundation
import Network
import Testing
import WebKit

/// The embedded browser must not inherit macOS system proxy settings.
/// WebKit treats an empty `proxyConfigurations` array as "use System Settings",
/// so the direct override has to be a non-empty list that matches no real host.
@Suite struct BrowserDirectConnectionTests {
    private let connection = BrowserDirectConnection.standard

    private func enumeratedMatchDomains(_ configuration: ProxyConfiguration) -> [String] {
        var domains: [String] = []
        nw_proxy_config_enumerate_match_domains(configuration._nw) { domain in
            domains.append(String(cString: domain))
        }
        return domains
    }

    @Test func ordinaryHostsBypassTheStandInProxy() {
        let hosts = [
            "example.com",
            "localhost",
            "tenant.localhost",
            "api.github.com",
            "127.0.0.1",
            "::1",
            "[::1]",
            "cmux-browser-direct.invalid.example",
            "not-cmux-browser-direct.invalid",
        ]
        for host in hosts {
            #expect(!connection.hostUsesStandInProxy(host), "\(host) must connect directly")
        }
    }

    @Test func sentinelHostIsTheOnlyStandInMatch() {
        #expect(connection.hostUsesStandInProxy("cmux-browser-direct.invalid"))
        #expect(connection.hostUsesStandInProxy("Foo.CMUX-browser-direct.invalid"))
        #expect(connection.hostUsesStandInProxy("cmux-browser-direct.invalid."))
    }

    @Test func proxyListIsNonEmptyAndMatchesOnlyTheSentinel() throws {
        let configurations = connection.proxyConfigurations()
        let configuration = try #require(configurations.first)
        #expect(configurations.count == 1)
        let domains = enumeratedMatchDomains(configuration)
        #expect(domains == [connection.sentinelMatchDomain])
        #expect(!domains.isEmpty)
        #expect(configuration.allowFailover == true)
    }

    @Test func urlSessionUsesAnEmptyProxyDictionaryAndTheStandInList() throws {
        let configuration = connection.urlSessionConfiguration()
        let dictionary = try #require(configuration.connectionProxyDictionary)
        #expect(dictionary.isEmpty)
        let proxy = try #require(configuration.proxyConfigurations.first)
        #expect(configuration.proxyConfigurations.count == 1)
        #expect(enumeratedMatchDomains(proxy) == [connection.sentinelMatchDomain])
        #expect(proxy.allowFailover == true)

        let owned = URLSessionConfiguration.ephemeral
        owned.timeoutIntervalForRequest = 3
        connection.disableSystemProxy(on: owned)
        #expect(owned.timeoutIntervalForRequest == 3)
        #expect(owned.connectionProxyDictionary?.isEmpty == true)
        #expect(enumeratedMatchDomains(try #require(owned.proxyConfigurations.first)) == [connection.sentinelMatchDomain])
    }

    @MainActor
    @Test func unconfiguredWebsiteDataStoreReceivesTheDirectOverride() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        #expect(store.proxyConfigurations.isEmpty)
        connection.applyIfUnconfigured(to: store)
        let proxy = try #require(store.proxyConfigurations.first)
        #expect(store.proxyConfigurations.count == 1)
        #expect(enumeratedMatchDomains(proxy) == [connection.sentinelMatchDomain])

        connection.applyIfUnconfigured(to: store)
        #expect(store.proxyConfigurations.count == 1)
    }

    @MainActor
    @Test func explicitProxyIsLeftInPlace() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 1080)
        var proxy = ProxyConfiguration(socksv5Proxy: endpoint)
        proxy.matchDomains = ["keep.example"]
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]

        connection.applyIfUnconfigured(to: store)

        let installed = try #require(store.proxyConfigurations.first)
        #expect(store.proxyConfigurations.count == 1)
        #expect(enumeratedMatchDomains(installed) == ["keep.example"])
        #expect(installed.allowFailover == false)
    }
}
