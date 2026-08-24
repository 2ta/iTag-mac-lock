import AppKit
import SwiftUI

@MainActor
enum PairingPanel {
    private static var panel: NSPanel?
    private static var hosting: NSHostingView<PairingView>?
    private static var lastRefresh = Date.distantPast

    static func show() {
        if panel == nil {
            let hosting = NSHostingView(rootView: PairingView(monitor: TagMonitor.shared))
            let size = NSSize(width: 420, height: 520)
            hosting.frame = NSRect(origin: .zero, size: size)
            Self.hosting = hosting

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "Pair iTAG \(AppVersion.marketing)"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = hosting
            panel.center()
            panel.delegate = PanelCloser.shared
            Self.panel = panel
        }

        refresh(force: true)
        NSApp.setActivationPolicy(.regular)
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func refresh(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastRefresh) > 0.25 else { return }
        lastRefresh = now
        hosting?.rootView = PairingView(monitor: TagMonitor.shared)
    }

    static func hide() {
        panel?.orderOut(nil)
    }
}

private final class PanelCloser: NSObject, NSWindowDelegate {
    static let shared = PanelCloser()

    func windowWillClose(_ notification: Notification) {
        TagMonitor.shared.stopUserScan()
    }
}

struct PairingView: View {
    var monitor: TagMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Nearby Bluetooth devices")
                    .font(.headline)
                Spacer()
                if monitor.isUserScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(instructions)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if monitor.discovered.isEmpty {
                ContentUnavailableView {
                    Label("No tags yet", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Press and hold the iTAG button until it beeps, then keep it next to the Mac.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(monitor.discovered) { tag in
                    Button {
                        monitor.pair(tag)
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(tag.displayName)
                                        .foregroundStyle(.primary)
                                    if tag.isLikelyITag {
                                        Text("iTAG")
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
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }

            HStack {
                Text("\(monitor.discovered.count) device\(monitor.discovered.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop Scanning") {
                    monitor.stopUserScan()
                }
            }
        }
        .padding(16)
        .frame(width: 420, height: 520)
    }

    private var instructions: String {
        "This black iTAG from ECA is a generic iTracing tracker. Insert a CR2032 battery, long-press the center button until it beeps, and disconnect it from your phone first — it only talks to one device. It may show up as iTAG, ITAG, itracing, or Unnamed."
    }
}
