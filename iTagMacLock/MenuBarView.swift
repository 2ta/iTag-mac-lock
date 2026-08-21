import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var monitor: TagMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusSection
            rssiSection
            Divider()
            pairingSection
            Divider()
            settingsSection
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: monitor.menuBarSymbol)
                .foregroundStyle(.primary)
            Text("iTag Mac Lock")
                .font(.headline)
            Spacer()
        }
    }

    private var statusSection: some View {
        Text(monitor.statusText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var rssiSection: some View {
        if monitor.rawRSSI != nil || monitor.smoothedRSSI != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let raw = monitor.rawRSSI {
                    labeledRow("RSSI", "\(raw) dBm")
                }
                if let smoothed = monitor.smoothedRSSI {
                    labeledRow("Smoothed", String(format: "%.0f dBm", smoothed))
                }
            }
            .font(.caption.monospacedDigit())
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        if monitor.settings.pairedPeripheralID == nil || monitor.isUserScanning {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(monitor.isUserScanning ? "Nearby devices" : "Pair a tag")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if monitor.isUserScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if monitor.discovered.isEmpty && monitor.isUserScanning {
                    Text("Turn the iTag on (long-press until it beeps) and hold it near the Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !monitor.discovered.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(monitor.discovered) { tag in
                                Button {
                                    monitor.pair(tag)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(tag.name)
                                                    .foregroundStyle(.primary)
                                                if tag.isLikelyITag {
                                                    Text("iTag")
                                                        .font(.caption2.weight(.semibold))
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 1)
                                                        .background(.green.opacity(0.2), in: Capsule())
                                                }
                                            }
                                            Text(tag.id.uuidString)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Text("\(tag.rssi) dBm")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                }

                if monitor.isUserScanning {
                    Button("Stop Scanning") {
                        monitor.stopUserScan()
                    }
                } else {
                    Button("Scan for Devices") {
                        monitor.startUserScan()
                    }
                    .disabled(monitor.status == .bluetoothOff
                              || monitor.status == .unauthorized
                              || monitor.status == .bluetoothUnavailable)
                    .keyboardShortcut("s")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                labeledRow("Tag", monitor.displayName)
                Button("Change Device…") {
                    monitor.startUserScan()
                }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Lock when weaker than")
                    Spacer()
                    Text("\(monitor.settings.rssiThreshold) dBm")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                Slider(
                    value: Binding(
                        get: { Double(monitor.settings.rssiThreshold) },
                        set: { monitor.settings.rssiThreshold = Int($0.rounded()) }
                    ),
                    in: -90...(-50),
                    step: 1
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Debounce")
                    Spacer()
                    Text(debounceLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                Slider(
                    value: Binding(
                        get: { monitor.settings.debounceSeconds },
                        set: { monitor.settings.debounceSeconds = $0 }
                    ),
                    in: 1...8,
                    step: 1
                )
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Monitor tag",
                isOn: Binding(
                    get: { monitor.settings.monitoringEnabled },
                    set: { monitor.setMonitoringEnabled($0) }
                )
            )
            .disabled(monitor.settings.pairedPeripheralID == nil)

            if monitor.settings.pairedPeripheralID != nil {
                Button("Forget Device", role: .destructive) {
                    monitor.forgetDevice()
                }
            }

            Button("Quit iTag Mac Lock") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private var debounceLabel: String {
        let seconds = Int(monitor.settings.debounceSeconds.rounded())
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    private func labeledRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
}

#Preview {
    MenuBarView(monitor: TagMonitor.shared)
}
