import XCTest
import OctoCore
@testable import OctoAgents

final class ThreadTitleTests: XCTestCase {
    func testTitleValidation() {
        XCTAssertEqual(ThreadTitles.validated("  Fix sidebar sizing  "), "Fix sidebar sizing")
        for value in ["", " \n ", "Title\nSecond line", "Title\u{0000}", String(repeating: "a", count: 101)] {
            XCTAssertNil(ThreadTitles.validated(value))
        }
        XCTAssertEqual(ThreadTitles.validated("修复侧边栏布局"), "修复侧边栏布局")
    }
    func testGeneratedTitlesStayWithinSixWordsAndSixtyCharacters() {
        XCTAssertEqual(ThreadTitles.validated("one two three four five six seven eight"), "one two three four five six")
        XCTAssertEqual(ThreadTitles.validated("one   two    three"), "one two three")
        let longWord = String(repeating: "é", count: 80)
        XCTAssertEqual(ThreadTitles.validated(longWord), String(repeating: "é", count: 60))
        let title = ThreadTitles.validated("Improve authentication authorization observability documentation workflows")!
        XCTAssertLessThanOrEqual(title.count, 60)
        XCTAssertEqual(title, "Improve authentication authorization observability")
    }
    @MainActor func testAdapterConfiguration() {
        XCTAssertEqual(HarnessRegistry.titleConfiguration(.codex), .init(model: "gpt-6-luna", reasoningEffort: "low"))
        XCTAssertNil(HarnessRegistry.titleConfiguration(.claude))
    }
    @MainActor func testFiniteTitleRequestUsesExplicitModelAndIsolatedCLIArguments() async throws {
        let root = try PrivateTemporaryDirectory()
        let fixture = root.url.appendingPathComponent("codex")
        let script = #"""
        #!/usr/bin/python3
        import sys, json, os
        args = sys.argv[1:]
        assert args[0] == 'exec'
        assert all(x in args for x in ['--ephemeral', '--ignore-user-config', '--skip-git-repo-check'])
        assert args[args.index('--sandbox')+1] == 'read-only'
        assert args[args.index('--model')+1] == 'fixture-model'
        assert 'model_reasoning_effort="low"' in args
        assert 'features.shell_tool=false' in args
        assert 'features.apps=false' in args
        assert 'features.remote_plugin=false' in args
        assert 'web_search="disabled"' in args
        assert 'project_doc_max_bytes=0' in args
        assert args[-1] == '-'
        assert oct(os.stat(os.getcwd()).st_mode & 0o777) == '0o700'
        schema = json.load(open(args[args.index('--output-schema')+1]))
        assert schema['required'] == ['title']
        prompt = sys.stdin.read()
        assert 'Do not answer the message' in prompt
        assert 'at most 6 words and 60 characters' in prompt
        text = json.loads(prompt.split('Message (JSON string):\n')[1])
        assert text == 'Summarize this "quoted" request\nSecond line'
        with open(args[args.index('--output-last-message')+1], 'w') as f:
            json.dump({'title':'A concise fixture title'}, f)
        """#
        try Data(script.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let title = try await CodexHarness.generateTitle("Summarize this \"quoted\" request\nSecond line", configuration: .init(model: "fixture-model", reasoningEffort: "low"), executable: fixture)
        XCTAssertEqual(title, "A concise fixture title")
    }
    @MainActor func testUnavailableCLIAndDeadlineDoNotGenerateATitle() async throws {
        let root = try PrivateTemporaryDirectory(), config = ThreadTitleConfiguration(model: "fixture")
        let failed = try await CodexHarness.generateTitle("Prompt", configuration: config, executable: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertNil(failed)
        let fixture = root.url.appendingPathComponent("slow-cli")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        do {
            _ = try await CodexHarness.generateTitle("Prompt", configuration: config, executable: fixture, timeout: 0.1)
            XCTFail("Title subprocess must time out")
        } catch { XCTAssertTrue(error is ProcessFailure) }
        let task = Task { try await CodexHarness.generateTitle("Prompt", configuration: config, executable: fixture) }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        do { _ = try await task.value; XCTFail("Title subprocess must cancel") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
