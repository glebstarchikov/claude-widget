import Foundation
import CoreGraphics

public enum CritterPose: Equatable, Sendable {
    case idle, walkA, walkB, blink, asleep
}

public struct Circle2D: Equatable, Sendable {
    public let center: CGPoint
    public let radius: CGFloat
}

public enum CritterGeometry {
    public static let canvas = CGSize(width: 24, height: 24)

    static let body = CGRect(x: 3, y: 5, width: 17.998, height: 12.079)
    static let leftNub = CGRect(x: 0, y: 10.95, width: 3, height: 3.1)
    static let rightNub = CGRect(x: 21, y: 10.949, width: 3, height: 3.102)
    static let legs = [
        CGRect(x: 4.487, y: 17.079, width: 1.513, height: 2.921),
        CGRect(x: 7.488, y: 17.079, width: 1.512, height: 2.921),
        CGRect(x: 15, y: 17.079, width: 1.513, height: 2.921),
        CGRect(x: 18, y: 17.079, width: 1.513, height: 2.921),
    ]
    static let eyes = [
        CGRect(x: 6, y: 8.102, width: 1.488, height: 2.847),
        CGRect(x: 16.51, y: 8.102, width: 1.49, height: 2.847),
    ]

    public static func bodyRects(pose: CritterPose) -> [CGRect] {
        var rects = [body, leftNub, rightNub]
        for (index, leg) in legs.enumerated() {
            let lifted = (pose == .walkA && (index == 0 || index == 2))
                      || (pose == .walkB && (index == 1 || index == 3))
            var rect = leg
            if lifted { rect.size.height *= 0.6 }
            rects.append(rect)
        }
        return rects
    }

    public static func eyeCutouts(pose: CritterPose) -> [CGRect] {
        switch pose {
        case .blink:
            return []
        case .asleep:
            return eyes.map { CGRect(x: $0.minX, y: $0.maxY - 1.05, width: $0.width, height: 1.05) }
        default:
            return eyes
        }
    }

    // MARK: New Year hat and needs-you badge

    /// With the hat on, the body is drawn this far down so the hat fits in the
    /// canvas above it (body bottom lands at 23 of 24). The hat's own
    /// coordinates already include this shift; `bodyRects` itself is unchanged.
    public static let hatBodyShift: CGFloat = 3

    /// Centered cone whose tip flops to the right.
    public static func hatCone() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 8, y: 6.6))
        path.addLine(to: CGPoint(x: 16, y: 6.6))
        path.addLine(to: CGPoint(x: 14.2, y: 2.4))
        path.addQuadCurve(to: CGPoint(x: 11.2, y: 1.6), control: CGPoint(x: 13, y: 0.4))
        path.closeSubpath()
        return path
    }
    public static let hatBrim = CGRect(x: 7, y: 6.3, width: 10, height: 1.8)
    public static let hatPom = Circle2D(center: CGPoint(x: 11, y: 1.6), radius: 1.25)

    /// Top-right "needs you" dot; `badgeGap` is the clear ring cut around it.
    public static let badge = Circle2D(center: CGPoint(x: 20.2, y: 3.8), radius: 2.6)
    public static let badgeGap: CGFloat = 1.2
}
