import Foundation
import XCTest

/// `Scripts/build-app.sh` builds Octo.xcodeproj, whose app target lists its sources by hand, while
/// `swift test` compiles the whole folder. A new file left out of the project passes every test
/// and still breaks the app build.
final class XcodeProjectTests: XCTestCase {
    func testEveryAppSourceIsInTheXcodeTarget() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("Octo.xcodeproj/project.pbxproj"), encoding: .utf8)
        let sources = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/OctoApp").path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(sources.isEmpty)
        for file in sources {
            // Each needs a file reference and a build file pointing at it.
            guard let reference = project.range(of: #"(\w{24}) = \{ isa = PBXFileReference; [^}]*path = "# + NSRegularExpression.escapedPattern(for: file) + ";",
                                                options: .regularExpression) else {
                XCTFail("\(file) is missing from Octo.xcodeproj"); continue
            }
            let id = String(project[reference].prefix(24))
            XCTAssertTrue(project.contains("isa = PBXBuildFile; fileRef = \(id);"), "\(file) is not compiled by the app target")
        }
    }
}
