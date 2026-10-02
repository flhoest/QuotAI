import Foundation
import Combine
import ServiceManagement

/// Non-sensitive app preferences, stored in UserDefaults.
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var keepOnTop: Bool { didSet { defaults.set(keepOnTop, forKey: Keys.keepOnTop) } }
    @Published var showPanelAtLaunch: Bool { didSet { defaults.set(showPanelAtLaunch, forKey: Keys.showPanelAtLaunch) } }
    @Published var panelVisible: Bool { didSet { defaults.set(panelVisible, forKey: Keys.panelVisible) } }
    @Published var showResetTime: Bool { didSet { defaults.set(showResetTime, forKey: Keys.showResetTime) } }
    @Published var showLastUpdate: Bool { didSet { defaults.set(showLastUpdate, forKey: Keys.showLastUpdate) } }
    @Published var showRemaining: Bool { didSet { defaults.set(showRemaining, forKey: Keys.showRemaining) } }
    @Published var panelOpacity: Double { didSet { defaults.set(panelOpacity, forKey: Keys.panelOpacity) } }
    @Published var showPanelBorder: Bool { didSet { defaults.set(showPanelBorder, forKey: Keys.showPanelBorder) } }
    /// Each row collapses to just a status dot, the provider name and its percentage — no gauge
    /// bar, no subtitle.
    @Published var miniMode: Bool { didSet { defaults.set(miniMode, forKey: Keys.miniMode) } }
    /// Above this percentage, a gauge turns orange (warning). Must stay below `criticalThreshold`.
    @Published var warningThreshold: Double { didSet { defaults.set(warningThreshold, forKey: Keys.warningThreshold) } }
    /// Above this percentage, a gauge turns red (critical).
    @Published var criticalThreshold: Double { didSet { defaults.set(criticalThreshold, forKey: Keys.criticalThreshold) } }

    private enum Keys {
        static let keepOnTop = "keepOnTop"
        static let showPanelAtLaunch = "showPanelAtLaunch"
        static let panelVisible = "panelVisible"
        static let showResetTime = "showResetTime"
        static let showLastUpdate = "showLastUpdate"
        static let showRemaining = "showRemaining"
        static let panelOpacity = "panelOpacity"
        static let showPanelBorder = "showPanelBorder"
        static let miniMode = "miniMode"
        static let warningThreshold = "warningThreshold"
        static let criticalThreshold = "criticalThreshold"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.keepOnTop: true,
            Keys.showPanelAtLaunch: true,
            Keys.panelVisible: true,
            Keys.showResetTime: true,
            Keys.showLastUpdate: true,
            Keys.showRemaining: true,
            Keys.panelOpacity: 1.0,
            Keys.showPanelBorder: true,
            Keys.miniMode: false,
            Keys.warningThreshold: 60.0,
            Keys.criticalThreshold: 80.0
        ])
        keepOnTop = defaults.bool(forKey: Keys.keepOnTop)
        showPanelAtLaunch = defaults.bool(forKey: Keys.showPanelAtLaunch)
        panelVisible = defaults.bool(forKey: Keys.panelVisible)
        showResetTime = defaults.bool(forKey: Keys.showResetTime)
        showLastUpdate = defaults.bool(forKey: Keys.showLastUpdate)
        showRemaining = defaults.bool(forKey: Keys.showRemaining)
        panelOpacity = min(max(defaults.double(forKey: Keys.panelOpacity), 0.4), 1.0)
        showPanelBorder = defaults.bool(forKey: Keys.showPanelBorder)
        miniMode = defaults.bool(forKey: Keys.miniMode)
        warningThreshold = min(max(defaults.double(forKey: Keys.warningThreshold), 1), 99)
        criticalThreshold = min(max(defaults.double(forKey: Keys.criticalThreshold), 1), 99)
    }

    // MARK: - Launch at login (user opt-in, via the system's login items)

    var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }
}
