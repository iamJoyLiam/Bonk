//
//  SerialPortService.swift
//  Bonk
//
//  Serial port connection service using IOKit.
//

import Darwin
import Foundation
import IOKit
import IOKit.serial
import os.log

extension Notification.Name {
    static let serialPortsChanged = Notification.Name("com.bonk.serialPortsChanged")
}

/// A detected serial device with a friendly display name.
struct SerialPortDevice: Identifiable, Hashable {
    let path: String
    let deviceName: String
    let productName: String?
    let kind: SerialPortKind

    var id: String {
        path
    }

    /// Short, human-readable name shown in the port picker.
    var displayName: String {
        if let productName, !productName.isEmpty, productName != deviceName {
            return "\(deviceName) · \(productName)"
        }
        return deviceName
    }
}

enum SerialPortKind: String, Hashable {
    case usb
    case bluetooth
    case other
    case internalConsole

    var sortOrder: Int {
        switch self {
        case .usb:
            0
        case .bluetooth:
            1
        case .other:
            2
        case .internalConsole:
            3
        }
    }

    var iconName: String {
        switch self {
        case .usb:
            "cable.connector"
        case .bluetooth:
            "wave.3.right.circle"
        case .other:
            "externaldrive"
        case .internalConsole:
            "terminal"
        }
    }
}

/// Serial port connection service.
@Observable @MainActor
final class SerialPortService {
    static let shared = SerialPortService()

    private let logger = Logger(subsystem: "com.bonk", category: "SerialPort")

    nonisolated(unsafe) private var notificationPort: OpaquePointer?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var matchedIterator: io_iterator_t = 0
    nonisolated(unsafe) private var removedIterator: io_iterator_t = 0
    nonisolated(unsafe) private var isMonitoring = false

    deinit {
        // Ensure IOKit resources are released even if stopMonitoring was not called.
        // SerialPortService is a long-lived singleton, but deinit handles unit-test teardown.
        if isMonitoring {
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }
            if matchedIterator != 0 { IOObjectRelease(matchedIterator) }
            if removedIterator != 0 { IOObjectRelease(removedIterator) }
            if let port = notificationPort { IONotificationPortDestroy(port) }
        }
    }

    /// IOSSIOSPEED request codes from `IOKit/serial/ioss.h` — Swift cannot
    /// import these macros. The 8-byte variant matches `speed_t` on LP64;
    /// the 4-byte variant is what pyserial/serial2 ship for compatibility.
    private static let iossIOSpeed64Request: UInt = 0x8008_5402
    private static let iossIOSpeed32Request: UInt = 0x8004_5402

    /// Currently open serial ports (path → session). USB drivers often do not
    /// report EBUSY on a second open(), so without this guard two panes could
    /// read the same data stream twice (duplicate output, interleaved writes).
    private var openPorts: [String: WeakRefBox<PTYSession>] = [:]

    private init() {}

    // MARK: - Port Scanning

    /// Scan for available serial ports. Prefers call-out (`/dev/cu.*`) nodes,
    /// which are the correct device nodes for outgoing terminal connections.
    func scanPorts() -> [SerialPortDevice] {
        var devices: [SerialPortDevice] = []
        var usedNames = Set<String>()
        var iterator: io_iterator_t = 0

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOSerialBSDClient"),
            &iterator
        ) == KERN_SUCCESS else {
            return devices
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            let callout = ioProperty(service, key: kIOCalloutDeviceKey) as? String
            let dialin = ioProperty(service, key: kIODialinDeviceKey) as? String
            guard let path = callout ?? dialin, !path.isEmpty else { continue }

            let name = (ioProperty(service, key: kIOTTYDeviceKey) as? String)
                ?? URL(fileURLWithPath: path).lastPathComponent
            guard usedNames.insert(name).inserted else { continue }

            let productName = usbProductName(for: service)
            let kind = classify(name, hasUSBProduct: productName != nil)
            // Apple's internal debug console is not a user-facing serial port.
            guard kind != .internalConsole else { continue }

            devices.append(SerialPortDevice(
                path: path,
                deviceName: name,
                productName: productName,
                kind: kind
            ))
        }

        return devices.sorted {
            if $0.kind != $1.kind {
                return $0.kind.sortOrder < $1.kind.sortOrder
            }
            return $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
        }
    }

    // MARK: - Hot Plug Monitoring

    /// Start watching for serial devices being plugged in or removed.
    /// Posts `.serialPortsChanged` on the main thread when the device set changes.
    func startMonitoring() {
        guard !isMonitoring else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }

        isMonitoring = true
        notificationPort = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        let matchedMatching = IOServiceMatching("IOSerialBSDClient")
        IOServiceAddMatchingNotification(
            port,
            kIOMatchedNotification,
            matchedMatching,
            serialPortsChangedCallback,
            nil,
            &matchedIterator
        )
        drain(matchedIterator)

        let removedMatching = IOServiceMatching("IOSerialBSDClient")
        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            removedMatching,
            serialPortsChangedCallback,
            nil,
            &removedIterator
        )
        drain(removedIterator)
    }

    /// Stop watching for serial device changes.
    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        if matchedIterator != 0 {
            IOObjectRelease(matchedIterator)
            matchedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    // MARK: - Connection

    /// Open and configure a serial port, returning a PTY session that owns
    /// the file descriptor.
    func openSession(config: SerialPortConfig, onDisconnect: (@Sendable () -> Void)? = nil) throws -> PTYSession {
        let path = config.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw SerialPortError.portNotFound(path)
        }

        // Reject a second open of the same device while a live session exists.
        if let existing = openPorts[path]?.value, !existing.isClosed {
            throw SerialPortError.portInUse(path)
        }

        let fileDescriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw SerialPortError.openFailed(path, String(cString: strerror(errno)))
        }

        do {
            try configurePort(fileDescriptor, config: config)
        } catch {
            close(fileDescriptor)
            throw error
        }

        let session = PTYSession()
        session.onUnexpectedClose = onDisconnect
        session.startSerial(fileDescriptor: fileDescriptor)
        openPorts[path] = WeakRefBox(session)
        logger.info("Opened serial port: \(path, privacy: .public)")
        return session
    }

    // MARK: - Private

    private func ioProperty(_ service: io_service_t, key: String) -> CFTypeRef? {
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        return property.takeRetainedValue()
    }

    /// Look up the USB product/vendor name by walking up the IOKit registry
    /// from the serial device to its USB parent.
    private func usbProductName(for service: io_service_t) -> String? {
        let product = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "USB Product Name" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) as? String
        if let product, !product.isEmpty { return product }

        let vendor = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "USB Vendor Name" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) as? String
        return vendor.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func classify(_ deviceName: String, hasUSBProduct: Bool) -> SerialPortKind {
        let lower = deviceName.lowercased()
        if lower.contains("bluetooth") { return .bluetooth }
        if lower.contains("debug-console") || lower.contains("usbdebug") {
            return .internalConsole
        }
        if hasUSBProduct
            || lower.hasPrefix("usbserial")
            || lower.hasPrefix("usbmodem")
            || lower.hasPrefix("usb")
        {
            return .usb
        }
        return .other
    }

    private func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private func configurePort(_ fileDescriptor: Int32, config: SerialPortConfig) throws {
        var tty = termios()
        guard tcgetattr(fileDescriptor, &tty) == 0 else {
            throw SerialPortError.configureFailed(String(cString: strerror(errno)))
        }

        tty.c_cflag &= ~UInt(CSIZE | PARENB | CSTOPB | CRTSCTS)
        tty.c_cflag |= UInt(CLOCAL | CREAD)

        setDataBits(config.dataBits, tty: &tty)
        setStopBits(config.stopBits, tty: &tty)
        setParity(config.parity, tty: &tty)
        setFlowControl(config.flowControl, tty: &tty)

        tty.c_iflag &= ~UInt(ICRNL | INLCR | IGNCR | ISTRIP)
        tty.c_oflag &= ~UInt(OPOST | ONLCR | OCRNL | ONOCR | ONLRET)
        tty.c_lflag &= ~UInt(ICANON | ECHO | ECHOE | ISIG | IEXTEN)

        let baud = config.baudRate > 230_400
            ? speed_t(B38400)
            : baudRateConstant(config.baudRate)
        guard cfsetispeed(&tty, baud) == 0, cfsetospeed(&tty, baud) == 0 else {
            throw SerialPortError.configureFailed(String(cString: strerror(errno)))
        }

        guard tcsetattr(fileDescriptor, TCSANOW, &tty) == 0 else {
            throw SerialPortError.configureFailed(String(cString: strerror(errno)))
        }

        // Drop stale input buffered by the driver before the session starts.
        tcflush(fileDescriptor, TCIOFLUSH)

        // macOS has no B460800/B921600 constants — IOSSIOSPEED sets them directly.
        if config.baudRate > 230_400 {
            try setCustomBaudRate(fileDescriptor, baudRate: config.baudRate)
        }
    }

    private func setCustomBaudRate(_ fileDescriptor: Int32, baudRate: Int) throws {
        // The 8-byte variant is the canonical IOSSIOSPEED; the 4-byte variant
        // covers drivers/kernels that only accept the legacy request code.
        // Accept either, then report both errno values if both fail.
        var speed64 = speed_t(baudRate)
        if ioctl(fileDescriptor, Self.iossIOSpeed64Request, &speed64) == 0 {
            return
        }
        let firstError = String(cString: strerror(errno))

        var speed32 = UInt32(baudRate)
        guard ioctl(fileDescriptor, Self.iossIOSpeed32Request, &speed32) == 0 else {
            let secondError = String(cString: strerror(errno))
            throw SerialPortError.configureFailed(
                "Cannot set \(baudRate) baud (IOSSIOSPEED: \(firstError) / \(secondError))"
            )
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

    private func setStopBits(_ bits: Double, tty: inout termios) {
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

    private func baudRateConstant(_ rate: Int) -> speed_t {
        switch rate {
        case 1200: speed_t(B1200)
        case 2400: speed_t(B2400)
        case 4800: speed_t(B4800)
        case 9600: speed_t(B9600)
        case 19200: speed_t(B19200)
        case 38400: speed_t(B38400)
        case 57600: speed_t(B57600)
        case 115_200: speed_t(B115200)
        case 230_400: speed_t(B230400)
        default: speed_t(B9600)
        }
    }
}

/// IOKit callback for matched/terminated serial devices.
private func serialPortsChangedCallback(_: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    var service = IOIteratorNext(iterator)
    while service != 0 {
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .serialPortsChanged, object: nil)
    }
}

// MARK: - Errors

enum SerialPortError: LocalizedError {
    case portNotFound(String)
    case openFailed(String, String)
    case configureFailed(String)
    case writeFailed(String)
    case portInUse(String)

    var errorDescription: String? {
        switch self {
        case let .portNotFound(path):
            "Serial port not found: \(path)"
        case let .openFailed(path, reason):
            "Failed to open serial port \(path): \(reason)"
        case let .configureFailed(reason):
            "Failed to configure serial port: \(reason)"
        case let .writeFailed(reason):
            "Failed to write to serial port: \(reason)"
        case let .portInUse(path):
            "Serial port already in use: \(path)"
        }
    }
}

/// A weak reference box so the port map does not retain sessions.
private final class WeakRefBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
