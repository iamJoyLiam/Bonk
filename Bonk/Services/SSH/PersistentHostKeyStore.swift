//
//  PersistentHostKeyStore.swift
//  Bonk
//
//  UserDefaults-backed host key fingerprint store.
//  Fingerprints persist across app launches (TOFU once, trust forever).
//

import Foundation

struct PersistentHostKeyStore: SSHHostKeyStore {
    private static let key = "com.bonk.hostKeys"
    private let storage = LockedStorage()

    init() {
        load()
    }

    func knownFingerprint(for host: String, port: UInt16) async -> SSHHostFingerprint? {
        storage.fingerprints[key(host, port)]
    }

    func saveFingerprint(_ fingerprint: SSHHostFingerprint, for host: String, port: UInt16) async {
        storage.fingerprints[key(host, port)] = fingerprint
        save()
    }

    private func key(_ host: String, _ port: UInt16) -> String {
        "\(host):\(port)"
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let map = try? JSONDecoder().decode([String: SSHHostFingerprint].self, from: data) else
        {
            return
        }
        storage.fingerprints = map
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(storage.fingerprints) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

private final class LockedStorage: @unchecked Sendable {
    var fingerprints: [String: SSHHostFingerprint] = [:]
    private let lock = NSLock()

    subscript(key: String) -> SSHHostFingerprint? {
        get { lock.lock(); defer { lock.unlock() }; return fingerprints[key] }
        set { lock.lock(); defer { lock.unlock() }; fingerprints[key] = newValue }
    }
}
