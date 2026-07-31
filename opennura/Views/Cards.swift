import SwiftUI

/// A rounded container used to group controls into tidy cards, with an optional
/// titled header shown as a coloured icon tile plus label.
struct Card<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var title: String?
    var systemImage: String?
    var accent: Color
    @ViewBuilder var content: () -> Content

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        accent: Color = .accentColor,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                HStack(spacing: 10) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(accent.opacity(0.16))
                            )
                    }
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 0)
                }
            }
            content()
        }
        .padding(horizontalSizeClass == .compact ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: horizontalSizeClass == .compact ? 16 : 18, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: horizontalSizeClass == .compact ? 16 : 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// A circular battery indicator.
struct BatteryRing: View {
    let percentage: Int
    let isCharging: Bool

    private var color: Color {
        if isCharging { return .green }
        switch percentage {
        case 21...100: return .green
        case 11...20: return .orange
        default: return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, Double(percentage) / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: percentage)
            VStack(spacing: 0) {
                Text("\(percentage)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Text("%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 76, height: 76)
        .accessibilityElement()
        .accessibilityLabel("Battery")
        .accessibilityValue("\(percentage) percent\(isCharging ? ", charging" : "")")
    }
}
