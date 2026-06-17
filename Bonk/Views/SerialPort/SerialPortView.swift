//
//  SerialPortView.swift
//  Bonk
//

import SwiftUI

/// Serial port connection panel.
struct SerialPortView: View {
    @Environment(I18n.self) var i18n
    @Binding var isPresented: Bool
    let onConnect: (SerialPortConfig) -> Void

    @State private var config = SerialPortConfig()
    @State private var availablePorts: [String] = []
    @State private var isScanning = false
    @State private var serialPortService = SerialPortService.shared
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cable.connector")
                    .foregroundStyle(.blue)
                Text(i18n.t(.serialPort))
                    .font(.headline)
                Spacer()
                Button {
                    scanPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .help(i18n.t(.scanPorts))
                .disabled(isScanning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Configuration
            Form {
                Section(i18n.t(.port)) {
                    Picker(i18n.t(.port), selection: $config.path) {
                        Text(i18n.t(.selectPort)).tag("")
                        ForEach(availablePorts, id: \.self) { port in
                            Text(port).tag(port)
                        }
                    }

                    if isScanning {
                        HStack {
                            ProgressView()
                                .controlSize(.mini)
                            Text(i18n.t(.scanning))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section(i18n.t(.connection)) {
                    Picker(i18n.t(.baudRate), selection: $config.baudRate) {
                        ForEach(SerialPortConfig.defaultBaudRates, id: \.self) { rate in
                            Text("\(rate)").tag(rate)
                        }
                    }

                    Picker(i18n.t(.dataBits), selection: $config.dataBits) {
                        ForEach(5...8, id: \.self) { bits in
                            Text("\(bits)").tag(bits)
                        }
                    }

                    Picker(i18n.t(.stopBits), selection: $config.stopBits) {
                        Text("1").tag(1.0)
                        Text("1.5").tag(1.5)
                        Text("2").tag(2.0)
                    }

                    Picker(i18n.t(.parity), selection: $config.parity) {
                        ForEach(SerialPortConfig.Parity.allCases, id: \.self) { parity in
                            Text(parity.displayName).tag(parity)
                        }
                    }

                    Picker(i18n.t(.flowControl), selection: $config.flowControl) {
                        ForEach(SerialPortConfig.FlowControl.allCases, id: \.self) { flowControl in
                            Text(flowControl.displayName).tag(flowControl)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            // Connect button
            HStack {
                Spacer()
                Button {
                    onConnect(config)
                    isPresented = false
                } label: {
                    Label(i18n.t(.connect), systemImage: "bolt")
                }
                .buttonStyle(.borderedProminent)
                .disabled(config.path.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 450, height: 500)
        .onAppear {
            scanPorts()
        }
    }

    private func scanPorts() {
        isScanning = true
        // 使用 SerialPortService 扫描真实端口
        DispatchQueue.global(qos: .userInitiated).async {
            let ports = serialPortService.scanPorts()
            DispatchQueue.main.async {
                availablePorts = ports
                isScanning = false
            }
        }
    }
}
