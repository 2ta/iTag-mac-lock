import AppKit
import Foundation

struct GitHubRelease: Decodable, Equatable {
    let tagName: String
    let name: String?
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case draft
        case prerelease
    }

    var versionString: String {
        var value = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value = String(value.dropFirst())
        }
        return value
    }
}

enum UpdateCheckResult: Equatable {
    case upToDate(latest: String)
    case updateAvailable(release: GitHubRelease)
    case noReleases
    case failed(String)
}

@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let releasesURL = URL(string: "https://api.github.com/repos/2ta/iTag-mac-lock/releases/latest")!
    static let releasesPageURL = AppVersion.githubReleasesURL
    private static let week: TimeInterval = 7 * 24 * 60 * 60

    private(set) var isChecking = false
    private(set) var lastResult: UpdateCheckResult?
    private(set) var availableRelease: GitHubRelease?

    private let settings = AppSettings.shared

    private init() {}

    /// Silent weekly check on launch when the user opted in.
    func scheduleLaunchCheck() {
        guard settings.weeklyUpdateCheckEnabled else { return }
        guard shouldRunWeeklyCheck else { return }
        Task {
            _ = await checkForUpdates(userInitiated: false)
        }
    }

    var shouldRunWeeklyCheck: Bool {
        guard let last = settings.lastUpdateCheckDate else { return true }
        return Date().timeIntervalSince(last) >= Self.week
    }

    var statusText: String {
        if isChecking {
            return "Checking GitHub for updates…"
        }
        if let release = availableRelease {
            return "Update \(release.versionString) is available."
        }
        switch lastResult {
        case .upToDate(let latest):
            return "You're on the latest release (\(latest))."
        case .noReleases:
            return "No GitHub releases published yet."
        case .failed(let message):
            return message
        case .updateAvailable(let release):
            return "Update \(release.versionString) is available."
        case nil:
            if let last = settings.lastUpdateCheckDate {
                return "Last checked \(Self.relativeDate.localizedString(for: last, relativeTo: Date()))."
            }
            return "Checks GitHub Releases for a newer version."
        }
    }

    @discardableResult
    func checkForUpdates(userInitiated: Bool) async -> UpdateCheckResult {
        guard !isChecking else {
            return lastResult ?? .failed("Already checking.")
        }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("iTagMacLock/\(AppVersion.marketing)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)
            settings.lastUpdateCheckDate = Date()

            if let http = response as? HTTPURLResponse {
                if http.statusCode == 404 {
                    let result = UpdateCheckResult.noReleases
                    lastResult = result
                    availableRelease = nil
                    return result
                }
                guard (200...299).contains(http.statusCode) else {
                    let result = UpdateCheckResult.failed("GitHub returned status \(http.statusCode).")
                    lastResult = result
                    return result
                }
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            if release.draft || release.prerelease {
                let result = UpdateCheckResult.upToDate(latest: AppVersion.marketing)
                lastResult = result
                availableRelease = nil
                return result
            }

            if Self.isVersion(release.versionString, newerThan: AppVersion.marketing) {
                let result = UpdateCheckResult.updateAvailable(release: release)
                lastResult = result
                availableRelease = release
                if userInitiated {
                    presentUpdateAlert(for: release)
                }
                return result
            }

            let result = UpdateCheckResult.upToDate(latest: release.versionString)
            lastResult = result
            availableRelease = nil
            if userInitiated {
                presentUpToDateAlert(latest: release.versionString)
            }
            return result
        } catch {
            let message: String
            if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
                message = "No internet connection."
            } else {
                message = "Could not check for updates."
            }
            let result = UpdateCheckResult.failed(message)
            lastResult = result
            if userInitiated {
                presentErrorAlert(message)
            }
            return result
        }
    }

    func openAvailableRelease() {
        let url = availableRelease.flatMap { URL(string: $0.htmlURL) } ?? Self.releasesPageURL
        NSWorkspace.shared.open(url)
    }

    private func presentUpdateAlert(for release: GitHubRelease) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Version \(release.versionString) is on GitHub. You are running \(AppVersion.display)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Release")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: release.htmlURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func presentUpToDateAlert(latest: String) {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "The latest GitHub release is \(latest). This Mac is running \(AppVersion.display)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Compare dotted numeric versions, e.g. "1.2" > "1.1.0".
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = versionParts(candidate)
        let right = versionParts(current)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func versionParts(_ value: String) -> [Int] {
        var cleaned = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") {
            cleaned = String(cleaned.dropFirst())
        }
        return cleaned.split(separator: ".").map { segment in
            Int(segment.prefix(while: \.isNumber)) ?? 0
        }
    }

    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
