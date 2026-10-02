import SwiftUI
import AppKit

/// The small square view that lives in the floating panel: a single opaque, rounded, shadowed
/// card (rather than a translucent system-material sheet) so it reads as a self-contained
/// dashboard on top of whatever's behind it, matching the reference design.
struct CompactView: View {
    @ObservedObject var environment: AppEnvironment
    @ObservedObject private var store: UsageStore
    @ObservedObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(environment: AppEnvironment) {
        self.environment = environment
        self.store = environment.store
        self.settings = environment.settings
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { timeline in
            content(now: timeline.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu {
            Button("Refresh Now") { environment.refreshAll() }
            Button("Details…") { environment.showDetails() }
            Button("Settings…") { environment.showSettings() }
            Divider()
            Toggle("Mini Mode", isOn: $settings.miniMode)
            Divider()
            Button("Hide Panel") { environment.hidePanel() }
            Divider()
            Button("Quit QuotAI") { NSApp.terminate(nil) }
        }
    }

    private func rows(now: Date) -> [RowModel] {
        store.enabledConnections.map { connection in
            RowModel.make(connection: connection,
                          runtime: store.runtime(for: connection.id),
                          showReset: settings.showResetTime,
                          showRemaining: settings.showRemaining,
                          now: now,
                          warningThreshold: settings.warningThreshold,
                          criticalThreshold: settings.criticalThreshold)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        GeometryReader { proxy in
            let rows = rows(now: now)
            let rawScale = max(0.8, min(proxy.size.width / 240, 2.2))
            // Capped at 1.0 once there's more than one row: growing the (square) panel to fit
            // an extra row also grows its width, and width is what this scale is based on — left
            // uncapped, that enlarged *every row's own text and icons* too, which both looked
            // like an unwanted zoom and, since bigger rows need yet more height, fed back into
            // wanting an even bigger panel. A single provider's ring view still scales up with
            // a bigger panel — there, more room really does mean "show it bigger" — so the cap
            // only applies to the list.
            let scale = (rows.count > 1 || settings.miniMode) ? min(rawScale, 1.0) : rawScale
            let cardRadius = 20 * scale
            ZStack {
                // The rounded corners and shadow live on the background fill alone, not on a
                // clip applied to the content. `ViewThatFits`'s fits-or-not estimate has proven
                // imprecise in practice (borderline cases have twice slipped through as "fits"
                // when the actual laid-out content was a hair taller); a clipped card would
                // silently amputate real data — a row's reset time simply vanishing — in exactly
                // that situation. Worst case now, content very slightly overruns the rounded
                // corner instead: a cosmetic nit, never a missing number.
                Color("PanelBackground")
                    .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 6, x: 0, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                            // A mid-gray edge reads fine against a light background but all but
                            // disappears against a dark one, so the border flips to light-gray in
                            // dark mode instead, matching the shadow's own light/dark split above.
                            .strokeBorder(settings.showPanelBorder
                                          ? (colorScheme == .dark ? Color.white.opacity(0.22) : Color.gray.opacity(0.35))
                                          : Color.clear, lineWidth: 1)
                    )
                VStack(spacing: 0) {
                    Group {
                        if rows.isEmpty {
                            emptyState(scale: scale)
                        } else if settings.miniMode {
                            // Mini mode always uses the list layout, even for a single provider:
                            // the whole point is the compact dot+name+percentage line, not the
                            // big centered ring `SingleProviderView` draws. No divider/footer
                            // chrome to subtract here either, since mini mode hides both below.
                            let chromeAroundRows = 14 * scale * 2
                            let rowsMinHeight = max(proxy.size.height - chromeAroundRows, 0)
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    VStack(spacing: 2 * scale) {
                                        ForEach(rows) { row in
                                            MiniRowView(row: row, scale: scale)
                                                .onTapGesture { environment.showDetails(focus: row.id) }
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: rowsMinHeight)
                            }
                        } else if rows.count == 1, let row = rows.first {
                            SingleProviderView(row: row, scale: scale)
                                .onTapGesture { environment.showDetails(focus: row.id) }
                        } else {
                            // A single, always-present ScrollView, deliberately simpler than what
                            // was here before (a `ViewThatFits` choosing between a flexible
                            // "spread to fill" layout and a scrollable one, with per-row capped
                            // spacers). That version broke three different ways in practice — an
                            // imprecise fits-or-not estimate, an invisible margin, and a row's own
                            // subtitle rendering with no reserved height despite correct data —
                            // all traceable to that same layered complexity. A plain ScrollView
                            // handles both "rows fit" (content just centers, nothing scrolls) and
                            // "rows overflow" (it scrolls) through one well-worn SwiftUI idiom,
                            // with every row keeping its own natural, unsqueezed size.
                            // Only affects centering, never correctness: if this estimate of the
                            // chrome around the rows (padding, divider, footer) is a little off,
                            // the ScrollView just centers less than perfectly — it can no longer
                            // hide a row's own content the way the old fits-or-not test could.
                            let chromeAroundRows = 14 * scale * 2 + 1 + 16 * scale + 20 * scale
                            let rowsMinHeight = max(proxy.size.height - chromeAroundRows, 0)
                            ScrollView(.vertical, showsIndicators: false) {
                                VStack(spacing: 0) {
                                    Spacer(minLength: 0)
                                    VStack(spacing: 12 * scale) {
                                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                            if index > 0 { divider(scale: scale) }
                                            ProviderRowView(row: row, scale: scale)
                                                .onTapGesture { environment.showDetails(focus: row.id) }
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: rowsMinHeight)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                    // Mini mode's whole point is just the rows — no "Updated …" text, no refresh
                    // button taking up a line underneath. Refresh still happens automatically on
                    // its usual schedule; it's just not shown here.
                    if !settings.miniMode {
                        divider(scale: scale).padding(.vertical, 8 * scale)
                        footer(scale: scale, now: now)
                    }
                }
                // Drag-zone clearance now scales with the panel instead of a fixed 22pt: on a
                // small panel that flat cost was eating enough height to tip rows that used to
                // comfortably fit into the scrollable fallback — which, with no scroll indicator,
                // looked like the second row's gauge and subtitle had simply vanished.
                .padding(.top, 14 * scale)
                .padding([.horizontal, .bottom], 14 * scale)
                // Deliberately not clipped to the rounded shape (see the comment above the
                // background fill): the inset from this padding already keeps content clear of
                // the corners in the normal case, without risking silently cutting off real text
                // if a size estimate is ever a hair off.
            }
            // Drag anywhere on the card, rows included — not just the chrome between them. A
            // `simultaneousGesture` on the whole stack, rather than `.gesture` on the background
            // layer alone, is what makes that work: it recognizes alongside a row's own tap
            // gesture instead of competing with it for the gesture slot, so a stationary click
            // still opens Details while an actual drag still moves the window, no matter which
            // one you start on.
            .windowDraggableBackground()
            // No outer margin: an invisible-but-still-part-of-the-window strip around the card
            // meant the panel couldn't actually be dragged flush to a screen edge — you'd hit the
            // window's real (invisible) boundary before the visible card got there. The window is
            // the card now; the shadow just softens right at its own edge instead of bleeding
            // beyond it, which reads fine at this shadow's now-modest size.
        }
    }

    /// A thin rule between rows and above the footer.
    private func divider(scale: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    private func emptyState(scale: CGFloat) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.system(size: 30 * scale))
                .foregroundStyle(.secondary)
            Text("No provider enabled")
                .font(.system(size: 13 * scale, weight: .medium))
            Button("Open Settings") { environment.showSettings() }
                .controlSize(.small)
        }
        .frame(maxHeight: .infinity)
    }

    private func footer(scale: CGFloat, now: Date) -> some View {
        let anyLoading = store.enabledConnections.contains {
            if case .loading = store.runtime(for: $0.id).status { return true }
            return false
        }
        return HStack(spacing: 6) {
            if settings.showLastUpdate {
                if let last = store.lastRefreshCompleted {
                    Text("Updated \(Formatters.clock(last))")
                } else {
                    Text("Not updated yet")
                }
            }
            Spacer(minLength: 0)
            Button {
                environment.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .foregroundStyle(Color("AccentIndigo"))
                    .rotationEffect(.degrees(anyLoading && !reduceMotion ? 360 : 0))
                    .animation(anyLoading && !reduceMotion ? .linear(duration: 0.9).repeatForever(autoreverses: false) : nil, value: anyLoading)
            }
            .buttonStyle(HoverIconButtonStyle())
            .help("Refresh now")
            .accessibilityLabel("Refresh now")
        }
        .font(.system(size: 10 * scale))
        .foregroundStyle(.secondary)
    }
}

/// A small, round hover highlight for icon-only buttons — the kind of tactile feedback a
/// premium native control gives even outside its default focus ring, plus a pointing-hand
/// cursor so a purely visual "this is clickable" cue doesn't rely on color alone.
struct HoverIconButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(5)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (isHovering ? 0.09 : 0))))
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

/// A provider's identity badge for the panel — the vendor's own logo when one is bundled, tinted
/// with that vendor's accent color; falls back to the descriptor's SF Symbol otherwise. Reuses
/// Settings' own badge component so a provider reads the same way everywhere in the app.
struct ProviderBadge: View {
    let row: RowModel
    let size: CGFloat

    var body: some View {
        if let logo = row.kind.brandLogo {
            SettingsIconBadge(image: logo, tint: row.kind.accentColor, size: size)
        } else {
            SettingsIconBadge(systemImage: row.symbol, tint: row.kind.accentColor, size: size)
        }
    }
}

struct ProviderRowView: View {
    let row: RowModel
    let scale: CGFloat
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * scale) {
            HStack(spacing: 8 * scale) {
                ProviderBadge(row: row, size: 18 * scale)
                Text(row.title)
                    .font(.system(size: 15 * scale, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(row.valueText)
                    .font(.system(size: 16 * scale, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(row.tone.color)
            }
            SegmentedGauge(fraction: row.fraction, tone: row.tone)
                .opacity(row.fraction == nil ? 0.5 : 1)
            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8 * scale)
        .background(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
            .fill(Color.primary.opacity(isHovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.valueText), \(row.statusText)")
        .accessibilityHint("Opens details")
    }
}

/// Mini mode's row: just the status dot, the provider name and its percentage — no gauge bar,
/// no subtitle. For when the panel's only job is a quick glance, not the detail.
struct MiniRowView: View {
    let row: RowModel
    let scale: CGFloat
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6 * scale) {
            ProviderBadge(row: row, size: 13 * scale)
            Text(row.title)
                .font(.system(size: 12.5 * scale, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(row.valueText)
                .font(.system(size: 12.5 * scale, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(row.tone.color)
        }
        .padding(.vertical, 4 * scale)
        .padding(.horizontal, 6 * scale)
        .background(RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
            .fill(Color.primary.opacity(isHovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.valueText), \(row.statusText)")
        .accessibilityHint("Opens details")
    }
}

struct SingleProviderView: View {
    let row: RowModel
    let scale: CGFloat

    var body: some View {
        VStack(spacing: 6 * scale) {
            Text(row.title)
                .font(.system(size: 14 * scale, weight: .bold, design: .rounded))
                .lineLimit(1)
            RingGauge(fraction: row.fraction, tone: row.tone, text: row.valueText, lineWidth: 9 * scale)
                .frame(maxWidth: 130 * scale, maxHeight: 130 * scale)
                .frame(maxHeight: .infinity)
            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(.system(size: 10.5 * scale))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(row.valueText), \(row.statusText)")
    }
}

extension View {
    /// Lets a drag starting on this view move the panel, the way the whole card used to via
    /// `NSPanel.isMovableByWindowBackground`. As of macOS 27, AppKit only starts that drag when
    /// the hit view's `mouseDownCanMoveWindow` returns true, and `NSHostingView` — what SwiftUI
    /// content is actually drawn into — returns false, so a window whose entire content is
    /// SwiftUI silently stopped being draggable by its background. `WindowDragGesture` (macOS
    /// 15+) moves the window directly from SwiftUI's own gesture system instead, sidestepping
    /// that AppKit check entirely. `isMovableByWindowBackground` is left set on the panel for
    /// macOS versions before 15, where it still works as before.
    ///
    /// `simultaneousGesture`, not `gesture`: this is applied to the whole card, rows included,
    /// so it has to coexist with each row's own `onTapGesture` (opens Details) rather than
    /// winning the single gesture slot and silently swallowing every click. The two don't
    /// actually conflict — a stationary click still recognizes as a tap, real pointer movement
    /// still recognizes as a drag — `simultaneousGesture` just lets both recognizers listen
    /// instead of only the one `gesture` would have picked.
    @ViewBuilder
    func windowDraggableBackground() -> some View {
        if #available(macOS 15.0, *) {
            self.simultaneousGesture(WindowDragGesture())
        } else {
            self
        }
    }
}
