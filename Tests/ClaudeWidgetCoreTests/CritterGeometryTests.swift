import XCTest
@testable import ClaudeWidgetCore

final class CritterGeometryTests: XCTestCase {
    func testIdleHasSevenBodyRectsWithOfficialCoordinates() {
        let rects = CritterGeometry.bodyRects(pose: .idle)
        XCTAssertEqual(rects.count, 7)
        XCTAssertEqual(rects[0], CGRect(x: 3, y: 5, width: 17.998, height: 12.079), "body")
        XCTAssertEqual(rects[1], CGRect(x: 0, y: 10.95, width: 3, height: 3.1), "left nub")
        XCTAssertEqual(rects[2], CGRect(x: 21, y: 10.949, width: 3, height: 3.102), "right nub")
        XCTAssertEqual(rects[3], CGRect(x: 4.487, y: 17.079, width: 1.513, height: 2.921), "leg 1")
        XCTAssertEqual(rects[4], CGRect(x: 7.488, y: 17.079, width: 1.512, height: 2.921), "leg 2")
        XCTAssertEqual(rects[5], CGRect(x: 15, y: 17.079, width: 1.513, height: 2.921), "leg 3")
        XCTAssertEqual(rects[6], CGRect(x: 18, y: 17.079, width: 1.513, height: 2.921), "leg 4")
    }

    func testWalkALiftsLegsOneAndThree() {
        let rects = CritterGeometry.bodyRects(pose: .walkA)
        let full = 2.921, lifted = 2.921 * 0.6
        XCTAssertEqual(rects[3].height, lifted, accuracy: 0.001)
        XCTAssertEqual(rects[4].height, full, accuracy: 0.001)
        XCTAssertEqual(rects[5].height, lifted, accuracy: 0.001)
        XCTAssertEqual(rects[6].height, full, accuracy: 0.001)
        XCTAssertEqual(rects[3].minY, 17.079, "top-anchored: feet lift, hip stays")
    }

    func testWalkBLiftsLegsTwoAndFour() {
        let rects = CritterGeometry.bodyRects(pose: .walkB)
        XCTAssertEqual(rects[3].height, 2.921, accuracy: 0.001)
        XCTAssertEqual(rects[4].height, 2.921 * 0.6, accuracy: 0.001)
        XCTAssertEqual(rects[5].height, 2.921, accuracy: 0.001)
        XCTAssertEqual(rects[6].height, 2.921 * 0.6, accuracy: 0.001)
        XCTAssertEqual(rects[6].minY, 17.079, accuracy: 0.001)
    }

    func testEyes() {
        let open = CritterGeometry.eyeCutouts(pose: .idle)
        XCTAssertEqual(open[0], CGRect(x: 6, y: 8.102, width: 1.488, height: 2.847))
        XCTAssertEqual(open[1], CGRect(x: 16.51, y: 8.102, width: 1.49, height: 2.847))

        XCTAssertTrue(CritterGeometry.eyeCutouts(pose: .blink).isEmpty)

        let asleep = CritterGeometry.eyeCutouts(pose: .asleep)
        XCTAssertEqual(asleep[0].height, 1.05, accuracy: 0.001)
        XCTAssertEqual(asleep[0].maxY, 8.102 + 2.847, accuracy: 0.001, "lid closes from the top, slit stays at the bottom")
        XCTAssertEqual(asleep[1].height, 1.05, accuracy: 0.001)
        XCTAssertEqual(asleep[1].maxY, 8.102 + 2.847, accuracy: 0.001)
    }

    func testHatAndBadgeStayInsideTheCanvas() {
        let canvas = CGRect(origin: .zero, size: CritterGeometry.canvas)
        XCTAssertTrue(canvas.contains(CritterGeometry.hatCone().boundingBoxOfPath))
        XCTAssertTrue(canvas.contains(CritterGeometry.hatBrim))
        let pom = CritterGeometry.hatPom
        XCTAssertTrue(canvas.contains(CGRect(x: pom.center.x - pom.radius, y: pom.center.y - pom.radius,
                                             width: pom.radius * 2, height: pom.radius * 2)))
        for hat in [false, true] {
            let b = CritterGeometry.badge(hat: hat), r = b.radius + CritterGeometry.badgeGap
            XCTAssertTrue(canvas.contains(CGRect(x: b.center.x - r, y: b.center.y - r, width: r * 2, height: r * 2)), "hat \(hat)")
        }
    }

    func testBodyWithHatStaysInsideTheCanvas() {
        let canvas = CGRect(origin: .zero, size: CritterGeometry.canvas)
        for rect in CritterGeometry.bodyRects(pose: .idle) {
            XCTAssertTrue(canvas.contains(rect.offsetBy(dx: 0, dy: CritterGeometry.hatBodyShift)))
        }
    }

    func testHatSitsOnTheShiftedBody() {
        let top = CritterGeometry.bodyRects(pose: .idle)[0].minY + CritterGeometry.hatBodyShift
        XCTAssertEqual(CritterGeometry.hatBrim.maxY, top, accuracy: 0.3)
    }

    func testPomHangsToTheSideOfTheConeCenter() {
        let cone = CritterGeometry.hatCone().boundingBoxOfPath
        XCTAssertNotEqual(CritterGeometry.hatPom.center.x, cone.midX, accuracy: 0.5)
    }

    private func distance(from p: CGPoint, to r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }

    func testBadgeNeverTouchesTheHat() {
        let b = CritterGeometry.badge(hat: true), p = CritterGeometry.hatPom
        let clear = b.radius + CritterGeometry.badgeGap
        XCTAssertGreaterThan(hypot(b.center.x - p.center.x, b.center.y - p.center.y) - p.radius, clear, "pom")
        XCTAssertGreaterThan(distance(from: b.center, to: CritterGeometry.hatCone().boundingBoxOfPath), clear, "cone")
        XCTAssertGreaterThan(distance(from: b.center, to: CritterGeometry.hatBrim), clear, "brim")
    }

    func testBadgeMovesWithTheBodyAndKeepsItsCorner() {
        let body = CritterGeometry.bodyRects(pose: .idle)[0]
        let plain = CritterGeometry.badge(hat: false), hatted = CritterGeometry.badge(hat: true)
        XCTAssertEqual(hatted.radius, plain.radius)
        XCTAssertEqual(hatted.center.x, plain.center.x)
        XCTAssertEqual(hatted.center.y - plain.center.y, CritterGeometry.hatBodyShift, accuracy: 0.001)
        XCTAssertEqual(plain.center.y - body.minY, hatted.center.y - (body.minY + CritterGeometry.hatBodyShift), accuracy: 0.001,
                       "same offset from the body's top edge with and without the hat")
        XCTAssertEqual(hatted.center.x, body.maxX - 0.8, accuracy: 1, "on the body's right corner")
    }

    func testBodyIsUnchangedWithoutHat() {
        XCTAssertEqual(CritterGeometry.bodyRects(pose: .idle)[0], CGRect(x: 3, y: 5, width: 17.998, height: 12.079))
    }
}
