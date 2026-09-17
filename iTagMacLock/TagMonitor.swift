@preconcurrency import CoreBluetooth
import Foundation

struct DiscoveredTag: Identifiable {
    var id: UUID { peripheral.identifier }
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var isLikelyITag: Bool

    var displayName: String {
        if name != "Unknown" { return name }
        return isLikelyITag ? "iTAG (no name)" : "Unnamed device"
    }
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
    case lockingSoon
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
    /// Whole seconds left before lock. `nil` when no countdown is running.
    private(set) var countdownRemaining: Int?

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
        case .lockingSoon:
            return "lock.trianglebadge.exclamationmark"
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
            return connectedHintText
        case .weakSignal:
            return "Signal is weak. Locking if it stays weak."
        case .disconnected:
            return "Tag disconnected. Trying to reconnect…"
        case .lockingSoon:
            let seconds = countdownRemaining ?? 0
            return seconds == 1
                ? "Locking in 1 second. Cancel if you want to stay unlocked."
                : "Locking in \(seconds) seconds. Cancel if you want to stay unlocked."
        }
    }

    var displayName: String {
        settings.pairedPeripheralName ?? "iTag"
    }

    private var connectedHintText: String {
        switch (settings.clickToLockEnabled, settings.doubleClickToUnlockEnabled) {
        case (true, true):
            return "Connected to \(displayName). Click the tag to lock, double-click to unlock."
        case (true, false):
            return "Connected to \(displayName). Click the tag to lock."
        case (false, true):
            return "Connected to \(displayName). Double-click the tag to unlock."
        case (false, false):
            return "Connected to \(displayName)."
        }
    }

    private var central: CBCentralManager!
    private var pairedPeripheral: CBPeripheral?
    private var rssiTimer: Timer?
    private var reconnectTimer: Timer?
    private var connectTimeout: Timer?
    private var lockCountdownTimer: Timer?
    private var weakSince: Date?
    /// After a lock, wait until the tag is nearby again before another lock can fire.
    private var lockArmed = false
    private var userInitiatedDisconnect = false
    private var keepAlive: NSObjectProtocol?
    private var isReconnectScan = false
    private var pendingSingleClickTimer: Timer?
    private var awaitingSecondClick = false
    private var clickDebounceUntil = Date.distantPast
    private var silenceCharacteristics: [CBCharacteristic] = []
    private var silenceRetryTimers: [Timer] = []
    private var silenceKeepAliveTimer: Timer?

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
        seedConnectedPeripherals()
        beginScan(allowDuplicates: true)
        status = .scanning
        PairingPanel.show()
    }

    func stopUserScan() {
        isUserScanning = false
        PairingPanel.hide()
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
        settings.pairedPeripheralName = tag.name == "Unknown" ? "iTAG" : tag.name
        isUserScanning = false
        isReconnectScan = false
        central.stopScan()
        lockArmed = false
        PairingPanel.hide()
        connect(tag.peripheral)
    }

    func forgetDevice() {
        userInitiatedDisconnect = true
        stopTimers()
        central.stopScan()
        isUserScanning = false
        isReconnectScan = false
        disconnectQuietly()
        pairedPeripheral = nil
        settings.pairedPeripheralID = nil
        settings.pairedPeripheralName = nil
        rawRSSI = nil
        smoothedRSSI = nil
        weakSince = nil
        lockArmed = false
        clearLockCountdown()
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
            disconnectQuietly()
            rawRSSI = nil
            smoothedRSSI = nil
            weakSince = nil
            lockArmed = false
            clearLockCountdown()
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
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let services = advertised + overflow
        Task { @MainActor in
            self.handleDiscover(peripheral, advertisedName: advertisedName, rssi: rssi, services: services)
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

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            self.handleDiscoveredServices(peripheral)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            self.handleDiscoveredCharacteristics(peripheral, service: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil else { return }
        Task { @MainActor in
            self.handleButtonNotification(from: characteristic)
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
        clearLockCountdown()
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

    private func seedConnectedPeripherals() {
        let connected = central.retrieveConnectedPeripherals(withServices: Self.itagServiceUUIDs)
        for peripheral in connected {
            handleDiscover(
                peripheral,
                advertisedName: peripheral.name,
                rssi: -40,
                services: Self.itagHintServiceUUIDs
            )
        }
    }

    private func handleDiscover(_ peripheral: CBPeripheral, advertisedName: String?, rssi: Int, services: [CBUUID]) {
        let name = resolvedName(peripheral, advertisedName: advertisedName)
        let likely = Self.isLikelyITag(name: name, services: services)
        let sample = rssi == Self.invalidRSSI ? -100 : rssi
        let isNew: Bool

        if let index = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
            isNew = false
            discovered[index].name = name
            discovered[index].rssi = sample
            discovered[index].isLikelyITag = likely || discovered[index].isLikelyITag
        } else {
            isNew = true
            discovered.append(
                DiscoveredTag(peripheral: peripheral, name: name, rssi: sample, isLikelyITag: likely)
            )
        }
        sortDiscovered()
        if isUserScanning {
            PairingPanel.refresh(force: isNew)
        }

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
        silenceCharacteristics.removeAll()
        stopSilenceWrites()
        peripheral.discoverServices(nil)
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
        stopSilenceWrites()
        rawRSSI = nil
        smoothedRSSI = nil
        weakSince = nil
        silenceCharacteristics.removeAll()

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
        if countdownRemaining == nil {
            status = .disconnected
        }
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
            if countdownRemaining == nil {
                status = .weakSignal
            }
            if weakSince == nil {
                weakSince = Date()
                // Last chance to set No Alert before the radio drops out of range.
                silenceTag()
            }
            if countdownRemaining == nil,
               let weakSince, Date().timeIntervalSince(weakSince) >= settings.debounceSeconds {
                triggerAway()
            }
        } else {
            weakSince = nil
            if countdownRemaining != nil, smoothed >= threshold + Self.hysteresis {
                cancelLockCountdown()
            } else if countdownRemaining == nil {
                status = .connected
            }
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

        if settings.countdownEnabled {
            startLockCountdown()
        } else {
            ScreenLocker.lock()
        }
    }

    private func startLockCountdown() {
        guard countdownRemaining == nil else { return }
        let seconds = max(1, Int(settings.countdownSeconds.rounded()))
        countdownRemaining = seconds
        status = .lockingSoon
        LockCountdownPanel.show()
        LockCountdownPanel.refresh()
        startCountdownTicker()
    }

    private func startCountdownTicker() {
        lockCountdownTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                TagMonitor.shared.tickLockCountdown()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lockCountdownTimer = timer
    }

    private func tickLockCountdown() {
        guard let remaining = countdownRemaining else { return }
        if remaining <= 1 {
            lockNow()
            return
        }
        countdownRemaining = remaining - 1
        status = .lockingSoon
        LockCountdownPanel.refresh()
    }

    func cancelLockCountdown() {
        clearLockCountdown()
        restoreStatusAfterCountdown()
    }

    func lockNow() {
        clearLockCountdown()
        ScreenLocker.lock()
        restoreStatusAfterCountdown()
    }

    private func clearLockCountdown() {
        lockCountdownTimer?.invalidate()
        lockCountdownTimer = nil
        countdownRemaining = nil
        LockCountdownPanel.hide()
    }

    private func restoreStatusAfterCountdown() {
        if pairedPeripheral?.state == .connected {
            status = currentConnectedStatus()
        } else if bluetoothState == .poweredOn, settings.monitoringEnabled, settings.pairedPeripheralID != nil {
            status = .disconnected
        }
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
        pendingSingleClickTimer?.invalidate()
        pendingSingleClickTimer = nil
        awaitingSecondClick = false
        stopSilenceWrites()
        clearLockCountdown()
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

    private static func isLikelyITag(name: String, services: [CBUUID]) -> Bool {
        let folded = name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        let nameHit = folded.contains("itag")
            || folded.contains("itrace")
            || folded.contains("itracing")
        let serviceHit = services.contains { advertised in
            itagHintServiceUUIDs.contains(advertised)
        }
        return nameHit || serviceHit
    }

    // MARK: - Tag button

    private func handleDiscoveredServices(_ peripheral: CBPeripheral) {
        guard pairedPeripheral?.identifier == peripheral.identifier else { return }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    private func handleDiscoveredCharacteristics(_ peripheral: CBPeripheral, service: CBService) {
        guard pairedPeripheral?.identifier == peripheral.identifier else { return }
        var foundNewSilenceTarget = false
        for characteristic in service.characteristics ?? [] {
            if Self.buttonCharacteristicUUIDs.contains(characteristic.uuid),
               characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if Self.canSilence(characteristic), !alreadyTrackingSilence(characteristic) {
                silenceCharacteristics.append(characteristic)
                foundNewSilenceTarget = true
            }
        }
        if foundNewSilenceTarget {
            silenceTag(on: peripheral)
            scheduleSilenceRetries(for: peripheral)
            startSilenceKeepAlive(for: peripheral)
        }
    }

    /// Link Loss 0x00 = no beep when the connection drops. Immediate Alert / FFE1 0x00 stops an active beep.
    /// Cheap clones often ignore 1803 unless written after a delay, and some reset Alert Level to High on connect.
    private static func canSilence(_ characteristic: CBCharacteristic) -> Bool {
        let writable = characteristic.properties.contains(.write)
            || characteristic.properties.contains(.writeWithoutResponse)
        guard writable else { return false }
        if characteristic.uuid == batteryLevelUUID { return false }
        if characteristic.uuid == alertLevelUUID { return true }
        if buttonCharacteristicUUIDs.contains(characteristic.uuid) { return true }
        if let serviceUUID = characteristic.service?.uuid, alertServiceUUIDs.contains(serviceUUID) {
            return true
        }
        return false
    }

    private func alreadyTrackingSilence(_ characteristic: CBCharacteristic) -> Bool {
        silenceCharacteristics.contains { existing in
            existing.uuid == characteristic.uuid
                && existing.service?.uuid == characteristic.service?.uuid
        }
    }

    private func silenceTag(on peripheral: CBPeripheral? = nil) {
        let target = peripheral ?? pairedPeripheral
        guard let target, target.state == .connected else { return }
        let off = Data([0x00])
        let ordered = silenceCharacteristics.sorted { silencePriority($0) < silencePriority($1) }
        for characteristic in ordered {
            guard let type = Self.writeType(for: characteristic) else { continue }
            target.writeValue(off, for: characteristic, type: type)
        }
    }

    /// Immediate Alert is Write Without Response; Link Loss is Write with response. Prefer the spec when both exist.
    private static func writeType(for characteristic: CBCharacteristic) -> CBCharacteristicWriteType? {
        let canWithResponse = characteristic.properties.contains(.write)
        let canWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)
        guard canWithResponse || canWithoutResponse else { return nil }

        let serviceUUID = characteristic.service?.uuid
        if serviceUUID == linkLossServiceUUID {
            return canWithResponse ? .withResponse : .withoutResponse
        }
        if serviceUUID == immediateAlertServiceUUID {
            return canWithoutResponse ? .withoutResponse : .withResponse
        }
        if canWithoutResponse { return .withoutResponse }
        return .withResponse
    }

    private func silencePriority(_ characteristic: CBCharacteristic) -> Int {
        let service = characteristic.service?.uuid
        if service == Self.linkLossServiceUUID { return 0 }
        if characteristic.uuid == Self.alertLevelUUID { return 1 }
        if service == Self.immediateAlertServiceUUID { return 2 }
        if Self.buttonCharacteristicUUIDs.contains(characteristic.uuid) { return 3 }
        return 4
    }

    private func scheduleSilenceRetries(for peripheral: CBPeripheral) {
        guard silenceRetryTimers.isEmpty else { return }
        let identifier = peripheral.identifier
        for delay in [0.4, 1.5] {
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                Task { @MainActor in
                    guard TagMonitor.shared.pairedPeripheral?.identifier == identifier else { return }
                    TagMonitor.shared.silenceTag()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            silenceRetryTimers.append(timer)
        }
    }

    private func startSilenceKeepAlive(for peripheral: CBPeripheral) {
        guard silenceKeepAliveTimer == nil else { return }
        let identifier = peripheral.identifier
        let timer = Timer(timeInterval: 4.0, repeats: true) { _ in
            Task { @MainActor in
                guard let current = TagMonitor.shared.pairedPeripheral,
                      current.identifier == identifier,
                      current.state == .connected else { return }
                TagMonitor.shared.silenceTag(on: current)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        silenceKeepAliveTimer = timer
    }

    private func stopSilenceWrites() {
        silenceRetryTimers.forEach { $0.invalidate() }
        silenceRetryTimers.removeAll()
        silenceKeepAliveTimer?.invalidate()
        silenceKeepAliveTimer = nil
    }

    private func disconnectQuietly() {
        guard let peripheral = pairedPeripheral else { return }
        silenceTag(on: peripheral)
        let identifier = peripheral.identifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let current = self.pairedPeripheral, current.identifier == identifier {
                self.central.cancelPeripheralConnection(current)
            } else {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func handleButtonNotification(from characteristic: CBCharacteristic) {
        guard settings.clickToLockEnabled || settings.doubleClickToUnlockEnabled else { return }
        guard pairedPeripheral != nil else { return }
        guard Self.buttonCharacteristicUUIDs.contains(characteristic.uuid) else { return }
        // Ignore 0x00 echoes from the No Alert write so silence does not look like a button click.
        if let value = characteristic.value, value.allSatisfy({ $0 == 0 }) { return }

        let now = Date()
        if now < clickDebounceUntil { return }
        clickDebounceUntil = now.addingTimeInterval(0.12)

        if awaitingSecondClick {
            awaitingSecondClick = false
            pendingSingleClickTimer?.invalidate()
            pendingSingleClickTimer = nil
            handleTagDoubleClick()
            return
        }

        awaitingSecondClick = true
        pendingSingleClickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
            Task { @MainActor in
                TagMonitor.shared.finishPendingSingleClick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pendingSingleClickTimer = timer
    }

    private func finishPendingSingleClick() {
        awaitingSecondClick = false
        pendingSingleClickTimer = nil
        handleTagSingleClick()
    }

    private func handleTagSingleClick() {
        guard settings.clickToLockEnabled else { return }
        if countdownRemaining != nil {
            lockNow()
            return
        }
        ScreenLocker.lock()
    }

    private func handleTagDoubleClick() {
        guard settings.doubleClickToUnlockEnabled else { return }
        if countdownRemaining != nil {
            cancelLockCountdown()
            return
        }
        ScreenLocker.unlock()
    }

    /// Button notify characteristics used by generic iTAG / iTracing clones.
    private static let buttonCharacteristicUUIDs: [CBUUID] = [
        CBUUID(string: "FFE1"),
        CBUUID(string: "FFE2"),
        CBUUID(string: "FFF1"),
    ]

    private static let alertLevelUUID = CBUUID(string: "2A06")
    private static let batteryLevelUUID = CBUUID(string: "2A19")
    private static let immediateAlertServiceUUID = CBUUID(string: "1802")
    private static let linkLossServiceUUID = CBUUID(string: "1803")
    private static let ffe0ServiceUUID = CBUUID(string: "FFE0")
    private static let alertServiceUUIDs: Set<CBUUID> = [
        immediateAlertServiceUUID,
        linkLossServiceUUID,
        ffe0ServiceUUID,
    ]

    /// Services this generic iTAG / iTracing keyfinder advertises or exposes.
    private static let itagHintServiceUUIDs: [CBUUID] = [
        CBUUID(string: "1802"),
        CBUUID(string: "1803"),
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFE1"),
        CBUUID(string: "FFF0"),
    ]

    private static let itagServiceUUIDs: [CBUUID] = [
        CBUUID(string: "1802"),
        CBUUID(string: "1803"),
        CBUUID(string: "180F"),
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFE1"),
        CBUUID(string: "FFF0"),
    ]
}
