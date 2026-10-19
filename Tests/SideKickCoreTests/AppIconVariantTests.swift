import XCTest
@testable import SideKickCore

final class AppIconVariantTests: XCTestCase {
    private func name(_ hex: Int) -> String? {
        AppIconVariant.iconName(red: Double((hex >> 16) & 0xFF) / 255,
                                green: Double((hex >> 8) & 0xFF) / 255,
                                blue: Double(hex & 0xFF) / 255)
    }

    func testDefaultTealAccentsUsePrimaryIcon() {
        XCTAssertNil(name(0x007A74))
        XCTAssertNil(name(0x3DD6C6))
        XCTAssertNil(name(0x2EE0C4))
    }

    func testAccentsUseTheirOwnHue() {
        // Variants are centred on the accent's hue, so red is red, not orange.
        XCTAssertEqual(name(0xFF0000), "AppIcon-Hue000")
        XCTAssertEqual(name(0xFF3B30), "AppIcon-Hue000") // system red
        XCTAssertEqual(name(0xFF9500), "AppIcon-Hue030") // system orange
        XCTAssertEqual(name(0x00FF00), "AppIcon-Hue120")
        XCTAssertEqual(name(0x0000FF), "AppIcon-Hue240")
        XCTAssertEqual(name(0xFF00FF), "AppIcon-Hue300")
        XCTAssertEqual(name(0xFF0010), "AppIcon-Hue000") // 356° wraps to 0°
    }

    func testUnsaturatedAccentsUseMonoIcon() {
        XCTAssertEqual(name(0x808080), AppIconVariant.monoName)
        XCTAssertEqual(name(0x000000), AppIconVariant.monoName)
        XCTAssertEqual(name(0xFFFFFF), AppIconVariant.monoName)
    }

    func testEveryResultIsAShippedIcon() throws {
        let names = Set(AppIconVariant.allNames)
        XCTAssertEqual(names.count, 22)
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("SideKick/Assets.xcassets")
        for name in names {
            XCTAssertTrue(FileManager.default.fileExists(atPath: catalog.appendingPathComponent(name + ".appiconset").path), name)
            let preview = AppIconVariant.previewName(for: name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: catalog.appendingPathComponent(preview + ".imageset").path), preview)
        }
        for degrees in stride(from: 0.0, to: 360.0, by: 1.0) {
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

    func testPreviewNames() {
        XCTAssertEqual(AppIconVariant.previewName(for: nil), "AppIconPreview")
        XCTAssertEqual(AppIconVariant.previewName(for: "AppIcon-Hue090"), "AppIconPreview-Hue090")
        XCTAssertEqual(AppIconVariant.previewName(for: AppIconVariant.monoName), "AppIconPreview-Mono")
        XCTAssertEqual(AppIconVariant.previewName(for: "SomethingElse"), "AppIconPreview")
    }
}
