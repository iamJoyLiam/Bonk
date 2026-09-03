import Combine
import Foundation
import Network
import os.log

// MARK: - Discovered Host

struct DiscoveredTeamHost: Identifiable, Hashable, Sendable {
    var id: String // endpoint debugDescription
    var displayName: String
    var endpoint: NWEndpoint
    var txtRecord: [String: String]
}

// MARK: - Discovery Service (Bonjour + manual IP)

@MainActor
final class TeamDiscoveryService: ObservableObject {
    @Published private(set) var discoveredHosts: [DiscoveredTeamHost] = []
    @Published private(set) var isBrowsing = false
    // Single isHosting truth: mirrors TeamStore (one NWListener). Discovery's listener is now Store's.
    private let store = TeamStore.shared
    @Published private(set) var isHosting = false
    private var cancellables = Set<AnyCancellable>()

    private let logger = Logger(subsystem: "com.bonk", category: "TeamDiscovery")
    private var browser: NWBrowser?
    // Listener moved to TeamStore — retained via Store
    private var hostedServiceName: String = TeamConstants.defaultHostName

    init() {
        store.$isHosting.receive(on: DispatchQueue.main).sink { [weak self] value in
            self?.isHosting = value
        }.store(in: &cancellables)
    }

    // MARK: - Host: publish

    func startHosting(displayName: String) {
        hostedServiceName = displayName
        do {
            try store.startHosting(displayName: displayName)
            logger.info("Started hosting via Store: \(displayName)")
        } catch {
            logger.error("Failed to start hosting via Store: \(error.localizedDescription)")
        }
    }

    func stopHosting() {
        store.stopHosting()
    }

    // MARK: - Guest: browse

    func startBrowsing() {
        guard !isBrowsing else { return }
        let parameters = NWParameters.tcp
        let descriptor = NWBrowser.Descriptor.bonjour(type: TeamConstants.serviceType, domain: TeamConstants.serviceDomain)
        browser = NWBrowser(for: descriptor, using: parameters)
        browser?.stateUpdateHandler = { [weak self] state in
            self?.logger.info("Browser state: \(String(describing: state))")
        }
        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            Task { @MainActor in
                self.discoveredHosts = results.compactMap { result in
                    guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                    let txt: [String: String] = [:]
                    return DiscoveredTeamHost(
                        id: "\(name).\(type).\(domain)",
                        displayName: name,
                        endpoint: result.endpoint,
                        txtRecord: txt
                    )
                }
                self.logger.info("Discovered \(self.discoveredHosts.count) hosts")
            }
        }
        browser?.start(queue: .global(qos: .utility))
        isBrowsing = true
        logger.info("Started browsing team services")
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        discoveredHosts.removeAll()
    }

    // MARK: - Manual IP

    func manualEndpoint(host: String, port: UInt16) -> NWEndpoint {
        .hostPort(host: .init(host), port: .init(integerLiteral: port))
    }

    deinit {
        // Cancel on deinit needs to be called from main actor context
        // The service will be stopped explicitly by caller before deinit in normal flow
    }
}
