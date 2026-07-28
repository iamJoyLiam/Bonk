//
//  QuakeSettingsView.swift
//  Bonk
//
//  Settings view for Quake terminal configuration.
//

import SwiftUI

// MARK: - Quake Settings View

/// Settings for Quake dropdown terminal.
struct QuakeSettingsView: View {
    @Environment(I18n.self) private var i18n
    @Bindable var quakeController: QuakeController

    @State private var enabled: Bool
    @State private var heightRatio: Double
    @State private var widthRatio: Double
    @State private var autoHideOnFocusLoss: Bool
    @State private var escBehavior: EscBehavior
    @State private var showPermissionAlert = false

    init(quakeController: QuakeController) {
        self.quakeController = quakeController
        self.enabled = quakeController.configuration.enabled
        self.heightRatio = quakeController.configuration.heightRatio
        self.widthRatio = quakeController.configuration.widthRatio
        self.autoHideOnFocusLoss = quakeController.configuration.autoHideOnFocusLoss
        self.escBehavior = quakeController.configuration.escBehavior
    }

    var body: some View {
        Form {
            // Enable/Disable
            Section {
                Toggle(i18n.t(.quakeEnabled), isOn: $enabled)
                    .onChange(of: enabled) { _, newValue in
                        updateConfig { $0.enabled = newValue }
                    }

                if enabled {
                    // Permission status
                    HStack {
                        Label(i18n.t(.accessibilityPermission), systemImage: "lock.shield")
                        Spacer()
                        if quakeController.permissionManager.isAccessibilityGranted {
                            Label(i18n.t(.granted), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button(i18n.t(.grantPermission)) {
                                quakeController.permissionManager.requestAccessibility()
                            }
                        }
                    }

                    // Hotkey display
                    HStack {
                        Label(i18n.t(.toggleHotkey), systemImage: "keyboard")
                        Spacer()
                        Text(quakeController.configuration.shortcut.description)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Window settings
            if enabled {
                Section(i18n.t(.windowSettings)) {
                    HStack {
                        Text(i18n.t(.height))
                        Spacer()
                        Slider(value: $heightRatio, in: 0.2 ... 0.9, step: 0.1)
                            .frame(width: 150)
                        Text("\(Int(heightRatio * 100))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .onChange(of: heightRatio) { _, newValue in
                        updateConfig { $0.heightRatio = CGFloat(newValue) }
                    }

                    HStack {
                        Text(i18n.t(.width))
                        Spacer()
                        Slider(value: $widthRatio, in: 0.5 ... 1.0, step: 0.1)
                            .frame(width: 150)
                        Text("\(Int(widthRatio * 100))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .onChange(of: widthRatio) { _, newValue in
                        updateConfig { $0.widthRatio = CGFloat(newValue) }
                    }
                }

                // Behavior settings
                Section(i18n.t(.behavior)) {
                    Toggle(i18n.t(.autoHideOnFocusLoss), isOn: $autoHideOnFocusLoss)
                        .onChange(of: autoHideOnFocusLoss) { _, newValue in
                            updateConfig { $0.autoHideOnFocusLoss = newValue }
                        }

                    Picker(i18n.t(.escKeyBehavior), selection: $escBehavior) {
                        ForEach(EscBehavior.allCases, id: \.self) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    .onChange(of: escBehavior) { _, newValue in
                        updateConfig { $0.escBehavior = newValue }
                    }
                }

                // Test section
                Section {
                    Button {
                        quakeController.toggle()
                    } label: {
                        Label(i18n.t(.testQuake), systemImage: "play.circle")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func updateConfig(_ modifier: (inout QuakeConfiguration) -> Void) {
        var config = quakeController.configuration
        modifier(&config)
        quakeController.updateConfiguration(config)
    }
}
