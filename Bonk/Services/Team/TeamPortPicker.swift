//
//  TeamPortPicker.swift
//  Bonk
//
//  Picks a free TCP port for the team relay.
//
//  Its own type so production and tests share one implementation: a test that
//  rolled its own port picker would pass against a picker the product does not
//  use, which is the kind of green that means nothing.
//

import Foundation

enum TeamPortPicker {
    /// Ask the OS for a free TCP port by binding and immediately releasing it.
    ///
    /// Inherently racy — a port could be taken between release and bind — but
    /// the alternative is a fixed port, which fails outright whenever another
    /// instance is hosting. A failure surfaces as a failed start, never as a
    /// silently wrong port.
    static func availablePort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        addr.sin_port = 0
        let didBind = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else { return nil }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didName = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard didName == 0 else { return nil }
        let bound = UInt16(bigEndian: actual.sin_port)
        return bound == 0 ? nil : bound
    }
}
