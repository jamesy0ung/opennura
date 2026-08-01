import SwiftUI

/// The noise-control continuum for every device since NuraLoop (0 = full
/// social/transparency, 6 = full ANC), replacing the Nuraphone's boolean
/// ANC/Passthrough pair.
struct AncLevelSlider: View {
    let current: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 4) {
            if let current {
                Text(levelLabel(current))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: 6) {
                ForEach(0...6, id: \.self) { level in
                    Button {
                        onSelect(level)
                    } label: {
                        Text(levelGlyph(level))
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(level == current ? levelColor(level) : Color.secondary.opacity(0.15))
                            .foregroundStyle(level == current ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("ANC level \(levelLabel(level))")
                    .accessibilityAddTraits(level == current ? [.isSelected] : [])
                }
            }
        }
    }

    private func levelGlyph(_ level: Int) -> String {
        switch level {
        case 0: return "Social"
        case 6: return "ANC"
        default: return "\(level)"
        }
    }

    private func levelLabel(_ level: Int) -> String {
        switch level {
        case 0: return "Full Social"
        case 6: return "Full ANC"
        default: return "Level \(level)"
        }
    }

    private func levelColor(_ level: Int) -> Color {
        switch level {
        case 0, 1: return .orange
        case 5, 6: return .blue
        default: return .gray
        }
    }
}
