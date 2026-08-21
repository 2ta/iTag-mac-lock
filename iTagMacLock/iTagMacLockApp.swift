import SwiftUI

@main
struct iTagMacLockApp: App {
    init() {
        _ = TagMonitor.shared
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(monitor: TagMonitor.shared)
        } label: {
            MenuBarIcon(monitor: TagMonitor.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    var monitor: TagMonitor

    var body: some View {
        Image(systemName: monitor.menuBarSymbol)
            .accessibilityLabel("iTag Mac Lock")
    }
}
