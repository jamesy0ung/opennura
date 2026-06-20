import SwiftUI

struct StatusBadge: View {
    let phase: ConnectionPhase

    var body: some View {
        Label {
            Text(phase.label)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
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

extension ConnectionPhase {
    var isConnecting: Bool {
        switch self {
        case .scanning, .connecting, .discovering, .handshaking: return true
        default: return false
        }
    }
}
