import SwiftUI

/// Plots a profile's hearing signature as a clean left/right curve. This draws
/// the raw values the headphones report for the selected profile; it sends
/// nothing to the device itself.
struct ProfileVisualisationView: View {
    let visualisation: NuraProfileVisualisation
    
    private let leftColor = Color.blue
    private let rightColor = Color.pink
    
    var body: some View {
        VStack(spacing: 12) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .frame(height: 150)
            .accessibilityLabel("Hearing profile shape")
            
            HStack(spacing: 18) {
                legendItem(color: leftColor, label: "Left")
                legendItem(color: rightColor, label: "Right")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
    
    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
    
    // MARK: - Drawing
    
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let left = visualisation.left
        let right = visualisation.right
        guard left.count >= 2, right.count >= 2 else { return }
        
        // Shared vertical scale so the two ears are directly comparable.
        let all = left + right
        let minValue = all.min() ?? 0
        let maxValue = all.max() ?? 1
        let span = max(maxValue - minValue, 0.0001)
        let insetY: CGFloat = 14
        let plotHeight = size.height - insetY * 2
        
        func point(_ value: Double, index: Int, count: Int) -> CGPoint {
            let x = count <= 1 ? 0 : CGFloat(index) / CGFloat(count - 1) * size.width
            let normalized = (value - minValue) / span
            // Higher value plotted higher on screen.
            let y = insetY + plotHeight * (1 - CGFloat(normalized))
            return CGPoint(x: x, y: y)
        }
        
        // Faint midline for reference.
        var midline = Path()
        midline.move(to: CGPoint(x: 0, y: size.height / 2))
        midline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(midline, with: .color(.secondary.opacity(0.15)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        
        drawCurve(right, color: rightColor, in: &context) { point($0, index: $1, count: right.count) }
        drawCurve(left, color: leftColor, in: &context) { point($0, index: $1, count: left.count) }
    }
    
    private func drawCurve(
        _ values: [Double],
        color: Color,
        in context: inout GraphicsContext,
        pointFor: (Double, Int) -> CGPoint
    ) {
        let points = values.enumerated().map { pointFor($1, $0) }
        guard points.count >= 2 else { return }
        let path = smoothPath(points)
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        
        // Small dots at each sampled band.
        for p in points {
            let dot = Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            context.fill(dot, with: .color(color))
        }
    }
    
    /// A gently smoothed path through the points using midpoint quad curves.
    private func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
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
