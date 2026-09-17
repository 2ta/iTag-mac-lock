import Foundation

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let pairedPeripheralID = "pairedPeripheralID"
        static let pairedPeripheralName = "pairedPeripheralName"
        static let rssiThreshold = "rssiThreshold"
        static let debounceSeconds = "debounceSeconds"
        static let monitoringEnabled = "monitoringEnabled"
        static let countdownEnabled = "countdownEnabled"
        static let countdownSeconds = "countdownSeconds"
        static let buttonActionsEnabled = "buttonActionsEnabled"
        static let clickToLockEnabled = "clickToLockEnabled"
        static let doubleClickToUnlockEnabled = "doubleClickToUnlockEnabled"
        static let weeklyUpdateCheckEnabled = "weeklyUpdateCheckEnabled"
        static let lastUpdateCheckDate = "lastUpdateCheckDate"
    }

    /// Default: roughly “across a room”. More negative = farther away before lock.
    static let defaultRSSIThreshold = -75
    static let defaultDebounceSeconds = 3.0
    static let defaultCountdownSeconds = 10.0

    var pairedPeripheralID: UUID? {
        didSet {
            UserDefaults.standard.set(pairedPeripheralID?.uuidString, forKey: Key.pairedPeripheralID)
        }
    }

    var pairedPeripheralName: String? {
        didSet {
            UserDefaults.standard.set(pairedPeripheralName, forKey: Key.pairedPeripheralName)
        }
    }

    var rssiThreshold: Int {
        didSet {
            UserDefaults.standard.set(rssiThreshold, forKey: Key.rssiThreshold)
        }
    }

    var debounceSeconds: Double {
        didSet {
            UserDefaults.standard.set(debounceSeconds, forKey: Key.debounceSeconds)
        }
    }

    var monitoringEnabled: Bool {
        didSet {
            UserDefaults.standard.set(monitoringEnabled, forKey: Key.monitoringEnabled)
        }
    }

    var countdownEnabled: Bool {
        didSet {
            UserDefaults.standard.set(countdownEnabled, forKey: Key.countdownEnabled)
        }
    }

    var countdownSeconds: Double {
        didSet {
            UserDefaults.standard.set(countdownSeconds, forKey: Key.countdownSeconds)
        }
    }

    var clickToLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clickToLockEnabled, forKey: Key.clickToLockEnabled)
        }
    }

    var doubleClickToUnlockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(doubleClickToUnlockEnabled, forKey: Key.doubleClickToUnlockEnabled)
        }
    }

    var weeklyUpdateCheckEnabled: Bool {
        didSet {
            UserDefaults.standard.set(weeklyUpdateCheckEnabled, forKey: Key.weeklyUpdateCheckEnabled)
        }
    }

    var lastUpdateCheckDate: Date? {
        didSet {
            UserDefaults.standard.set(lastUpdateCheckDate, forKey: Key.lastUpdateCheckDate)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Key.pairedPeripheralID) {
            pairedPeripheralID = UUID(uuidString: raw)
        } else {
            pairedPeripheralID = nil
        }

        pairedPeripheralName = UserDefaults.standard.string(forKey: Key.pairedPeripheralName)

        if UserDefaults.standard.object(forKey: Key.rssiThreshold) != nil {
            rssiThreshold = UserDefaults.standard.integer(forKey: Key.rssiThreshold)
        } else {
            rssiThreshold = Self.defaultRSSIThreshold
        }

        if UserDefaults.standard.object(forKey: Key.debounceSeconds) != nil {
            debounceSeconds = UserDefaults.standard.double(forKey: Key.debounceSeconds)
        } else {
            debounceSeconds = Self.defaultDebounceSeconds
        }

        if UserDefaults.standard.object(forKey: Key.monitoringEnabled) != nil {
            monitoringEnabled = UserDefaults.standard.bool(forKey: Key.monitoringEnabled)
        } else {
            monitoringEnabled = true
        }

        if UserDefaults.standard.object(forKey: Key.countdownEnabled) != nil {
            countdownEnabled = UserDefaults.standard.bool(forKey: Key.countdownEnabled)
        } else {
            countdownEnabled = true
        }

        if UserDefaults.standard.object(forKey: Key.countdownSeconds) != nil {
            countdownSeconds = UserDefaults.standard.double(forKey: Key.countdownSeconds)
        } else {
            countdownSeconds = Self.defaultCountdownSeconds
        }

        clickToLockEnabled = Self.loadMigratedBool(key: Key.clickToLockEnabled)
        doubleClickToUnlockEnabled = Self.loadMigratedBool(key: Key.doubleClickToUnlockEnabled)

        if UserDefaults.standard.object(forKey: Key.weeklyUpdateCheckEnabled) != nil {
            weeklyUpdateCheckEnabled = UserDefaults.standard.bool(forKey: Key.weeklyUpdateCheckEnabled)
        } else {
            weeklyUpdateCheckEnabled = true
        }

        lastUpdateCheckDate = UserDefaults.standard.object(forKey: Key.lastUpdateCheckDate) as? Date
    }

    /// Prefer the split flag; fall back to the old combined `buttonActionsEnabled` so existing users keep their choice.
    private static func loadMigratedBool(key: String) -> Bool {
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        if UserDefaults.standard.object(forKey: Key.buttonActionsEnabled) != nil {
            return UserDefaults.standard.bool(forKey: Key.buttonActionsEnabled)
        }
        return true
    }
}
