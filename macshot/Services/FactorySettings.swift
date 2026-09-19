import Foundation
import Carbon

/// Reviewed, portable settings for new installations of this fork. Unlisted settings
/// retain the app's existing built-in defaults. Never populate this from a raw plist:
/// paths, credentials, device IDs, capture history and framework state are not defaults.
enum FactorySettings {
    static let installationKey = "factorySettingsVersion"
    static let pendingLoginItemKey = "factorySettingsNeedsLoginRegistration"

    static func hotkey(for binding: HotkeyManager.Binding) -> (keyCode: UInt32, modifiers: UInt32) {
        let commandShift = UInt32(cmdKey | shiftKey)
        if binding.kind == .alternative {
            return binding.slot == .quickCapture ? (UInt32(kVK_ANSI_4), commandShift) : (0, 0)
        }
        switch binding.slot {
        case .captureArea: return (UInt32(kVK_ANSI_5), commandShift)
        case .captureOCR: return (UInt32(kVK_ANSI_3), commandShift)
        case .quickCapture: return (UInt32(kVK_ANSI_S), UInt32(optionKey))
        case .captureFullScreen, .recordArea: return (0, 0)
        default: return (binding.slot.defaultKeyCode, binding.slot.defaultModifiers)
        }
    }

    static var preferences: [String: Any] {
        var values: [String: Any] = [
            "SUEnableAutomaticChecks": true,
            "captureExcludedApplications": [["bundleIdentifier": "com.itvx.lotus", "displayName": "Lotus"]],
            "disableSelectionOutsideShadow": true,
            "enabledActions": Array(1001...1013),
            "enabledTools": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16, 17, 18],
            "filenameTemplate": "Screenshot {date} at {time}",
            "lastUsedTool": 9, // Pixelate; the current drawing color is the built-in system red.
            "launchAtLogin": true,
            "ocrAction": 2,
            "playCopySound": false,
            "windowSnapEnabled": true,
        ]
        for binding in HotkeyManager.Binding.all {
            let shortcut = hotkey(for: binding)
            values[binding.keyCodeKey] = Int(shortcut.keyCode)
            values[binding.modifiersKey] = Int(shortcut.modifiers)
            values[binding.disabledKey] = shortcut == (0, 0)
        }
        return values
    }

    /// Run before any settings consumers are initialized. Seed only a fresh app domain;
    /// existing users retain both explicit settings and the old implicit defaults.
    /// The marker is local bookkeeping and must not travel with settings exports.
    @discardableResult
    static func installIfNeeded(defaults: UserDefaults = .standard,
                                domainName: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let domainName = domainName else { return false }
        var domain = defaults.persistentDomain(forName: domainName) ?? [:]
        guard domain[installationKey] == nil else { return false }
        let isExistingInstallation = domain.keys.contains {
            $0 == "NSViewUsesAutomaticLayerBackingStores" || $0.hasPrefix("SU")
                || SettingsPortability.isPortable($0) || SettingsPortability.excludedKeys.contains($0)
        }
        if !isExistingInstallation {
            domain.merge(preferences) { existing, _ in existing }
            // Survive a first-launch move from a downloaded/translocated app to /Applications.
            domain[pendingLoginItemKey] = true
        }
        domain[installationKey] = 1
        defaults.setPersistentDomain(domain, forName: domainName)
        return !isExistingInstallation
    }
}
