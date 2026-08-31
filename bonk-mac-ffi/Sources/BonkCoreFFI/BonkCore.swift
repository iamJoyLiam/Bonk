import Foundation

// MARK: - C ABI Bridge (auto-generated header from cbindgen will be imported as CBonkCore)
// For now we declare the two stable funcs manually so Package compiles without header.

@_silgen_name("bonk_core_init")
func bonk_core_init() -> Int32

@_silgen_name("bonk_core_version")
func bonk_core_version() -> UnsafePointer<CChar>

@_silgen_name("bonk_core_validate_host_json")
func bonk_core_validate_host_json(_ json: UnsafePointer<CChar>) -> Int32

// MARK: - Swift-friendly wrapper

public enum BonkCore {
    public static func initialize() {
        _ = bonk_core_init()
        let ver = String(cString: bonk_core_version())
        print("[BonkCoreFFI] Rust core v\(ver) initialized")
    }

    /// Validate HostItemDto JSON via Rust core (tests FFI roundtrip)
    public static func validateHost(json: String) -> Bool {
        json.withCString { ptr in
            bonk_core_validate_host_json(ptr) == 0
        }
    }
}

// MARK: - DTOs (Codable mirrors Rust HostItemDto)
// Swift side keeps its own @Model for SwiftData, but converts to DTO for FFI.

public struct HostItemDTO: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var authType: String // maps to Rust AuthType
    public var groupId: UUID?
    public var credentialId: UUID?
    public var jumpHostId: UUID?
    public var createdAt: Date
    public var lastConnectedAt: Date?
    public var sortOrder: Int32
    public var isFavorite: Bool
    public var isSerial: Bool
    public var serialBaudRate: UInt32?
    public var forceCompatibility: Bool

    public func toJson() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Session bridge (future: async FFI with callbacks)
// Phase 1: Rust core runs mock PTY; Phase 2: wire real russh + streaming callbacks
//
// Swift usage sketch:
//
//   BonkCore.initialize()
//   let json = try hostDTO.toJson()
//   guard BonkCore.validateHost(json: json) else { return }
//   // Next: BonkCoreSession.connect(dto: dto, onData: { data in termView.feed(data) })
