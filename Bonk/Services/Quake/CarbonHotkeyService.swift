//
//  CarbonHotkeyService.swift
//  Bonk
//
//  Carbon-based global hotkey implementation.
//

import Carbon
import os.log
import AppKit

// MARK: - Carbon Hotkey Service

/// Carbon-based implementation of GlobalHotkeyService.
@MainActor
final class CarbonHotkeyService: GlobalHotkeyService {
    private let logger = Logger(subsystem: "com.bonk", category: "Hotkey")

    var onPress: (() -> Void)?
    private var hotkeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var currentShortcut: HotkeyShortcut?

    var isRegistered: Bool { hotkeyRef != nil }

    // MARK: - Public API

    func register(shortcut: HotkeyShortcut) throws {
        // Unregister existing hotkey first
        unregister()

        let modifierFlags = carbonModifiers(from: shortcut.modifiers)
        var hotkeyID = EventHotKeyID()
        hotkeyID.signature = OSType(0x424E4B00) // "BNK\0"
        hotkeyID.id = 1

        // Install event handler
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = UInt32(kEventHotKeyPressed)

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        guard status == noErr else {
            logger.error("Failed to install event handler: \(status)")
            throw HotkeyError.handlerInstallationFailed
        }

        // Register hotkey
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            modifierFlags,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        guard registerStatus == noErr else {
            logger.error("Failed to register hotkey: \(registerStatus)")
            throw HotkeyError.registrationFailed
        }

        currentShortcut = shortcut
        logger.info("Registered hotkey: \(shortcut.description)")
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        currentShortcut = nil
        logger.info("Unregistered hotkey")
    }

    // MARK: - Helpers

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbonFlags: UInt32 = 0
        if flags.contains(.command) { carbonFlags |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonFlags |= UInt32(optionKey) }
        if flags.contains(.control) { carbonFlags |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonFlags |= UInt32(shiftKey) }
        return carbonFlags
    }

    /// Called by Carbon event handler.
    fileprivate func handleHotkeyEvent() {
        logger.info("Hotkey pressed")
        onPress?()
    }
}

// MARK: - Hotkey Errors

enum HotkeyError: Error, LocalizedError {
    case handlerInstallationFailed
    case registrationFailed

    var errorDescription: String? {
        switch self {
        case .handlerInstallationFailed:
            "Failed to install hotkey event handler"
        case .registrationFailed:
            "Failed to register global hotkey"
        }
    }
}

// MARK: - Carbon Callback

/// C callback for Carbon hotkey events.
private func hotkeyCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }

    let serviceRef = Unmanaged<CarbonHotkeyService>.fromOpaque(userData).takeUnretainedValue()

    Task { @MainActor in
        serviceRef.handleHotkeyEvent()
    }

    return noErr
}
