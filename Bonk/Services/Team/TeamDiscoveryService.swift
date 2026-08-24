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
    @Published private(set) var isHosting = false

    private let logger = Logger(subsystem: "com.bonk", category: "TeamDiscovery")
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var hostedServiceName: String = TeamConstants.defaultHostName

    // MARK: - Host: publish

    func startHosting(displayName: String) {
        stopHosting()
        hostedServiceName = displayName
        do {
            let parameters = NWParameters.tcp
            // MVP: no TLS for local discovery; TLS added in Relay layer
            listener = try NWListener(service: .init(name: displayName, type: TeamConstants.serviceType), using: parameters)
            listener?.stateUpdateHandler = { [weak self] state in
                self?.logger.info("Host listener state: \(String(describing: state))")
            }
            listener?.serviceRegistrationUpdateHandler = { [weak self] change in
                switch change {
                case .add(let endpoint): self?.logger.info("Service registered: \(String(describing: endpoint))")
                case .remove(let endpoint): self?.logger.info("Service removed: \(String(describing: endpoint))")
                @unknown default: break
                }
            }
            listener?.newConnectionHandler = { _ in
                // Relay owns connection handling; this listener is only for Bonjour advertisement
                // Keep it alive even if Relay creates its own NWListener on same service name
            }
            listener?.start(queue: .global(qos: .utility))
            isHosting = true
            logger.info("Started hosting team service: \(displayName)")
        } catch {
            logger.error("Failed to start hosting: \(error.localizedDescription)")
        }
    }

    func stopHosting() {
        listener?.cancel()
        listener = nil
        isHosting = false
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
