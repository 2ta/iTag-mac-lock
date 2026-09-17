import SwiftUI

enum AppVersion {
    static let marketing = "1.2"
    static let build = "5"
    static var display: String { "\(marketing) (\(build))" }
    static let githubURL = URL(string: "https://github.com/2ta/iTag-mac-lock")!
    static let githubReleasesURL = URL(string: "https://github.com/2ta/iTag-mac-lock/releases")!
}

@main
struct iTagMacLockApp: App {
    init() {
        _ = TagMonitor.shared
        UpdateChecker.shared.scheduleLaunchCheck()
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
