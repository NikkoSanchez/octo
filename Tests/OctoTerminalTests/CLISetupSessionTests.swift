import XCTest
@testable import OctoTerminal

@MainActor final class CLISetupSessionTests: XCTestCase {
    func testDedicatedTerminalLaunchQuotesEveryArgument() {
        let command = CLISetupSession.command(executable: URL(fileURLWithPath: "/tmp/Claude's folder/claude"), arguments: ["auth", "login", "$(touch bad)"])
        XCTAssertEqual(command, "'/tmp/Claude'\\''s folder/claude' 'auth' 'login' '$(touch bad)'")
    }
}
