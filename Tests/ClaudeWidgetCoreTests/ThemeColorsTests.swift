import XCTest
@testable import ClaudeWidgetCore

final class ThemeColorsTests: XCTestCase {
    func testHexRoundTripAndRejects() {
        XCTAssertEqual(RGB(hex: "#d97757")?.hex, "#D97757")
        XCTAssertNil(RGB(hex: "D97757")); XCTAssertNil(RGB(hex: "#D9775")); XCTAssertNil(RGB(hex: "#GG7757"))
        XCTAssertNil(RGB(hex: "#+12345")); XCTAssertNil(RGB(hex: "#-00000"))
    }
    func testContrastKnownValues() {
        let w = RGB(hex: "#FFFFFF")!, b = RGB(hex: "#000000")!
        XCTAssertEqual(w.contrast(with: b), 21, accuracy: 0.01)
        XCTAssertEqual(RGB(hex: "#D97757")!.contrast(with: ThemePalette.darkBar), 4.83, accuracy: 0.02)
    }
    func testPresetTableIsExact() {
        let expected: [ThemeID: (String, String)] = [
            .claude: ("#C36B4E", "#D97757"), .lime: ("#5E9425", "#6FAE2C"), .mint: ("#1C9571", "#1FA67E"),
            .ocean: ("#2C7FE0", "#2C7FE0"), .indigo: ("#4B46F5", "#8A86FF"), .violet: ("#9459E6", "#9459E6"),
            .rose: ("#DB4F84", "#DB4F84"), .system: ("#1D1D1F", "#F5F5F7")]
        for (id, (l, d)) in expected {
            let p = ThemePalette.pair(for: id, custom: RGB(hex: "#000000")!)
            XCTAssertEqual(p.light.hex, l, "\(id) light"); XCTAssertEqual(p.dark.hex, d, "\(id) dark")
        }
    }
    func testEveryPresetMeetsThreeToOne() {
        for id in ThemeID.allCases where id != .custom {
            let p = ThemePalette.pair(for: id, custom: RGB(hex: "#000000")!)
            XCTAssertGreaterThanOrEqual(p.light.contrast(with: ThemePalette.lightBar), 3, "\(id)")
            XCTAssertGreaterThanOrEqual(p.dark.contrast(with: ThemePalette.darkBar), 3, "\(id)")
        }
    }
    func testCustomExtremesAreFittedOnBothBars() {
        for hex in ["#FFFFFF", "#FFF2A8", "#000000", "#101030", "#2BB3C0"] {
            let p = ThemePalette.pair(for: .custom, custom: RGB(hex: hex)!)
            XCTAssertGreaterThanOrEqual(p.light.contrast(with: ThemePalette.lightBar), 3, hex)
            XCTAssertGreaterThanOrEqual(p.dark.contrast(with: ThemePalette.darkBar), 3, hex)
        }
    }
    func testFittingStopsAtTheFirstPassingStep() {
        let c = RGB(hex: "#FFF2A8")!
        let fitted = c.fitted(against: ThemePalette.lightBar, toward: ThemePalette.black)
        XCTAssertGreaterThanOrEqual(fitted.contrast(with: ThemePalette.lightBar), 3)
        var fraction = 0.0
        for step in 1...20 where c.mixed(with: ThemePalette.black, fraction: Double(step) * 0.05) == fitted { fraction = Double(step) * 0.05 }
        XCTAssertGreaterThan(fraction, 0.05, "this color needs fitting")
        let previous = c.mixed(with: ThemePalette.black, fraction: fraction - 0.05)
        XCTAssertLessThan(previous.contrast(with: ThemePalette.lightBar), 3, "one step less mixed must fail")
    }
    func testCustomThatAlreadyPassesIsUntouched() {   // negative: fitting must not drift a good color
        let p = ThemePalette.pair(for: .custom, custom: RGB(hex: "#2C7FE0")!)
        XCTAssertEqual(p.light.hex, "#2C7FE0"); XCTAssertEqual(p.dark.hex, "#2C7FE0")
    }
    func testOnAccentIsWhiteUnlessItFallsBelowThreeToOne() {
        XCTAssertEqual(ThemePalette.onAccent(RGB(hex: "#4B46F5")!), ThemePalette.white)
        XCTAssertEqual(ThemePalette.onAccent(RGB(hex: "#6FAE2C")!), ThemePalette.darkText)  // white is 2.7:1
    }
    func testOnAccentForMacOSAccentColors() {
        XCTAssertEqual(ThemePalette.onAccent(RGB(hex: "#FFCC00")!), ThemePalette.darkText)  // yellow
        XCTAssertEqual(ThemePalette.onAccent(RGB(hex: "#953D96")!), ThemePalette.white)     // purple
        XCTAssertEqual(ThemePalette.onAccent(RGB(hex: "#007AFF")!), ThemePalette.white)     // macOS blue, ~4.0:1
    }
    func testOnAccentIsWhiteOnClaudeOrange() {
        XCTAssertEqual(ThemePalette.onAccent(RGB(hex: "#D97757")!), ThemePalette.white)     // ~3.1:1
        XCTAssertEqual(ThemePalette.onAccent(RGB(hex: "#C36B4E")!), ThemePalette.white)
    }
    func testOnAccentStaysDarkJustUnderThreeToOne() {   // negative: the white rule must not swallow fills below 3:1
        let fill = RGB(hex: "#E07A5A")!
        let ratio = fill.contrast(with: ThemePalette.white)
        XCTAssertLessThan(ratio, 3); XCTAssertGreaterThan(ratio, 2.8)
        XCTAssertEqual(ThemePalette.onAccent(fill), ThemePalette.darkText)
    }
    func testNewYearWindowBoundaries() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: day, hour: h))!
        }
        XCTAssertFalse(NewYear.isActive(on: d(2026, 12, 14, 23), calendar: cal))
        XCTAssertTrue(NewYear.isActive(on: d(2026, 12, 15, 0), calendar: cal))
        XCTAssertTrue(NewYear.isActive(on: d(2026, 12, 31), calendar: cal))
        XCTAssertTrue(NewYear.isActive(on: d(2027, 1, 1), calendar: cal))
        XCTAssertTrue(NewYear.isActive(on: d(2027, 1, 7, 23), calendar: cal))
        XCTAssertFalse(NewYear.isActive(on: d(2027, 1, 8, 0), calendar: cal))
        XCTAssertFalse(NewYear.isActive(on: d(2026, 7, 1), calendar: cal))
    }
}
