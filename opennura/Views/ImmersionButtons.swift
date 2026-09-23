import SwiftUI

struct ImmersionSlider: View {
    let current: Int
    let onSelect: (Int) -> Void
    /// -2...4 on the classic Nuraphone; NuraTrue Pro's range is -3...+3.
    var range: ClosedRange<Int> = -2...4
    
    var body: some View {
        VStack(spacing: 4) {
            Text(levelLabel(current))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 6) {
                ForEach(Array(range), id: \.self) { level in
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
                    .accessibilityLabel("Immersion \(levelLabel(level))")
                    .accessibilityAddTraits(level == current ? [.isSelected] : [])
                }
            }
        }
    }
    
    private func levelLabel(_ level: Int) -> String {
        if range == -2...4 {
            switch level {
            case 4: return "Maximum"
            case 3: return "High"
            case 2: return "Medium-High"
            case 1: return "Medium"
            case 0: return "Neutral"
            case -1: return "Low"
            case -2: return "Minimum"
            default: break
            }
        }
        if level == range.upperBound { return "Maximum" }
        if level == range.lowerBound { return "Minimum" }
        if level == 0 { return "Neutral" }
        return level > 0 ? "+\(level)" : "\(level)"
    }
    
    private func levelColor(_ level: Int) -> Color {
        if level == 0 { return .gray }
        if level > 0 { return level >= range.upperBound - 1 ? .purple : .blue }
        return .orange
    }
}
