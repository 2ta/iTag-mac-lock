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
    }

    /// Default: roughly “across a room”. More negative = farther away before lock.
    static let defaultRSSIThreshold = -75
    static let defaultDebounceSeconds = 3.0

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
    }
}
