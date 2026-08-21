import ApplicationServices
import CoreGraphics
import Darwin

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
