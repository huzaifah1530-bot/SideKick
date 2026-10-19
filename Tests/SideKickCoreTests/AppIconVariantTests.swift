import XCTest
@testable import SideKickCore

final class AppIconVariantTests: XCTestCase {
    private func rgb(_ hex: Int) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private func name(_ hex: Int) -> String? {
        let (r, g, b) = rgb(hex)
        return AppIconVariant.iconName(red: r, green: g, blue: b)
    }

    func testDefaultTealAccentsUsePrimaryIcon() {
        XCTAssertNil(name(0x007A74))
        XCTAssertNil(name(0x3DD6C6))
        XCTAssertNil(name(0x2EE0C4))
    }

    func testAccentsMapToNearestHueBucket() {
        // Pure blue (240°) is ~70° from the reference hue.
        XCTAssertEqual(name(0x0000FF), "AppIcon-Hue060")
        // Pure red (0°) is ~190° away.
        XCTAssertEqual(name(0xFF0000), "AppIcon-Hue180")
        // Pure green (120°) is ~310° away.
        XCTAssertEqual(name(0x00FF00), "AppIcon-Hue300")
    }

    func testUnsaturatedAccentsUseMonoIcon() {
        XCTAssertEqual(name(0x808080), AppIconVariant.monoName)
        XCTAssertEqual(name(0x000000), AppIconVariant.monoName)
        XCTAssertEqual(name(0xFFFFFF), AppIconVariant.monoName)
    }

    func testEveryResultIsAShippedIcon() {
        let names = Set(AppIconVariant.allNames)
        XCTAssertEqual(names.count, 12)
        for hue in stride(from: 0.0, to: 1.0, by: 0.01) {
            let degrees = hue * 360
            let x = 1 - abs((degrees / 60).truncatingRemainder(dividingBy: 2) - 1)
            let (r, g, b): (Double, Double, Double) = switch Int(degrees / 60) {
            case 0: (1, x, 0)
            case 1: (x, 1, 0)
            case 2: (0, 1, x)
            case 3: (0, x, 1)
            case 4: (x, 0, 1)
            default: (1, 0, x)
            }
            if let result = AppIconVariant.iconName(red: r, green: g, blue: b) {
                XCTAssertTrue(names.contains(result), result)
            }
        }
    }

    func testRotationRoundTrips() {
        XCTAssertEqual(AppIconVariant.rotation(for: nil), 0)
        XCTAssertEqual(AppIconVariant.rotation(for: "AppIcon-Hue090"), 90)
        XCTAssertNil(AppIconVariant.rotation(for: AppIconVariant.monoName))
    }
}
