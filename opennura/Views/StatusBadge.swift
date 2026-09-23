import SwiftUI

struct StatusBadge: View {
    let phase: ConnectionPhase
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.footnote.weight(.semibold))
            Text(phase.label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(iconColor.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(iconColor.opacity(0.25), lineWidth: 0.5))
    }
    
    private var iconName: String {
        switch phase {
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "headphones"
        default: return "antenna.radiowaves.left.and.right"
        }
    }
    
    private var iconColor: Color {
        switch phase {
        case .ready: return .green
        case .failed: return .red
        case .idle: return .secondary
        default: return .orange
        }
    }
}
