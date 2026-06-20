import SwiftUI

struct ImmersionSlider: View {
    let current: Int
    let onSelect: (Int) -> Void
    private let range = -2...4

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(levelLabel(current))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: 6) {
                ForEach(-2...4, id: \.self) { level in
                    Button {
                        onSelect(level)
                    } label: {
                        Text(level >= 0 ? "+\(level)" : "\(level)")
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(level == current ? levelColor(level) : Color.secondary.opacity(0.15))
                            .foregroundStyle(level == current ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func levelLabel(_ level: Int) -> String {
        switch level {
        case 4: return "Maximum"
        case 3: return "High"
        case 2: return "Medium-High"
        case 1: return "Medium"
        case 0: return "Neutral"
        case -1: return "Low"
        case -2: return "Minimum"
        default: return ""
        }
    }

    private func levelColor(_ level: Int) -> Color {
        switch level {
        case 3...4: return .purple
        case 1...2: return .blue
        case 0: return .gray
        default: return .orange
        }
    }
}
