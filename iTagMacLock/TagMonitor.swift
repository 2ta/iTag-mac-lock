@preconcurrency import CoreBluetooth
import Foundation

struct DiscoveredTag: Identifiable {
    var id: UUID { peripheral.identifier }
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var isLikelyITag: Bool
}

enum MonitorStatus: Equatable {
    case bluetoothUnavailable
    case bluetoothOff
    case unauthorized
    case noDevice
    case scanning
    case connecting
    case paused
    case connected
    case weakSignal
    case disconnected
}

@MainActor
@Observable
final class TagMonitor: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = TagMonitor()

    let settings = AppSettings.shared

    private(set) var status: MonitorStatus = .noDevice
    private(set) var bluetoothState: CBManagerState = .unknown
    private(set) var discovered: [DiscoveredTag] = []
    private(set) var rawRSSI: Int?
    private(set) var smoothedRSSI: Double?
    private(set) var isUserScanning = false

    var menuBarSymbol: String {
        switch status {
        case .bluetoothOff, .bluetoothUnavailable, .unauthorized:
            return "antenna.radiowaves.left.and.right.slash"
        case .paused:
            return "pause.circle"
        case .scanning:
            return "location.magnifyingglass"
        case .connecting:
            return "lock.circle"
        case .connected:
            return "dot.radiowaves.left.and.right"
        case .weakSignal, .disconnected:
            return "lock.fill"
        case .noDevice:
            return "lock.circle"
        }
    }

    var statusText: String {
        switch status {
        case .bluetoothUnavailable:
            return "Bluetooth is not available on this Mac."
        case .bluetoothOff:
            return "Bluetooth is off. Turn it on to monitor your iTag. The Mac will not lock."
        case .unauthorized:
            return "Bluetooth access is denied. Enable it in System Settings → Privacy & Security → Bluetooth."
        case .noDevice:
            return "No tag paired. Scan and choose your iTag."
        case .scanning:
            return isUserScanning ? "Scanning for nearby tags…" : "Looking for your paired tag…"
        case .connecting:
            return "Connecting to \(displayName)…"
        case .paused:
            return "Monitoring paused."
        case .connected:
            return "Connected to \(displayName)."
        case .weakSignal:
            return "Signal is weak. Locking if it stays weak."
        case .disconnected:
            return "Tag disconnected. Trying to reconnect…"
        }
    }

    var displayName: String {
        settings.pairedPeripheralName ?? "iTag"
    }

    private var central: CBCentralManager!
    private var pairedPeripheral: CBPeripheral?
    private var rssiTimer: Timer?
    private var reconnectTimer: Timer?
    private var connectTimeout: Timer?
    private var weakSince: Date?
    /// After a lock, wait until the tag is nearby again before another lock can fire.
    private var lockArmed = false
    private var userInitiatedDisconnect = false
    private var keepAlive: NSObjectProtocol?
    private var isReconnectScan = false

    private static let rssiSmoothing = 0.3
    private static let hysteresis = 5.0
    private static let invalidRSSI = 127

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        updateKeepAlive()
    }

    // MARK: - Public actions

    func startUserScan() {
        guard bluetoothState == .poweredOn else { return }
        isUserScanning = true
        isReconnectScan = false
        discovered.removeAll()
        beginScan(allowDuplicates: true)
        status = .scanning
    }

    func stopUserScan() {
        isUserScanning = false
        if pairedPeripheral?.state == .connected {
            central.stopScan()
            status = currentConnectedStatus()
        } else if settings.pairedPeripheralID != nil, settings.monitoringEnabled {
            startReconnectScan()
        } else {
            central.stopScan()
            status = settings.pairedPeripheralID == nil ? .noDevice : .paused
        }
    }

    func pair(_ tag: DiscoveredTag) {
        settings.pairedPeripheralID = tag.id
        settings.pairedPeripheralName = tag.name
        isUserScanning = false
        isReconnectScan = false
        central.stopScan()
        lockArmed = false
        connect(tag.peripheral)
    }

    func forgetDevice() {
        userInitiatedDisconnect = true
        stopTimers()
        central.stopScan()
        isUserScanning = false
        isReconnectScan = false
        if let peripheral = pairedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        pairedPeripheral = nil
        settings.pairedPeripheralID = nil
        settings.pairedPeripheralName = nil
        rawRSSI = nil
        smoothedRSSI = nil
        weakSince = nil
        lockArmed = false
        status = bluetoothState == .poweredOn ? .noDevice : statusFromBluetooth()
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        settings.monitoringEnabled = enabled
        updateKeepAlive()

        if !enabled {
            userInitiatedDisconnect = true
            stopTimers()
            central.stopScan()
            isUserScanning = false
            isReconnectScan = false
            if let peripheral = pairedPeripheral {
                central.cancelPeripheralConnection(peripheral)
            }
            rawRSSI = nil
            smoothedRSSI = nil
            weakSince = nil
            lockArmed = false
            status = .paused
            return
        }

        guard bluetoothState == .poweredOn else {
            status = statusFromBluetooth()
            return
        }
        attemptReconnect()
    }

    // MARK: - CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            self.handleBluetoothState(state)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        Task { @MainActor in
            self.handleDiscover(peripheral, advertisedName: advertisedName, rssi: rssi)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.handleConnect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.handleConnectFailure(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.handleDisconnect(peripheral)
        }
    }

    // MARK: - CBPeripheralDelegate

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let rssi = RSSI.intValue
        let failed = error != nil
        Task { @MainActor in
            if failed { return }
            self.handleRSSI(rssi)
        }
    }

    nonisolated func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        let name = peripheral.name
        Task { @MainActor in
            if self.pairedPeripheral?.identifier == peripheral.identifier, let name, !name.isEmpty {
                self.settings.pairedPeripheralName = name
            }
        }
    }

    // MARK: - Bluetooth state

    private func handleBluetoothState(_ state: CBManagerState) {
        bluetoothState = state

        switch state {
        case .poweredOn:
            updateKeepAlive()
            if isUserScanning {
                beginScan(allowDuplicates: true)
                status = .scanning
            } else if settings.monitoringEnabled, settings.pairedPeripheralID != nil {
                attemptReconnect()
            } else if settings.pairedPeripheralID == nil {
                status = .noDevice
            } else {
                status = .paused
            }
        case .poweredOff:
            // User turned Bluetooth off: pause, do not lock.
            enterBluetoothOffState(status: .bluetoothOff)
        case .unauthorized:
            enterBluetoothOffState(status: .unauthorized)
        case .unsupported, .unknown, .resetting:
            enterBluetoothOffState(status: .bluetoothUnavailable)
        @unknown default:
            enterBluetoothOffState(status: .bluetoothUnavailable)
        }
    }

    private func enterBluetoothOffState(status: MonitorStatus) {
        stopTimers()
        central.stopScan()
        isReconnectScan = false
        rawRSSI = nil
        smoothedRSSI = nil
        weakSince = nil
        lockArmed = false
        pairedPeripheral = nil
        self.status = status
        updateKeepAlive()
    }

    private func statusFromBluetooth() -> MonitorStatus {
        switch bluetoothState {
        case .poweredOn: return settings.pairedPeripheralID == nil ? .noDevice : .paused
        case .poweredOff: return .bluetoothOff
        case .unauthorized: return .unauthorized
        default: return .bluetoothUnavailable
        }
    }

    // MARK: - Scan / connect / reconnect

    private func beginScan(allowDuplicates: Bool) {
        central.stopScan()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
    }

    private func handleDiscover(_ peripheral: CBPeripheral, advertisedName: String?, rssi: Int) {
        let name = resolvedName(peripheral, advertisedName: advertisedName)
        let likely = Self.isLikelyITag(name)
        let sample = rssi == Self.invalidRSSI ? -100 : rssi

        if let index = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            discovered[index].name = name
            discovered[index].rssi = sample
            discovered[index].isLikelyITag = likely
        } else {
            discovered.append(
                DiscoveredTag(peripheral: peripheral, name: name, rssi: sample, isLikelyITag: likely)
            )
        }
        sortDiscovered()

        guard !isUserScanning, isReconnectScan, settings.monitoringEnabled else { return }
        if matchesPairedTag(peripheral, name: name) {
            central.stopScan()
            isReconnectScan = false
            connect(peripheral)
        }
    }

    private func matchesPairedTag(_ peripheral: CBPeripheral, name: String) -> Bool {
        if let id = settings.pairedPeripheralID, peripheral.identifier == id {
            return true
        }
        if let saved = settings.pairedPeripheralName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty,
           name.compare(saved, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }
        return false
    }

    private func connect(_ peripheral: CBPeripheral) {
        pairedPeripheral = peripheral
        peripheral.delegate = self
        status = .connecting
        connectTimeout?.invalidate()
        let timeout = Timer(timeInterval: 12, repeats: false) { _ in
            Task { @MainActor in
                TagMonitor.shared.handleConnectTimeout()
            }
        }
        RunLoop.main.add(timeout, forMode: .common)
        connectTimeout = timeout
        central.connect(peripheral, options: nil)
    }

    private func handleConnectTimeout() {
        guard status == .connecting, let peripheral = pairedPeripheral else { return }
        userInitiatedDisconnect = true
        central.cancelPeripheralConnection(peripheral)
        userInitiatedDisconnect = false
        status = .disconnected
        scheduleReconnect()
    }

    private func handleConnect(_ peripheral: CBPeripheral) {
        connectTimeout?.invalidate()
        connectTimeout = nil
        pairedPeripheral = peripheral
        peripheral.delegate = self
        if let name = peripheral.name, !name.isEmpty {
            settings.pairedPeripheralName = name
        }
        rawRSSI = nil
        smoothedRSSI = nil
        weakSince = nil
        status = .connected
        startRSSIPolling(peripheral)
        peripheral.readRSSI()
    }

    private func handleConnectFailure(_ peripheral: CBPeripheral) {
        connectTimeout?.invalidate()
        connectTimeout = nil
        guard settings.pairedPeripheralID == peripheral.identifier else { return }
        status = .disconnected
        scheduleReconnect()
    }

    private func handleDisconnect(_ peripheral: CBPeripheral) {
        connectTimeout?.invalidate()
        connectTimeout = nil
        stopRSSIPolling()
        rawRSSI = nil
        smoothedRSSI = nil
        weakSince = nil

        let initiated = userInitiatedDisconnect
        userInitiatedDisconnect = false

        let bluetoothOn = bluetoothState == .poweredOn
        let shouldLock = !initiated
            && bluetoothOn
            && settings.monitoringEnabled
            && settings.pairedPeripheralID == peripheral.identifier

        if shouldLock {
            triggerAway()
        }

        if initiated {
            if !settings.monitoringEnabled {
                status = bluetoothOn ? .paused : statusFromBluetooth()
            } else if settings.pairedPeripheralID == nil {
                status = bluetoothOn ? .noDevice : statusFromBluetooth()
            }
            return
        }

        guard bluetoothOn, settings.monitoringEnabled, settings.pairedPeripheralID != nil else {
            return
        }
        status = .disconnected
        scheduleReconnect()
    }

    private func attemptReconnect() {
        guard bluetoothState == .poweredOn, settings.monitoringEnabled else { return }
        guard let id = settings.pairedPeripheralID else {
            status = .noDevice
            return
        }

        if let connected = central.retrieveConnectedPeripherals(withServices: Self.itagServiceUUIDs)
            .first(where: { $0.identifier == id }) {
            connect(connected)
            return
        }

        let retrieved = central.retrievePeripherals(withIdentifiers: [id])
        if let peripheral = retrieved.first {
            connect(peripheral)
            return
        }

        startReconnectScan()
    }

    private func startReconnectScan() {
        guard bluetoothState == .poweredOn, settings.monitoringEnabled else { return }
        isReconnectScan = true
        isUserScanning = false
        beginScan(allowDuplicates: true)
        status = .scanning
    }

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
            Task { @MainActor in
                TagMonitor.shared.attemptReconnect()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconnectTimer = timer
    }

    // MARK: - RSSI

    private func startRSSIPolling(_ peripheral: CBPeripheral) {
        rssiTimer?.invalidate()
        let identifier = peripheral.identifier
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                TagMonitor.shared.pollRSSI(expectedID: identifier)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rssiTimer = timer
    }

    private func pollRSSI(expectedID: UUID) {
        guard let peripheral = pairedPeripheral, peripheral.identifier == expectedID else { return }
        guard peripheral.state == .connected else { return }
        peripheral.readRSSI()
    }

    private func stopRSSIPolling() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }

    private func handleRSSI(_ rssi: Int) {
        guard rssi != Self.invalidRSSI, rssi < 20 else { return }
        rawRSSI = rssi

        let sample = Double(rssi)
        if let previous = smoothedRSSI {
            smoothedRSSI = Self.rssiSmoothing * sample + (1 - Self.rssiSmoothing) * previous
        } else {
            smoothedRSSI = sample
        }

        evaluateProximity()
    }

    private func evaluateProximity() {
        guard settings.monitoringEnabled, pairedPeripheral?.state == .connected else { return }
        guard let smoothed = smoothedRSSI else { return }

        let threshold = Double(settings.rssiThreshold)
        if smoothed <= threshold {
            status = .weakSignal
            if weakSince == nil {
                weakSince = Date()
            }
            if let weakSince, Date().timeIntervalSince(weakSince) >= settings.debounceSeconds {
                triggerAway()
            }
        } else {
            weakSince = nil
            status = .connected
            if smoothed >= threshold + Self.hysteresis {
                lockArmed = true
            }
        }
    }

    private func currentConnectedStatus() -> MonitorStatus {
        if let smoothed = smoothedRSSI, smoothed <= Double(settings.rssiThreshold) {
            return .weakSignal
        }
        return .connected
    }

    // MARK: - Lock

    private func triggerAway() {
        guard lockArmed else { return }
        guard settings.monitoringEnabled else { return }
        guard bluetoothState == .poweredOn else { return }
        lockArmed = false
        ScreenLocker.lock()
    }

    // MARK: - Keep-alive / timers

    private func updateKeepAlive() {
        if let keepAlive {
            ProcessInfo.processInfo.endActivity(keepAlive)
            self.keepAlive = nil
        }
        let shouldStayAwake = bluetoothState == .poweredOn && settings.monitoringEnabled
        guard shouldStayAwake else { return }
        keepAlive = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Monitor iTag proximity"
        )
    }

    private func stopTimers() {
        rssiTimer?.invalidate()
        rssiTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        connectTimeout?.invalidate()
        connectTimeout = nil
    }

    // MARK: - Helpers

    private func resolvedName(_ peripheral: CBPeripheral, advertisedName: String?) -> String {
        if let advertisedName, !advertisedName.isEmpty { return advertisedName }
        if let name = peripheral.name, !name.isEmpty { return name }
        if let existing = discovered.first(where: { $0.id == peripheral.identifier })?.name,
           existing != "Unknown" {
            return existing
        }
        return "Unknown"
    }

    private func sortDiscovered() {
        discovered.sort { lhs, rhs in
            if lhs.isLikelyITag != rhs.isLikelyITag {
                return lhs.isLikelyITag && !rhs.isLikelyITag
            }
            return lhs.rssi > rhs.rssi
        }
    }

    private static func isLikelyITag(_ name: String) -> Bool {
        let folded = name.lowercased().replacingOccurrences(of: " ", with: "")
        return folded.contains("itag") || folded.contains("i-tag")
    }

    private static let itagServiceUUIDs: [CBUUID] = [
        CBUUID(string: "1802"),
        CBUUID(string: "1803"),
        CBUUID(string: "180F"),
        CBUUID(string: "FFE0"),
    ]
}
