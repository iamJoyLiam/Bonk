//
//  SSHErrorMessageParser.swift
//  Bonk
//
//  Translates raw OpenSSH output into clear, user-facing error messages.
//  OpenSSH reports connection failures as terse lines ("Connection closed by
//  UNKNOWN port 65535", "administratively prohibited", ...) that leave users
//  guessing whether the network is down, credentials are wrong, or TCP
//  forwarding is disabled on the server. This parser matches known ssh
//  failure signatures and explains them; unrecognized output passes through
//  unchanged so file-level sftp errors ("Permission denied" on a path) are
//  never mislabeled as connection failures.
//

import Foundation

enum SSHErrorMessageParser {
    /// Explain `raw` ssh output for `host` (optionally via `jumpHost`).
    /// Returns nil when the output does not match any known
    /// connection-failure signature (the caller keeps the original text).
    static func explain(_ raw: String, host: String?, jumpHost: String? = nil) -> String? {
        let i18n = I18n.shared

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine
                .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\r", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()

            // Server or jump host refuses TCP forwarding (-W/-J tunnels).
            // "Connection closed by UNKNOWN port 65535" is what newer ssh
            // clients print after the server rejects the direct-tcpip channel
            // ("administratively prohibited") when AllowTcpForwarding is off —
            // NOT a network failure, so it must be checked before the generic
            // "connection closed by" network signature below.
            if lower.contains("administratively prohibited")
                || lower.contains("open failed")
                || lower.contains("channel 0:")
                || lower.contains("connection closed by unknown port 65535")
            {
                if let jumpHost, !jumpHost.isEmpty {
                    return i18n.tr(.sshErrorJumpForwardingDisabled, args: jumpHost, host ?? "", line)
                }
                return i18n.tr(.sshErrorForwardingDisabled, args: host ?? "", line)
            }

            // Network-level failures: host down, refused, unreachable, or the
            // proxy process died ("Connection closed by UNKNOWN port ..." is
            // what ssh prints when the ProxyCommand tunnel drops).
            if lower.contains("connection refused")
                || lower.contains("connection timed out")
                || lower.contains("connect timed out")
                || lower.contains("no route to host")
                || lower.contains("network is unreachable")
                || lower.contains("could not resolve hostname")
                || lower.contains("kex_exchange_identification")
                || lower.contains("ssh_exchange_identification")
                || lower.contains("connection closed by")
                || lower.contains("connection reset")
                || lower.contains("unknown port")
            {
                return i18n.tr(.sshErrorNetworkUnreachable, args: host ?? "", line)
            }

            // Authentication failures. The full OpenSSH signatures are
            // matched so a plain file-level "Permission denied" from sftp is
            // not misread as a credential problem.
            if lower.contains("permission denied (publickey")
                || lower.contains("permission denied, please try again")
                || lower.contains("authentication failed")
                || lower.contains("authentication failure")
                || lower.contains("no supported authentication methods")
                || lower.contains("too many authentication failures")
            {
                return i18n.tr(.sshErrorAuthentication, args: line)
            }

            if lower.contains("host key verification failed")
                || lower.contains("remote host identification has changed")
            {
                return i18n.tr(.sshErrorHostKey, args: line)
            }

            if lower.contains("timed out") || lower.contains("timeout expired") {
                return i18n.tr(.sshErrorTimeout, args: line)
            }
        }
        return nil
    }
}