//
//  HostRunNonce.swift
//  Bonk
//
//  A token that only this run knows.
//

import Foundation

/// A token the host cannot guess.
///
/// The host runs the listing command, so the host controls the output and
/// could print anything at all. What the host cannot do is guess this: it
/// is generated locally, it travels with the command, and the file being
/// read — the part that is genuinely untrusted — never sees it.
///
/// So a file that prints marker-shaped lines prints **content**, not
/// structure: it cannot open another file's section, and it cannot close
/// its own early to make room for one.
enum HostRunNonce {
    static func make() -> String {
        String(UUID().uuidString.lowercased().prefix(12))
    }
}
