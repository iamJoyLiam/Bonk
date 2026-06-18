//
//  TabDragPayload.swift
//  Bonk
//
//  Transferable payload for tab drag-and-drop operations.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Custom transferable type for tab drag-and-drop.
struct TabDragPayload: Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .bonkTabID)
    }
}

/// Custom UTType for Bonk tab ID.
extension UTType {
    static let bonkTabID = UTType(exportedAs: "com.bonk.tab-id")
}

/// Codable conformance for Transferable.
extension TabDragPayload: Codable {
    enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idString = try container.decode(String.self, forKey: .id)
        guard let uuid = UUID(uuidString: idString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Invalid UUID string"
            )
        }
        self.id = uuid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString, forKey: .id)
    }
}
