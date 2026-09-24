import CoreGraphics

/// 把 `CGPath` 转换为 SVG path data（M、L、Q、C、Z 命令）。坐标原样输出，不做变换。
enum BezierPathSVG {
    static func pathData(_ path: CGPath) -> String {
        var parts: [String] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                parts.append("M \(BezierPathSVG.coord(points[0]))")
            case .addLineToPoint:
                parts.append("L \(BezierPathSVG.coord(points[0]))")
            case .addQuadCurveToPoint:
                parts.append("Q \(BezierPathSVG.coord(points[0])) \(BezierPathSVG.coord(points[1]))")
            case .addCurveToPoint:
                parts.append("C \(BezierPathSVG.coord(points[0])) \(BezierPathSVG.coord(points[1])) \(BezierPathSVG.coord(points[2]))")
            case .closeSubpath:
                parts.append("Z")
            @unknown default:
                break
            }
        }
        return parts.joined(separator: " ")
    }

    private static func coord(_ p: CGPoint) -> String {
        return "\(number(p.x)) \(number(p.y))"
    }

    private static func number(_ v: CGFloat) -> String {
        let d = Double(v)
        return d.isFinite ? JSONWriter.formatNumber(d) : "0"
    }
}
