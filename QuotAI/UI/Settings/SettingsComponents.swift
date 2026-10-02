import SwiftUI

/// A small colored rounded-square icon, the same visual language macOS's own System Settings
/// uses for each pane — used here as a section header icon throughout Settings, so related
/// controls read as one grouped "card" rather than a bare, flat list of toggles. Takes either a
/// plain SF Symbol or an arbitrary `Image` (a provider's official brand mark, template-rendered
/// so it tints white like a symbol would).
struct SettingsIconBadge: View {
    private let image: Image
    var tint: Color = .accentColor
    var size: CGFloat = 26

    init(systemImage: String, tint: Color = .accentColor, size: CGFloat = 26) {
        self.image = Image(systemName: systemImage)
        self.tint = tint
        self.size = size
    }

    init(image: Image, tint: Color = .accentColor, size: CGFloat = 26) {
        self.image = image
        self.tint = tint
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.52, height: size * 0.52)
                    .foregroundStyle(.white)
            )
    }
}

/// One titled, icon-badged card of related settings — the basic building block of the redesigned
/// Settings window, replacing the plain system `Form`/`Section` look with grouped, lightly
/// tinted panels that give the window real visual hierarchy. `badgeImage`, when given, overrides
/// `icon` — a provider's official brand mark in place of a generic SF Symbol.
struct SettingsCard<Content: View>: View {
    let title: String
    var icon: String = "circle"
    var badgeImage: Image?
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let badgeImage {
                    SettingsIconBadge(image: badgeImage, tint: tint)
                } else {
                    SettingsIconBadge(systemImage: icon, tint: tint)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        }
    }
}

/// A row inside a `SettingsCard` pairing a control with a one-line caption underneath — for
/// controls (sliders, pickers) whose purpose isn't self-evident from their label alone.
struct SettingsCaptionedRow<Content: View>: View {
    let caption: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One brand color per provider, used to tint its icon badge consistently everywhere it shows
/// up — the Connections sidebar, the editor's own header card, anywhere else it's identified at
/// a glance.
extension ProviderKind {
    var accentColor: Color {
        switch self {
        case .claudeCode: return Color("AccentIndigo")
        case .anthropicAPI: return .purple
        case .openAIAPI: return .green
        case .codex: return .orange
        }
    }

    /// The vendor's own mark (bundled as a template-rendered SVG asset, from Simple Icons) in
    /// place of a generic SF Symbol — both Claude connections use Claude's own logo (not
    /// Anthropic the company's), both Codex and the OpenAI API connection are OpenAI's.
    var brandLogo: Image? {
        switch self {
        case .claudeCode, .anthropicAPI: return Image("ClaudeLogo")
        case .openAIAPI, .codex: return Image("OpenAILogo")
        }
    }
}

/// A small, round hover highlight for icon-only buttons, matching the panel's own
/// `HoverIconButtonStyle` — used here for the Connections sidebar's add/remove buttons so the
/// two surfaces feel like the same app.
struct SettingsIconButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(5)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (isHovering ? 0.09 : 0))))
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
    }
}
