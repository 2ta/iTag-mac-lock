import AppKit
import SwiftUI

@MainActor
enum LockCountdownPanel {
    private static var panel: NSPanel?
    private static var hosting: NSHostingView<LockCountdownView>?

    static func show() {
        if panel == nil {
            let hosting = NSHostingView(rootView: LockCountdownView(monitor: TagMonitor.shared))
            let size = NSSize(width: 300, height: 210)
            hosting.frame = NSRect(origin: .zero, size: size)
            Self.hosting = hosting

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "iTag Mac Lock"
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = hosting
            panel.center()
            Self.panel = panel
        }

        refresh()
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func refresh() {
        hosting?.rootView = LockCountdownView(monitor: TagMonitor.shared)
    }

    static func hide() {
        panel?.orderOut(nil)
    }
}

struct LockCountdownView: View {
    var monitor: TagMonitor

    var body: some View {
        VStack(spacing: 14) {
            Text("Mac will lock")
                .font(.headline)

            Text("\(monitor.countdownRemaining ?? 0)")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)

            Text("seconds")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Don't Lock") {
                    monitor.cancelLockCountdown()
                }
                .keyboardShortcut(.cancelAction)

                Button("Lock Now") {
                    monitor.lockNow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300, height: 210)
    }
}
