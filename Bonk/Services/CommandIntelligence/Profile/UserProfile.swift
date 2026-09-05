//  UserProfile.swift
//  Bonk
//
//  Learned via feedback, not blind injection (Invariant #10).
//  Tracks accept/reject to boost Ranker, not to inject prompt blindly.
//

import Foundation

final class UserProfile: @unchecked Sendable {
    static let shared = UserProfile()

    private let defaults = UserDefaults.standard
    private let acceptKey = "inline_user_profile_accepts_v1"
    private let rejectKey = "inline_user_profile_rejects_v1"
    private let lock = NSLock()

    // In-memory for fast ranking; persisted to UserDefaults
    private var accepts: [String: Int] = [:]
    private var rejects: Set<String> = []

    init() {
        load()
    }

    private func load() {
        lock.lock(); defer { lock.unlock() }
        if let data = defaults.data(forKey: acceptKey),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            accepts = decoded
        }
        if let data = defaults.data(forKey: rejectKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            rejects = decoded
        }
    }

    private func save() {
        // Called with lock held
        if let data = try? JSONEncoder().encode(accepts) {
            defaults.set(data, forKey: acceptKey)
        }
        if let data = try? JSONEncoder().encode(rejects) {
            defaults.set(data, forKey: rejectKey)
        }
    }

    func recordAccept(suffix: String) {
        let key = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        accepts[key, default: 0] += 1
        save()
    }

    func recordReject(suffix: String) {
        let key = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        rejects.insert(key)
        save()
    }

    func isRejected(suffix: String) -> Bool {
        let key = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        return rejects.contains(key)
    }

    func boost(for suffix: String) -> Double {
        let key = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        guard let count = accepts[key] else { return 0 }
        return log(Double(count) + 1) * 5
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        accepts.removeAll()
        rejects.removeAll()
        save()
    }
}
