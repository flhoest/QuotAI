import SwiftUI

struct RingGauge: View {
    let fraction: Double?
    let tone: Tone
    let text: String
    var lineWidth: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            if let fraction {
                let trimmed = max(fraction, 0.005)
                // A soft, tone-colored glow beneath the progress arc reads as depth/vibrancy
                // rather than a flat ring — kept subtle so it never competes with the number.
                Circle()
                    .trim(from: 0, to: trimmed)
                    .stroke(tone.color.opacity(0.5), style: StrokeStyle(lineWidth: lineWidth + 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .blur(radius: 5)
                Circle()
                    .trim(from: 0, to: trimmed)
                    .stroke(tone.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: fraction)
            }
            Text(text)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .padding(lineWidth + 6)
        }
    }
}

/// A tick-mark progress bar (distinct filled segments rather than one smooth fill) — the
/// compact panel's row gauge. Segments light up as the value rises past each one's threshold.
struct SegmentedGauge: View {
    let fraction: Double?
    let tone: Tone
    var segmentCount: Int = 12
    var spacing: CGFloat = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let totalSpacing = spacing * CGFloat(segmentCount - 1)
            let segmentWidth = max((proxy.size.width - totalSpacing) / CGFloat(segmentCount), 1)
            HStack(spacing: spacing) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: index))
                        .frame(width: segmentWidth)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: fraction)
        }
        .frame(height: 7)
    }

    private func color(for index: Int) -> Color {
        guard let fraction else { return Color.primary.opacity(0.1) }
        let segmentThreshold = Double(index + 1) / Double(segmentCount)
        return segmentThreshold <= fraction + 0.0001 ? tone.color : Color.primary.opacity(0.12)
    }
}

/// Status color dot. `size` defaults to the compact list-style usage (Settings sidebar); the
/// panel's own rows pass a larger value to match its bolder, card-style presentation.
struct StatusDot: View {
    let tone: Tone
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(tone.color).frame(width: size, height: size)
    }
}

struct LinearGauge: View {
    let fraction: Double?
    let tone: Tone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let fraction {
                    Capsule().fill(tone.color)
                        .frame(width: max(proxy.size.width * fraction, 3))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: fraction)
                }
            }
        }
        .frame(height: 6)
    }
}
