import AppKit
import SwiftUI
import Combine

/// Non-activating floating panel: stays above other windows without stealing focus from the
/// app you are working in, and follows you across Spaces.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingPanelController {
    static let frameAutosaveName = "QuotAIFloatingPanel"
    static let defaultSize = NSSize(width: 240, height: 240)
    static let minimumSize = NSSize(width: 170, height: 170)
    /// Mini mode's rows are far shorter than normal ones, so the 170pt floor (sized for the
    /// normal layout) left a big dead gap above and below just one or two mini rows. This floor
    /// only applies while mini mode is active (see `resizeToFit`).
    static let miniMinimumSize = NSSize(width: 170, height: 60)
    static let maximumSize = NSSize(width: 560, height: 560)

    private let environment: AppEnvironment
    private var panel: FloatingPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        ensureOnScreen(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func resetPosition() {
        guard let panel else { return }
        panel.setContentSize(Self.defaultSize)
        position(panel, on: NSScreen.main ?? NSScreen.screens.first)
        panel.saveFrame(usingName: Self.frameAutosaveName)
    }

    /// Resizes the panel's height (its width is left alone) to match its current row count —
    /// growing when a provider is enabled and the panel is too short to show it without
    /// scrolling, and just as much shrinking back when one is disabled and the panel is now
    /// taller than its remaining rows need. The panel is no longer forced square (see
    /// `makePanel`), so this never has to touch width to resize height — which used to enlarge
    /// every row's own text and icons too (width drives `CompactView`'s scale), reading as an
    /// unwanted zoom and, since bigger rows need yet more height, feeding back into wanting an
    /// even bigger panel. Still never overrides a user's own manual resize *unless* the row
    /// count itself just changed — dragging the panel bigger or smaller by hand is untouched
    /// until the next such change.
    ///
    /// `CompactView` sizes itself from whatever frame the window gives it (via `GeometryReader`),
    /// so unlike the Details window there's no SwiftUI-reported "ideal size" to read here; this
    /// uses the same row-height accounting as `CompactView`'s own centering math, with generous
    /// headroom (an earlier, tighter estimate still came up short in practice), and simply
    /// accepts scrolling as the fallback if a future row/font change drifts enough to matter.
    func resizeToFit(rowCount: Int, miniMode: Bool = false) {
        guard let panel else { return }
        // AppKit enforces `contentMinSize` as a hard floor on any `setFrame`, programmatic or
        // not — so without lowering it here first, the panel could never actually get smaller
        // than the normal 170pt floor, no matter how short mini mode's own target height below
        // computes to.
        let minimumSize = miniMode ? Self.miniMinimumSize : Self.minimumSize
        panel.contentMinSize = minimumSize

        let targetContentHeight: CGFloat
        if rowCount >= 2 || (miniMode && rowCount >= 1) {
            // Mini mode's rows are a single short line each (no gauge bar, no subtitle) — much
            // shorter than a normal row, so the panel can shrink down a lot further to fit them.
            // The first, tighter mini-row estimate (26pt row / 6pt margin) measured short in
            // practice — the second mini row ended up visibly clipped rather than just losing a
            // little of its centering slack. Generous headroom here over a perfectly tight fit:
            // a few extra points of empty space reads fine, a clipped row does not.
            let estimatedRowHeight: CGFloat = miniMode ? 34 : 78
            let interRowGap: CGFloat = miniMode ? 4 : 13
            // Mini mode drops the divider + "Updated …"/refresh footer entirely, so there's
            // less fixed chrome around the rows than the normal (footer-showing) layout.
            let chromeAroundRows: CGFloat = miniMode ? 28 : 65
            let margin: CGFloat = miniMode ? 16 : 24
            let neededContentHeight = chromeAroundRows + CGFloat(rowCount) * estimatedRowHeight
                + CGFloat(max(rowCount - 1, 0)) * interRowGap + margin
            targetContentHeight = min(max(neededContentHeight, minimumSize.height), Self.maximumSize.height)
        } else {
            // 0 or 1 row (not mini): back to the original single-provider/empty-state design
            // size, not the bare minimum — that view (a centered ring gauge) was designed
            // around this size.
            targetContentHeight = Self.defaultSize.height
        }

        let currentContent = panel.contentRect(forFrameRect: panel.frame)
        guard abs(targetContentHeight - currentContent.height) > 1 else { return }

        // Resize from the top: the bottom edge and the current width both stay exactly where
        // they are; only the top edge moves, in either direction.
        var newFrame = panel.frame
        newFrame.size.height += targetContentHeight - currentContent.height
        panel.setFrame(newFrame, display: true, animate: true)
        ensureOnScreen(panel)
        panel.saveFrame(usingName: Self.frameAutosaveName)
    }

    // MARK: - Construction

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // The panel now draws its own opaque, rounded, shadowed card in SwiftUI (with a small
        // transparent margin around it for the shadow to bleed into), so the window itself must
        // be non-opaque with no system background — otherwise a square, solid window would show
        // through/behind the rounded card's corners and margin.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // avoid a second, square system shadow behind our own
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // No forced 1:1 aspect ratio: a taller-than-wide rectangle lets the panel grow to fit
        // more providers without also having to widen (see `growToFitIfNeeded`). Still freely
        // resizable by hand in both directions within the same min/max bounds as before.
        panel.contentMinSize = Self.minimumSize
        panel.contentMaxSize = Self.maximumSize
        panel.title = "QuotAI"
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: CompactView(environment: environment))
        hosting.sizingOptions = []
        // Belt-and-suspenders alongside the panel's own isOpaque/backgroundColor: make the
        // hosting view's own layer explicitly transparent too, so the margin SwiftUI leaves for
        // the card's shadow to fade into never shows an opaque backing behind it.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting

        // Position and size are remembered by AppKit under this name.
        let restored = panel.setFrameUsingName(Self.frameAutosaveName)
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !restored { position(panel, on: NSScreen.main ?? NSScreen.screens.first) }

        environment.settings.$keepOnTop
            .receive(on: DispatchQueue.main)
            .sink { [weak panel] keepOnTop in panel?.level = keepOnTop ? .floating : .normal }
            .store(in: &cancellables)
        environment.settings.$panelOpacity
            .receive(on: DispatchQueue.main)
            .sink { [weak panel] opacity in panel?.alphaValue = opacity }
            .store(in: &cancellables)

        // A monitor may be unplugged: bring the panel back onto a visible screen.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let panel = self.panel else { return }
                self.ensureOnScreen(panel)
            }
            .store(in: &cancellables)

        return panel
    }

    // MARK: - Multi-screen handling

    /// If the saved frame is not (sufficiently) visible on any connected screen, move it to the main screen.
    func ensureOnScreen(_ panel: NSPanel) {
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(panel.frame)
            return !overlap.isNull && overlap.width >= 40 && overlap.height >= 40
        }
        if !visible { position(panel, on: NSScreen.main ?? NSScreen.screens.first) }
    }

    private func position(_ panel: NSPanel, on screen: NSScreen?) {
        guard let screen else { return }
        let margin: CGFloat = 20
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin))
    }
}
