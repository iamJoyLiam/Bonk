//
//  SerialPortView.swift
//  Bonk
//

import SwiftUI

/// Serial port connection panel.
struct SerialPortView: View {
    @EnvironmentObject var i18n: I18n
    @Binding var isPresented: Bool
    let onConnect: (SerialPortConfig) -> Void

    @State private var config = SerialPortConfig()
    @State private var availablePorts: [String] = []
    @State private var isScanning = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "cable.connector")
                    .foregroundStyle(.blue)
                Text("Serial Port")
                    .font(.headline)
                Spacer()
                Button {
                    scanPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                }
                .help("Scan Ports")
                .disabled(isScanning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Configuration
            Form {
                Section("Port") {
                    Picker("Port", selection: $config.path) {
                        Text("Select Port").tag("")
                        ForEach(availablePorts, id: \.self) { port in
                            Text(port).tag(port)
                        }
                    }

                    if isScanning {
                        HStack {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Scanning...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Connection") {
                    Picker("Baud Rate", selection: $config.baudRate) {
                        ForEach(SerialPortConfig.defaultBaudRates, id: \.self) { rate in
                            Text("\(rate)").tag(rate)
                        }
                    }

                    Picker("Data Bits", selection: $config.dataBits) {
                        ForEach(5...8, id: \.self) { bits in
                            Text("\(bits)").tag(bits)
                        }
                    }

                    Picker("Stop Bits", selection: $config.stopBits) {
                        Text("1").tag(1.0)
                        Text("1.5").tag(1.5)
                        Text("2").tag(2.0)
                    }

                    Picker("Parity", selection: $config.parity) {
                        ForEach(SerialPortConfig.Parity.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }

                    Picker("Flow Control", selection: $config.flowControl) {
                        ForEach(SerialPortConfig.FlowControl.allCases, id: \.self) { fc in
                            Text(fc.displayName).tag(fc)
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
                    Label("Connect", systemImage: "bolt")
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
        // Scan for available serial ports
        // This would use IOKit or a serial port library
        // For now, show common port paths
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            availablePorts = [
                "/dev/tty.usbserial",
                "/dev/tty.usbmodem",
                "/dev/tty.SLAB_USBtoUART",
                "/dev/tty.wchusbserial",
            ]
            isScanning = false
        }
    }
}
