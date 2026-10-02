import AppKit
import SwiftUI
import Combine

/// Wires everything together: store, settings, windows. Single instance for the app's lifetime.
@MainActor
final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()

    let settings: AppSettings
    let store: UsageStore
    private(set) lazy var panel = FloatingPanelController(environment: self)
    private var settingsWindow: NSWindow?
    private var detailsWindow: NSWindow?
    private var detailsHosting: NSHostingController<DetailsView>?
    private var detailsFocus = DetailsFocus()
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    private init() {
        let http = URLSessionHTTPClient()
        settings = AppSettings()
        store = UsageStore(
            repository: FileConnectionRepository(),
            secrets: KeychainSecretStore(),
            cache: FileSnapshotCache(),
            connectorProvider: { kind in ConnectorFactory.make(kind: kind, http: http) }
        )
    }

    var isPanelVisible: Bool { settings.panelVisible }

    func start() {
        guard !started else { return }
        started = true
        let isFirstLaunch = FileConnectionRepository().load() == nil
        store.load()
        store.startScheduling()

        settings.panelVisible = settings.showPanelAtLaunch
        if settings.panelVisible { panel.show() }

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.store.tick() } }
            .store(in: &cancellables)

        // A connection added/removed/enabled elsewhere (Settings) changes what both the Details
        // window and the floating panel need to show in full.
        store.$connections
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connections in
                guard let self else { return }
                self.resyncDetailsWindowSize()
                if self.settings.panelVisible {
                    self.panel.resizeToFit(rowCount: connections.filter(\.isEnabled).count, miniMode: self.settings.miniMode)
                }
            }
            .store(in: &cancellables)

        // Switching mini mode resizes immediately, not just on the next connection change.
        settings.$miniMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] miniMode in
                guard let self, self.settings.panelVisible else { return }
                self.panel.resizeToFit(rowCount: self.store.enabledConnections.count, miniMode: miniMode)
            }
            .store(in: &cancellables)

        if isFirstLaunch { showSettings() }
    }

    // MARK: - Actions

    func refreshAll() { store.refreshAll() }

    func togglePanel() {
        if settings.panelVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        settings.panelVisible = true
        panel.show()
    }

    func hidePanel() {
        settings.panelVisible = false
        panel.hide()
    }

    func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(environment: self))
            let window = NSWindow(contentViewController: hosting)
            window.title = "QuotAI Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 940, height: 620))
            // Matches SettingsView's own `.frame(minWidth: 880, …)`: the sidebar plus the
            // Connections pane's internal list+editor need that much to avoid either clipping
            // content or fighting a SwiftUI minimum narrower than what AppKit would allow.
            window.minSize = NSSize(width: 880, height: 560)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("QuotAISettingsWindow")
            window.center()
            settingsWindow = window
        }
        bringToFront(settingsWindow)
    }

    func showDetails(focus id: UUID? = nil) {
        detailsFocus.id = id
        if detailsWindow == nil {
            let hosting = NSHostingController(rootView: DetailsView(environment: self, focus: detailsFocus))
            let window = NSWindow(contentViewController: hosting)
            window.title = "QuotAI Details"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 460, height: 360))
            window.minSize = NSSize(width: 380, height: 220)
            window.isReleasedWhenClosed = false
            // Deliberately no frame-autosave for this window: `setFrameAutosaveName` restores a
            // previously *saved* frame immediately (not just enabling future saves), which was
            // silently overwriting the sizes below with the old fixed 460x620 every single time —
            // fighting the whole point of sizing this window to its actual content.
            window.center()
            detailsWindow = window
            detailsHosting = hosting
        }
        bringToFront(detailsWindow)
        resyncDetailsWindowSize()
    }

    /// Re-measures the Details window's actual SwiftUI content and resizes to match. Called
    /// whenever the window is shown/focused on a different connection, and also whenever the
    /// connection list itself changes (e.g. a new one added from Settings) while the window is
    /// already open on "All Connections" — that case has no `showDetails` call of its own to
    /// hang a resize off, so without this it just silently needed scrolling instead of growing.
    /// Deferred one run-loop tick: SwiftUI only applies the underlying state change (a new focus,
    /// or a new/removed connection) on its next update pass, so measuring synchronously would
    /// still see the previous content.
    private func resyncDetailsWindowSize() {
        guard let window = detailsWindow, let hosting = detailsHosting else { return }
        DispatchQueue.main.async { [weak self, weak window, weak hosting] in
            guard let self, let window, let hosting else { return }
            // Measure at the window's *actual current width*, not an unconstrained ideal width.
            // The previous approach (`hosting.view.fittingSize`, or the `preferredContentSize`
            // KVO backing `.intrinsicContentSize`) both let SwiftUI pick its own width while
            // measuring — which, for a card with wrapping multi-line text (the notes below each
            // OpenAI API metric, longer than Claude's), reported a *shorter* height than what
            // that same text actually needs once wrapped at the narrower width the window is
            // really using. `sizeThatFits` pins the width explicitly, so the wrap the measurement
            // sees matches the wrap that gets rendered.
            //
            // `DetailsView` itself is never measured directly: its `ScrollView` is greedy about
            // whatever height it's proposed (that's what lets it scroll), so `sizeThatFits`
            // measured on it just echoed back the proposed height, never the content's actual
            // height. `DetailsMeasurementView` mirrors the same content in a plain `VStack`
            // instead, whose height genuinely is the sum of its content.
            let width = window.contentRect(forFrameRect: window.frame).width
            let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 2000
            let measurement = NSHostingController(rootView: DetailsMeasurementView(store: self.store, focus: self.detailsFocus))
            let idealHeight = measurement.sizeThatFits(in: NSSize(width: width, height: screenHeight)).height
            self.resizeDetailsWindow(window, toContentHeight: idealHeight)
        }
    }

    /// Resizes the Details window's height to match its SwiftUI content, keeping the current
    /// width and top edge in place. Clamped to the window's own minimum and to the visible
    /// screen height, so a long "all connections" list can't grow the window past the screen.
    private func resizeDetailsWindow(_ window: NSWindow, toContentHeight height: CGFloat) {
        guard height > 0 else { return }
        // A little slack even with a width-pinned measurement: cheap insurance against any
        // remaining sub-pixel rounding between SwiftUI's layout and AppKit's frame. Comfortably
        // over is invisible; even 1-2pt under clips the last line.
        let safetyMargin: CGFloat = 6
        let screenLimit = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? height
        let targetHeight = min(max(height + safetyMargin, window.minSize.height), screenLimit - 40)
        let currentContent = window.contentRect(forFrameRect: window.frame)
        guard abs(currentContent.height - targetHeight) > 0.5 else { return }
        window.setContentSize(NSSize(width: currentContent.width, height: targetHeight))
    }

    private func bringToFront(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func resetPanelPosition() {
        panel.resetPosition()
    }
}

/// Lets the details window scroll to a specific connection.
final class DetailsFocus: ObservableObject {
    @Published var id: UUID?
}
