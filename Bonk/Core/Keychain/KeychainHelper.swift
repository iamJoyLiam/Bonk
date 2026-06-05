import Foundation
import os.log
import Security

/// Secure byte buffer that zeroes its contents on deallocation.
/// Prevents sensitive data (passwords, private keys) from lingering in RAM
/// after the owning variable goes out of scope — mitigating cold-boot attacks
/// and core dump leakage (FIPS 140-3 compliance).
final class SecureBytes: @unchecked Sendable {
    private let buffer: UnsafeMutableRawBufferPointer

    init(_ data: Data) {
        let count = data.count
        buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: count, alignment: 1)
        data.copyBytes(to: buffer)
    }

    deinit {
        // memset_s is not subject to dead-store elimination by the compiler,
        // guaranteeing the zeroing actually happens at runtime.
        memset_s(buffer.baseAddress, buffer.count, 0, buffer.count)
        buffer.deallocate()
    }

    /// Access the raw bytes. The pointer is only valid for the lifetime of this call.
    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
        try body(UnsafeRawBufferPointer(buffer))
    }

    /// Convert to String (UTF-8). Caller should minimize the lifetime of the returned String.
    func toUTF8String() -> String? {
        withUnsafeBytes { String(bytes: $0, encoding: .utf8) }
    }

    var count: Int {
        buffer.count
    }
}

/// Lightweight wrapper around the iOS/macOS Keychain Services API.
enum KeychainHelper {
    private static let service = "com.bonk.credentials"
    private static let logger = Logger(subsystem: "com.bonk", category: "Keychain")

    // MARK: - Store

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        delete(for: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain set failed for \(account): \(status)")
        }
        return status == errSecSuccess
    }

    // MARK: - Read

    /// Read a secret as String. For non-sensitive data or UI display only.
    /// For security-critical operations (SSH auth, key loading), use `getSecure()` instead.
    static func get(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else {
            if status != errSecItemNotFound {
                logger.error("Keychain get failed for \(account): \(status)")
            }
            return nil
        }

        return string
    }

    /// Read a secret into a secure buffer that auto-zeroes on deallocation.
    /// Use this for SSH private keys, passwords, and API keys passed to auth logic.
    static func getSecure(for account: String) -> SecureBytes? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.error("Keychain getSecure failed for \(account): \(status)")
            }
            return nil
        }

        return SecureBytes(data)
    }

    // MARK: - Secure Comparison

    /// Constant-time byte comparison — prevents timing side-channel attacks.
    /// An attacker cannot infer how many bytes matched by measuring response time.
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var result: UInt8 = 0
        for i in 0 ..< lhs.count {
            result |= lhs[i] ^ rhs[i]
        }
        return result == 0
    }

    // MARK: - Delete

    @discardableResult
    static func delete(for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Keychain delete failed for \(account): \(status)")
        }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Convenience keys

    static func passwordKey(for hostID: UUID) -> String {
        "host_\(hostID.uuidString)_password"
    }

    static func privateKeyKey(for hostID: UUID) -> String {
        "host_\(hostID.uuidString)_privatekey"
    }
}
