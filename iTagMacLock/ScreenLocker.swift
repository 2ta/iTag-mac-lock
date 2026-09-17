import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum ScreenLocker {
    /// True when the loginwindow lock / screen saver lock is showing.
    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Locks the Mac immediately. No-op if the screen is already locked.
    static func lock() {
        guard !isScreenLocked() else { return }

        if lockViaLoginFramework() {
            return
        }
        lockViaKeystroke()
    }

    /// Same private API many proximity-lock utilities use. Does not need Accessibility.
    @discardableResult
    private static func lockViaLoginFramework() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            return false
        }
        defer { dlclose(handle) }

        typealias SACLockScreenImmediate = @convention(c) () -> Void
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            return false
        }
        unsafeBitCast(symbol, to: SACLockScreenImmediate.self)()
        return true
    }

    /// Types the Keychain password into the lock screen. Requires Accessibility.
    static func unlock() {
        guard isScreenLocked() else { return }
        guard let password = UnlockPasswordStore.load(), !password.isEmpty else { return }

        requestAccessibility()
        wakeDisplay()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            postKey(0x31) // space — focuses the password field
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            postUnicode(password)
            postKey(0x24) // return
        }
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func wakeDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "2"]
        try? process.run()

        let source = CGEventSource(stateID: .hidSystemState)
        let nudge = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: 8, y: 8),
            mouseButton: .left
        )
        nudge?.post(tap: .cghidEventTap)
    }

    private static func postUnicode(_ text: String) {
        guard !text.isEmpty else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        var utf16 = Array(text.utf16)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            return
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postKey(_ code: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Control-Command-Q. May require Accessibility permission if the private API is unavailable.
    private static func lockViaKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyQ: CGKeyCode = 0x0C
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyQ, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyQ, keyDown: false)
        else {
            return
        }
        keyDown.flags = [.maskCommand, .maskControl]
        keyUp.flags = [.maskCommand, .maskControl]
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
