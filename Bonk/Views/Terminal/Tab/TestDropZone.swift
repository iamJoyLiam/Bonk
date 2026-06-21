//
//  TestDropZone.swift
//  Bonk
//
//  Test view to verify if .onDrop works in pure SwiftUI area.
//

import SwiftUI
import UniformTypeIdentifiers

struct TestDropZone: View {
    @State private var isDragOver = false
    @State private var lastDrop: String = "No drop yet"

    var body: some View {
        HStack {
            Text("TEST DROP ZONE")
                .font(.caption.bold())
            Spacer()
            Text(lastDrop)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(isDragOver ? Color.accentColor.opacity(0.3) : Color.orange.opacity(0.2))
        .onDrop(of: [.utf8PlainText], isTargeted: $isDragOver) { providers, _ in
            print("[TEST] onDrop triggered!")
            guard let provider = providers.first else {
                print("[TEST] No provider")
                return false
            }
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                if let str = string as? String {
                    print("[TEST] Received: \(str)")
                    Task { @MainActor in
                        lastDrop = "Got: \(str.prefix(8))..."
                    }
                }
            }
            return true
        }
        .onChange(of: isDragOver) { _, newValue in
            print("[TEST] isDragOver: \(newValue)")
        }
    }
}
