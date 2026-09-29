import SwiftUI
import PRMasterCore

/// Every status glyph, drawn on one 16-point grid so they share a line weight.
///
/// Filled with the foreground style, so a glyph takes its row's tint and goes
/// grey in monochrome exactly as an SF Symbol would.
struct StatusGlyphView: View {
    let glyph: StatusGlyph

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 16
            context.scaleBy(x: scale, y: scale)
            Pen(context: context).draw(glyph)
        }
    }
}

private struct Pen {
    let context: GraphicsContext

    func stroke(_ path: Path, width: CGFloat = 1.4) {
        context.stroke(path, with: .foreground,
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    func fill(_ path: Path) { context.fill(path, with: .foreground) }

    func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat = 0.95) {
        fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)))
    }

    func line(_ points: CGPoint...) { stroke(Path { $0.addLines(points) }) }

    func ring() { stroke(Path(ellipseIn: CGRect(x: 1.7, y: 1.7, width: 12.6, height: 12.6))) }

    func bang(top: CGFloat, bottom: CGFloat, dotAt: CGFloat, x: CGFloat = 8) {
        line(p(x, top), p(x, bottom))
        dot(x, dotAt, 0.9)
    }

    /// A clockwise arc in screen terms, 0° pointing right, ending in an arrowhead.
    func arrowArc(from start: Double, to end: Double, radius: CGFloat = 6.1) {
        let centre = p(8, 8)
        func at(_ degrees: Double) -> CGPoint {
            let r = degrees * .pi / 180
            return p(centre.x + radius * cos(r), centre.y + radius * sin(r))
        }
        stroke(Path { path in
            path.move(to: at(start))
            for degrees in stride(from: start, through: end, by: 5) { path.addLine(to: at(degrees)) }
        })
        let tip = at(end)
        let heading = (end + 90) * .pi / 180
        for side in [-1.0, 1.0] {
            let back = heading + .pi + side * 0.75
            line(tip, p(tip.x + 2.6 * cos(back), tip.y + 2.6 * sin(back)))
        }
    }

    /// A speech bubble with its tail at the lower left.
    func bubble() {
        stroke(Path { b in
            b.move(to: p(4.7, 2.3))
            b.addLine(to: p(11.3, 2.3))
            b.addQuadCurve(to: p(14.3, 5.3), control: p(14.3, 2.3))
            b.addLine(to: p(14.3, 8.1))
            b.addQuadCurve(to: p(11.3, 11.1), control: p(14.3, 11.1))
            b.addLine(to: p(7.6, 11.1))
            b.addLine(to: p(4.2, 14.0))
            b.addLine(to: p(4.6, 11.1))
            b.addQuadCurve(to: p(1.7, 8.1), control: p(1.7, 11.1))
            b.addLine(to: p(1.7, 5.3))
            b.addQuadCurve(to: p(4.7, 2.3), control: p(1.7, 2.3))
            b.closeSubpath()
        })
    }

    func polygon(sides: Int, radii: [CGFloat], rotation: Double = 0) -> Path {
        Path { path in
            for index in 0..<(sides * radii.count) {
                let angle = rotation + Double(index) * 2 * .pi / Double(sides * radii.count)
                let r = radii[index % radii.count]
                let point = p(8 + r * cos(angle), 8 + r * sin(angle))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
    }

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    func draw(_ glyph: StatusGlyph) {
        switch glyph {
        case .ready:
            ring()
            line(p(4.9, 8.3), p(7.1, 10.5), p(11.2, 5.8))
        case .behind:
            ring()
            line(p(8, 4.7), p(8, 11.1))
            line(p(5.4, 8.6), p(8, 11.2), p(10.6, 8.6))
        case .waiting:
            stroke(Path { eye in
                eye.move(to: p(1.2, 8))
                eye.addQuadCurve(to: p(14.8, 8), control: p(8, 1.4))
                eye.addQuadCurve(to: p(1.2, 8), control: p(8, 14.6))
                eye.closeSubpath()
            })
            dot(8, 8, 2.2)
        case .pending:
            ring()
            line(p(8, 4.6), p(8, 8), p(10.7, 9.7))
        case .failing:
            ring()
            line(p(5.7, 5.7), p(10.3, 10.3))
            line(p(10.3, 5.7), p(5.7, 10.3))
        case .shipFailed:
            stroke(polygon(sides: 8, radii: [6.6], rotation: .pi / 8))
            line(p(5.8, 5.8), p(10.2, 10.2))
            line(p(10.2, 5.8), p(5.8, 10.2))
        case .conflicted:
            stroke(Path { $0.addLines([p(8, 1.9), p(14.5, 13.7), p(1.5, 13.7)]); $0.closeSubpath() })
            bang(top: 6.3, bottom: 9.4, dotAt: 11.7)
        case .draft:
            stroke(Path {
                $0.addLines([p(10.8, 2.4), p(13.6, 5.2), p(5.8, 13.0), p(2.4, 13.6), p(3.0, 10.2)])
                $0.closeSubpath()
            })
            line(p(9.3, 3.9), p(12.1, 6.7))
        case .comments:
            bubble()
            dot(5.1, 6.7)
            dot(8, 6.7)
            dot(10.9, 6.7)
        case .changesRequested:
            bubble()
            bang(top: 4.5, bottom: 6.9, dotAt: 8.9)
        case .dismissed:
            arrowArc(from: -40, to: 250)
            bang(top: 5.3, bottom: 8.3, dotAt: 10.5)
        case .approved:
            stroke(polygon(sides: 8, radii: [6.9, 5.6], rotation: -.pi / 2))
            line(p(5.5, 8.2), p(7.3, 10.0), p(10.6, 6.3))
        case .building:
            arrowArc(from: 195, to: 335)
            arrowArc(from: 15, to: 155)
        case .released:
            stroke(Path(roundedRect: CGRect(x: 1.4, y: 2.4, width: 13.2, height: 3.6), cornerRadius: 1.2))
            stroke(Path(roundedRect: CGRect(x: 2.4, y: 6.0, width: 11.2, height: 7.8), cornerRadius: 1.4))
            line(p(6.2, 9.0), p(9.8, 9.0))
        case .stale:
            stroke(Path(ellipseIn: CGRect(x: 1.4, y: 3.6, width: 10.8, height: 10.8)))
            line(p(6.8, 6.4), p(6.8, 9), p(8.8, 10.3))
            bang(top: 1.4, bottom: 5.0, dotAt: 7.4, x: 14.4)
        case .quill:
            dot(8, 1.8, 1.3)
            line(p(8, 3), p(8, 5))
            stroke(Path(roundedRect: CGRect(x: 2.7, y: 5, width: 10.6, height: 9.3), cornerRadius: 2.6))
            fill(Path(roundedRect: CGRect(x: 0.6, y: 8, width: 1.6, height: 3.4), cornerRadius: 0.6))
            fill(Path(roundedRect: CGRect(x: 13.8, y: 8, width: 1.6, height: 3.4), cornerRadius: 0.6))
            dot(6, 9.1, 1.1)
            dot(10, 9.1, 1.1)
            stroke(Path { $0.addLines([p(6.4, 11.9), p(9.6, 11.9)]) }, width: 1.2)
        }
    }
}
