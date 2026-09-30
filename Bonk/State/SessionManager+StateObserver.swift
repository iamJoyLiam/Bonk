//
//  SessionManager+StateObserver.swift
//  Bonk
//
//  Service state observation extracted from SessionManager to keep the class
//  body within size limits. Same-file logic, moved verbatim.
//

import os.log
import SwiftData
import SwiftTerm
import SwiftUI

// MARK: - SessionManager State Observer

extension SessionManager {
    func observeStateChanges(for tab: TerminalTab, session: TerminalSession, service: SSHNetworkService) {
        session.stateObservationTask?.cancel()
        let token = UUID()
        session.stateObserverToken = token
        let capturedGen = session.generation
        session.stateObservationTask = Task { [weak self, weak tab, weak session] in
            guard let self, let tab, let session else { return }
            for await state in service.stateStream {
                guard !Task.isCancelled else { break }
                guard session.stateObserverToken == token else { return }
                guard tab.session === session else { break }
                // Generation isolation: discard stale state
                guard session.generation == capturedGen else {
                    Log.session.info("[OBSERVER] discard stale state gen=\(capturedGen.uuidString.prefix(8)) != current=\(session.generation.uuidString.prefix(8))")
                    return
                }

                switch state {
                case .connected:
                    if let newPTY = await service.consumePendingPTY() {
                        if let firstPane = tab.layout.root.paneState {
                            let oldPTY = firstPane.ptySession
                            newPTY.teamSessionID = TeamSessionID(tabID: tab.id, paneID: firstPane.id)
                            newPTY.hostItem = tab.hostItem
                            // Fix 2: ensure output binding before closing old (make-before-break)
                            firstPane.ptySession = newPTY
                            session.ptySession = newPTY
                            // Refresh the VNext exec session: it wraps the previous transport,
                            // which the reconnect just replaced. Without this, agent/SFTP exec
                            // keeps hitting the dead connection after every reconnect.
                            if session.vnextSession != nil {
                                session.vnextSession = await service.makeVNextSession(
                                    endpoint: SSHEndpoint(host: tab.hostItem.host, port: UInt16(tab.hostItem.port))
                                )
                            }
                            // Rebind every owner of this tab: the main window and
                            // the Quake panel both hold a view, and rebinding one
                            // would leave the other feeding a closed session.
                            TerminalViewCache.shared.rebindOutputStream(forTab: tab.id, to: newPTY)
                            // Fix 1: log stages
                            Log.session.info("[RECOVERY_STEP] ptyReady=true outputBound=true pane=\(firstPane.id.uuidString.prefix(8), privacy: .public)")
                            syncPTYSize(for: firstPane.id, ptySession: newPTY)
                            // Close old only after new is bound
                            oldPTY?.close()
                        }
                        attachPTYSessionObservers(newPTY, to: tab)
                        session.connectedAt = Date()
                        session.errorMessage = nil
                        session.terminalState = .ready
                        self.setPhase(session, to: .ready, host: tab.hostItem.host, engine: "Observer", reason: "reconnect PTY")
                    } else if tab.layout.root.paneState?.ptySession != nil {
                        session.terminalState = .ready
                        self.setPhase(session, to: .ready, host: tab.hostItem.host, engine: "Observer", reason: "PTY ready")
                    } else {
                        Log.session.debug("[CONNECT] Ignoring .connected before PTY ready (phase=\(String(describing: session.phase)))")
                    }
                case .disconnected:
                    session.connectedAt = nil
                    if case .failed = session.phase { break }
                    self.setPhase(session, to: .idle, host: tab.hostItem.host, engine: "Observer", reason: "disconnected")
                case let .reconnecting(attempt, max):
                    self.setPhase(session, to: .reconnecting(attempt: attempt, maxAttempts: max), host: tab.hostItem.host, engine: "Observer", reason: "reconnecting")
                case .connecting:
                    if case .idle = session.phase {
                        self.setPhase(session, to: .connectingTransport, host: tab.hostItem.host, engine: "Observer", reason: "connecting")
                    } else {
                        session.connectionState = state
                    }
                }
            }
        }
    }
}
