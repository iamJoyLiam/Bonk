//
//  SerialPort.swift
//  Bonk
//

import Foundation

/// A serial port configuration.
struct SerialPortConfig: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var path: String
    var baudRate: Int
    var dataBits: Int
    var stopBits: Double
    var parity: Parity
    var flowControl: FlowControl

    enum Parity: String, CaseIterable {
        case none
        case odd
        case even

        var displayName: String {
            rawValue.capitalized
        }
    }

    enum FlowControl: String, CaseIterable {
        case none
        case hardware
        case software

        var displayName: String {
            switch self {
            case .none: "None"
            case .hardware: "Hardware (RTS/CTS)"
            case .software: "Software (XON/XOFF)"
            }
        }
    }

    static let defaultBaudRates = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]

    init(
        name: String = "",
        path: String = "",
        baudRate: Int = 115200,
        dataBits: Int = 8,
        stopBits: Double = 1,
        parity: Parity = .none,
        flowControl: FlowControl = .none
    ) {
        self.name = name
        self.path = path
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.stopBits = stopBits
        self.parity = parity
        self.flowControl = flowControl
    }

    var displayDescription: String {
        "\(baudRate) \(dataBits)N\(Int(stopBits)) \(parity.rawValue)"
    }
}
