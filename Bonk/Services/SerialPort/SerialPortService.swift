//
//  SerialPortService.swift
//  Bonk
//
//  Serial port connection service using IOKit.
//

import Foundation
import IOKit
import IOKit.serial
import os.log

/// Serial port connection service.
@Observable @MainActor
final class SerialPortService {
    static let shared = SerialPortService()

    private let logger = Logger(subsystem: "com.bonk", category: "SerialPort")

    var isConnected = false
    var lastError: String?
    var receivedData = Data()

    private var fileDescriptor: Int32 = -1
    private var readThread: Thread?
    private var onDataReceived: ((Data) -> Void)?

    private init() {}

    // MARK: - Public API

    /// Scan for available serial ports.
    func scanPorts() -> [String] {
        var ports: [String] = []

        // Check common serial port paths
        let commonPaths = [
            "/dev/tty.usbserial",
            "/dev/tty.usbmodem",
            "/dev/tty.SLAB_USBtoUART",
            "/dev/tty.wchusbserial",
            "/dev/tty.URT0",
            "/dev/tty.URT1",
        ]

        for path in commonPaths where FileManager.default.fileExists(atPath: path) {
            ports.append(path)
        }

        // Also check /dev/tty.* pattern
        if let enumerator = FileManager.default.enumerator(atPath: "/dev") {
            while let file = enumerator.nextObject() as? String {
                if file.hasPrefix("tty.") {
                    let fullPath = "/dev/\(file)"
                    if !ports.contains(fullPath) {
                        ports.append(fullPath)
                    }
                }
            }
        }

        return ports.sorted()
    }

    /// Connect to a serial port.
    func connect(config: SerialPortConfig) async throws {
        guard !isConnected else {
            throw SerialPortError.alreadyConnected
        }

        let path = config.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw SerialPortError.portNotFound(path)
        }

        // Open the serial port
        fileDescriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw SerialPortError.openFailed(path)
        }

        // Configure the port
        try configurePort(config: config)

        // Start reading
        startReading()

        isConnected = true
        lastError = nil
        logger.info("Connected to serial port: \(path)")
    }

    /// Disconnect from the serial port.
    func disconnect() {
        guard isConnected else { return }

        stopReading()

        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }

        isConnected = false
        logger.info("Disconnected from serial port")
    }

    /// Send data to the serial port.
    func send(_ data: Data) throws {
        guard isConnected else {
            throw SerialPortError.notConnected
        }

        let bytesWritten = data.withUnsafeBytes { buffer in
            write(fileDescriptor, buffer.baseAddress!, buffer.count)
        }

        guard bytesWritten >= 0 else {
            throw SerialPortError.writeFailed
        }
    }

    /// Send string to the serial port.
    func send(_ string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw SerialPortError.invalidData
        }
        try send(data)
    }

    /// Set callback for received data.
    func onData(_ callback: @escaping (Data) -> Void) {
        onDataReceived = callback
    }

    // MARK: - Private

    private func configurePort(config: SerialPortConfig) throws {
        var tty = termios()

        guard tcgetattr(fileDescriptor, &tty) == 0 else {
            throw SerialPortError.configureFailed
        }

        let baudRate = speed_t(config.baudRate)
        cfsetispeed(&tty, baudRate)
        cfsetospeed(&tty, baudRate)

        setDataBits(config.dataBits, tty: &tty)
        setStopBits(config.stopBits, tty: &tty)
        setParity(config.parity, tty: &tty)
        setFlowControl(config.flowControl, tty: &tty)

        tty.c_iflag &= ~UInt(ICRNL | INLCR | IGNCR | ISTRIP)
        tty.c_oflag &= ~UInt(OPOST | ONLCR | OCRNL | ONOCR | ONLRET)
        tty.c_lflag &= ~UInt(ICANON | ECHO | ECHOE | ISIG | IEXTEN)

        guard tcsetattr(fileDescriptor, TCSANOW, &tty) == 0 else {
            throw SerialPortError.configureFailed
        }
    }

    private func setDataBits(_ bits: Int, tty: inout termios) {
        tty.c_cflag &= ~UInt(CSIZE)
        switch bits {
        case 5: tty.c_cflag |= UInt(CS5)
        case 6: tty.c_cflag |= UInt(CS6)
        case 7: tty.c_cflag |= UInt(CS7)
        default: tty.c_cflag |= UInt(CS8)
        }
    }

    private func setStopBits(_ bits: Int, tty: inout termios) {
        if bits == 2 {
            tty.c_cflag |= UInt(CSTOPB)
        } else {
            tty.c_cflag &= ~UInt(CSTOPB)
        }
    }

    private func setParity(_ parity: SerialPortConfig.Parity, tty: inout termios) {
        switch parity {
        case .none:
            tty.c_cflag &= ~UInt(PARENB | PARODD)
        case .odd:
            tty.c_cflag |= UInt(PARENB | PARODD)
        case .even:
            tty.c_cflag |= UInt(PARENB)
            tty.c_cflag &= ~UInt(PARODD)
        }
    }

    private func setFlowControl(_ flowControl: SerialPortConfig.FlowControl, tty: inout termios) {
        switch flowControl {
        case .none:
            tty.c_cflag &= ~UInt(CRTSCTS)
            tty.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        case .hardware:
            tty.c_cflag |= UInt(CRTSCTS)
            tty.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        case .software:
            tty.c_cflag &= ~UInt(CRTSCTS)
            tty.c_iflag |= UInt(IXON | IXOFF | IXANY)
        }
    }

    private func startReading() {
        readThread = Thread { [weak self] in
            self?.readLoop()
        }
        readThread?.name = "SerialPortRead"
        readThread?.qualityOfService = .userInitiated
        readThread?.start()
    }

    private func stopReading() {
        readThread?.cancel()
        readThread = nil
    }

    private func readLoop() {
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while !Thread.current.isCancelled {
            let bytesRead = read(fileDescriptor, &buffer, bufferSize)

            if bytesRead > 0 {
                let data = Data(buffer[0 ..< bytesRead])
                DispatchQueue.main.async { [weak self] in
                    self?.receivedData.append(data)
                    self?.onDataReceived?(data)
                }
            } else if bytesRead < 0 {
                if errno != EAGAIN, errno != EWOULDBLOCK {
                    DispatchQueue.main.async { [weak self] in
                        self?.disconnect()
                        self?.lastError = "Read error: \(String(cString: strerror(errno)))"
                    }
                    break
                }
            }

            usleep(1000) // 1ms delay
        }
    }
}

// MARK: - Errors

enum SerialPortError: LocalizedError {
    case alreadyConnected
    case notConnected
    case portNotFound(String)
    case openFailed(String)
    case configureFailed
    case writeFailed
    case invalidData

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            "Already connected to a serial port"
        case .notConnected:
            "Not connected to a serial port"
        case let .portNotFound(path):
            "Serial port not found: \(path)"
        case let .openFailed(path):
            "Failed to open serial port: \(path)"
        case .configureFailed:
            "Failed to configure serial port"
        case .writeFailed:
            "Failed to write to serial port"
        case .invalidData:
            "Invalid data"
        }
    }
}
