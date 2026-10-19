import XCTest
import OctoCore
@testable import OctoApp

@MainActor final class ProviderIconTests: XCTestCase {
    func testCompactNumbersSplitOnSignsAndSecondDecimalPoint() {
        XCTAssertEqual(SVGPathData.tokens("m50.228 170.321.843-2.463-.843-1.361h-2e1Z"), [
            .command("m"), .number(50.228), .number(170.321), .number(0.843), .number(-2.463), .number(-0.843), .number(-1.361),
            .command("h"), .number(-20), .command("Z")
        ])
    }
    func testRelativeSegmentsAndImplicitLinesStayInsideViewBox() {
        let path = SVGPathData.path("M10 10h5v5l-5 0 0-5ZM20 20c1 1 2 2 3 3s1 1 2 2")
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 15, height: 15))
    }
    func testEveryProviderMarkFillsItsViewBox() {
        for harness in HarnessID.allCases {
            let mark = ProviderMark.of(harness), bounds = mark.path.boundingBoxOfPath
            XCTAssertFalse(bounds.isEmpty, "\(harness)")
            XCTAssertTrue(mark.viewBox.insetBy(dx: -1, dy: -1).contains(bounds), "\(harness) \(bounds)")
            XCTAssertGreaterThan(bounds.width, mark.viewBox.width * 0.8, "\(harness)")
            XCTAssertEqual(ProviderMark.image(harness).isTemplate, mark.tint == nil)
        }
    }
}
