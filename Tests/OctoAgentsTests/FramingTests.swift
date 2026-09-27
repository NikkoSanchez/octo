import XCTest
@testable import OctoAgents

final class FramingTests: XCTestCase {
    func testLimitAppliesToCompleteFragmentedAndFinalFrames() throws {
        for chunks in [[Data("123456789\n".utf8)], [Data("123456".utf8), Data("789\n".utf8)], [Data("123456789".utf8)]] {
            var framer = JSONLineFramer(limit: 8), emitted = [Data]()
            XCTAssertThrowsError(try chunks.forEach { try framer.receive($0) { emitted.append($0) } })
            XCTAssertTrue(emitted.isEmpty)
        }
        var framer = JSONLineFramer(limit: 8), emitted = [Data]()
        let bytes = Data("🐙\ncafé".utf8)
        for byte in bytes { try framer.receive(Data([byte])) { emitted.append($0) } }
        framer.finish { emitted.append($0) }
        XCTAssertEqual(emitted.map { String(decoding: $0, as: UTF8.self) }, ["🐙", "café"])
    }
}
