//
//  ImportKeyMaterial.swift
//  Bonk
//
//  An import manifest may describe a key. It may not open one.
//
//  The importers used to read a `privateKeyPath` out of the file, tilde-expand
//  it, and open it as a local file — during `load()` on `.onAppear`, with no
//  dialog, and with the path never shown. The path was chosen entirely by the
//  content of a file some other application wrote, so opening the Import sheet
//  was enough to read `~/.ssh/id_ed25519`, `~/.aws/credentials` or
//  `~/Library/Keychains/…`, and hand the contents to an attacker-chosen host as
//  its key material via `HostItem.init`, which writes the Keychain.
//
//  Choosing the manifest by hand does not make this safe. `NSOpenPanel` returns
//  a security-scoped URL for the file that was picked; a path *named inside*
//  that file is a different file the user never authorised.
//
//  So a manifest-supplied path is data. An inline PEM is also data, and stays
//  importable. The difference is not trust in the value, it is whether resolving
//  it requires opening a file the user did not name.
//

import Foundation
import os.log

/// Key material named by an import manifest.
enum ImportKeyMaterial: Equatable {
    /// A PEM literal present in the manifest. Data, not a file access.
    case inlinePEM(String)
    /// A path named by the manifest, deliberately not opened.
    ///
    /// Retained rather than discarded so the UI can tell the user that a key
    /// reference exists and was not followed, and so a future explicit
    /// "choose this key file" affordance has something to attach to.
    case unresolvedReference(String)
}

/// The logger importers use to report a reference they declined to follow.
let importKeyMaterialLog = Logger(subsystem: "com.bonk", category: "Import")

extension ImportKeyMaterial {
    /// Classify a manifest's key field.
    ///
    /// Never opens anything. That is the property the whole type exists to
    /// provide, and it is why this is a free function over a `String` rather
    /// than something handed a file reader.
    static func resolve(manifestValue: String?) -> ImportKeyMaterial? {
        guard let value = manifestValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        // A PEM begins with its armour header. Anything else is a reference to a
        // file, in some spelling, and is not followed.
        guard value.hasPrefix("-----BEGIN") else { return .unresolvedReference(value) }
        return .inlinePEM(value)
    }

    /// The inline PEM, if that is what this is.
    var inlinePEM: String? {
        if case .inlinePEM(let pem) = self { return pem }
        return nil
    }

    /// Report a reference that was not followed, so declining one is visible
    /// rather than looking like a manifest without a key.
    func logDeclinedReference(host: String) {
        guard case .unresolvedReference(let reference) = self else { return }
        importKeyMaterialLog.warning(
            "[Import] host \(host, privacy: .public) names a key file this app will not open on its behalf: \(reference, privacy: .public). Choose the key file yourself to use it."
        )
    }
}
