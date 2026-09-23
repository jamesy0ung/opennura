import SwiftUI

/// Overlays each populated profile's hearing signature so they can be compared.
/// Reads the stored values per profile (no profile switching, nothing played).
struct ProfileCompareView: View {
    @ObservedObject var device: NuraDeviceManager
    @Environment(\.dismiss) private var dismiss
    
    private let palette: [Color] = [.purple, .teal, .orange]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Card(accent: .indigo) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Each profile's hearing signature, overlaid. These are stored values read from the headphones; nothing is played. The horizontal axis is the shape across the hearing range, not calibrated frequencies.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button {
                                device.refreshAllVisualisations()
                            } label: {
                                Label("Reload all", systemImage: "arrow.down.circle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    
                    if populatedLoaded.isEmpty {
                        Card {
                            Text("Tap Reload all to fetch each profile's shape.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        comparisonCard
                    }
                }
                .padding(16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Compare profiles")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear { device.refreshAllVisualisations() }
        }
#if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
#endif
    }
    
    private var comparisonCard: some View {
        Card("Comparison", systemImage: "waveform.path.ecg", accent: .indigo) {
            VStack(spacing: 14) {
                Canvas { ctx, size in draw(populatedLoaded, in: &ctx, size: size) }
                    .frame(height: 200)
                legend(populatedLoaded)
            }
        }
    }
    
    private var populatedLoaded: [(id: Int, vis: NuraProfileVisualisation)] {
        [0, 1, 2].compactMap { id in
            guard device.isProfilePopulated(id),
                  let v = device.state.visualisations[id], !v.isEmpty
                    else { return nil }
            return (id, v)
        }
    }
    
    private func color(for id: Int) -> Color { palette[id % palette.count] }
    
    private func legend(_ loaded: [(id: Int, vis: NuraProfileVisualisation)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(loaded, id: \.id) { item in
                HStack(spacing: 8) {
                    Circle().fill(color(for: item.id)).frame(width: 9, height: 9)
                    Text(device.displayProfileName(item.id)).font(.caption)
                    if let detail = device.profileNameDetail(item.id) {
                        Text("(\(detail))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func draw(_ loaded: [(id: Int, vis: NuraProfileVisualisation)],
                      in ctx: inout GraphicsContext, size: CGSize) {
        let all = loaded.flatMap { $0.vis.combined }
        guard !all.isEmpty else { return }
        let minV = all.min() ?? 0
        let maxV = all.max() ?? 1
        let span = max(maxV - minV, 0.0001)
        let insetY: CGFloat = 16
        let plotH = size.height - insetY * 2
        
        var midline = Path()
        midline.move(to: CGPoint(x: 0, y: size.height / 2))
        midline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        ctx.stroke(midline, with: .color(.secondary.opacity(0.15)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        
        for item in loaded {
            let values = item.vis.combined
            guard values.count >= 2 else { continue }
            let pts = values.enumerated().map { (i, v) -> CGPoint in
                let x = CGFloat(i) / CGFloat(values.count - 1) * size.width
                let n = (v - minV) / span
                return CGPoint(x: x, y: insetY + plotH * (1 - CGFloat(n)))
            }
            ctx.stroke(smoothPath(pts), with: .color(color(for: item.id)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            for p in pts {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                         with: .color(color(for: item.id)))
            }
        }
    }
    
    private func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 2 { path.addLine(to: points[1]); return path }
        for i in 1..<points.count {
            let prev = points[i - 1]
            let curr = points[i]
            let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
