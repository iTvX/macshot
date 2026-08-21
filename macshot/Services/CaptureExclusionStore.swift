import Cocoa
import ScreenCaptureKit

struct CaptureExcludedApplication: Equatable {
    let bundleIdentifier: String
    let displayName: String

    nonisolated init?(bundleURL: URL) {
        guard let bundle = Bundle(url: bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            return nil
        }

        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        self.bundleIdentifier = bundleIdentifier
        self.displayName = name
    }

    nonisolated init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }
}

/// Stores application bundle identifiers that must be omitted from every capture.
/// ScreenCaptureKit resolves the identifiers to the currently running applications
/// immediately before capture, so exclusions also work after an app relaunches.
enum CaptureExclusionStore {
    nonisolated static let defaultsKey = "captureExcludedApplications"

    nonisolated private static let bundleIdentifierKey = "bundleIdentifier"
    nonisolated private static let displayNameKey = "displayName"

    nonisolated static var applications: [CaptureExcludedApplication] {
        let rows = UserDefaults.standard.array(forKey: defaultsKey) as? [[String: String]] ?? []
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let bundleIdentifier = row[bundleIdentifierKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleIdentifier.isEmpty,
                  seen.insert(bundleIdentifier).inserted else {
                return nil
            }
            let storedDisplayName = row[displayNameKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = storedDisplayName?.isEmpty == false
                ? storedDisplayName ?? bundleIdentifier
                : bundleIdentifier
            return CaptureExcludedApplication(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName)
        }
    }

    nonisolated static var hasConfiguredApplications: Bool {
        !applications.isEmpty
    }

    @discardableResult
    nonisolated static func add(_ application: CaptureExcludedApplication) -> Bool {
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        var current = applications
        guard !current.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) else {
            return false
        }
        current.append(application)
        save(current)
        return true
    }

    nonisolated static func remove(bundleIdentifier: String) {
        save(applications.filter { $0.bundleIdentifier != bundleIdentifier })
    }

    nonisolated static func resolvedApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        let identifiers = Set(applications.map(\.bundleIdentifier))
        guard !identifiers.isEmpty else { return [] }
        return content.applications.filter { identifiers.contains($0.bundleIdentifier) }
    }

    nonisolated static func contentFilter(
        display: SCDisplay,
        content: SCShareableContent,
        excludingWindows: [SCWindow] = []
    ) -> SCContentFilter {
        let exclusionsConfigured = hasConfiguredApplications
        let userExcludedApplications = resolvedApplications(in: content)
        var excludedApplications = userExcludedApplications
        if exclusionsConfigured,
           let dock = content.applications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
           }),
           !excludedApplications.contains(where: { $0.bundleIdentifier == dock.bundleIdentifier }) {
            // Dock owns both the desktop wallpaper and the application icons.
            // Excluding it prevents a selected app's running indicator/icon from
            // revealing that app after its windows have been removed.
            excludedApplications.append(dock)
        }
        let filter: SCContentFilter
        if excludedApplications.isEmpty {
            filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        } else {
            // For an excluding-applications filter, exception windows owned by an
            // included application are also hidden. This preserves macshot's existing
            // ability to omit its overlay/HUD windows while excluding whole apps.
            filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: excludingWindows)
        }

        if #available(macOS 14.2, *), exclusionsConfigured {
            // The active application's menu title is rendered by the system rather
            // than by the excluded process. Remove the system-owned menu bar so it
            // cannot reveal an excluded app's name.
            filter.includeMenuBar = false
        }
        return filter
    }

    nonisolated static func contains(_ application: SCRunningApplication?) -> Bool {
        guard let bundleIdentifier = application?.bundleIdentifier else { return false }
        return contains(bundleIdentifier: bundleIdentifier)
    }

    nonisolated static func contains(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return applications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    nonisolated private static func save(_ applications: [CaptureExcludedApplication]) {
        let sorted = applications.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let rows = sorted.map {
            [bundleIdentifierKey: $0.bundleIdentifier, displayNameKey: $0.displayName]
        }
        UserDefaults.standard.set(rows, forKey: defaultsKey)
    }
}
