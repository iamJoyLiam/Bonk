//
//  SafeCustomToolbar.swift
//  Bonk
//
//  Defensive NSToolbar subclass that tracks registered KVO observers.
//  Prevents SwiftUI's BarAppearanceBridge from crashing when it tries
//  to remove an observer that was never registered on our custom toolbar.
//

#if os(macOS)
    @preconcurrency import AppKit

    final class SafeCustomToolbar: NSToolbar, @unchecked Sendable {
        /// Tracks which (observer, keyPath) pairs were actually registered so removals are
        /// only forwarded to super when safe. Both public overloads share this guard, so a
        /// remove that lacks `context` still cleans up an add that had one (KVO allows this).
        private var registeredKeys = Set<String>()
        private let lock = NSLock()

        private func key(for observer: AnyObject, _ keyPath: String) -> String {
            "\(ObjectIdentifier(observer)):\(keyPath)"
        }

        /// Returns true and removes the entry if this (observer, keyPath) is registered;
        /// returns false otherwise (caller must then skip the super call).
        @discardableResult
        private func consumeRegistration(for observer: AnyObject, _ keyPath: String) -> Bool {
            let key = self.key(for: observer, keyPath)
            lock.lock()
            defer { lock.unlock() }
            guard registeredKeys.contains(key) else { return false }
            registeredKeys.remove(key)
            return true
        }

        @preconcurrency
        override func addObserver(
            _ observer: NSObject,
            forKeyPath keyPath: String,
            options: NSKeyValueObservingOptions = [],
            context: UnsafeMutableRawPointer?
        ) {
            lock.lock()
            registeredKeys.insert(key(for: observer, keyPath))
            lock.unlock()
            super.addObserver(observer, forKeyPath: keyPath, options: options, context: context)
        }

        @preconcurrency
        override func removeObserver(
            _ observer: NSObject,
            forKeyPath keyPath: String,
            context: UnsafeMutableRawPointer?
        ) {
            guard consumeRegistration(for: observer, keyPath) else { return }
            super.removeObserver(observer, forKeyPath: keyPath, context: context)
        }

        @preconcurrency
        override func removeObserver(
            _ observer: NSObject,
            forKeyPath keyPath: String
        ) {
            guard consumeRegistration(for: observer, keyPath) else { return }
            super.removeObserver(observer, forKeyPath: keyPath)
        }
    }
#endif
