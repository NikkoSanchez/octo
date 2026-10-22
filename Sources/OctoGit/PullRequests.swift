import Foundation
import OctoCore

public struct PullRequest: Equatable, Sendable, Decodable {
    public var number: Int
    public var url: String
    public var title: String
    public var isDraft: Bool
    public var baseRefName: String
    public init(number: Int, url: String, title: String, isDraft: Bool, baseRefName: String) {
        self.number = number; self.url = url; self.title = title; self.isDraft = isDraft; self.baseRefName = baseRefName
    }
}

/// GitHub pull requests through the user's installed and authenticated GitHub CLI (`gh`).
/// Octo stores no token; gh's own account, repository resolution and errors apply.
public enum PullRequests {
    /// Prompts would wait on a terminal Octo does not attach, so gh fails with its message instead.
    static let environment = ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "GH_SPINNER_DISABLED": "1", "NO_COLOR": "1"]
    public static var isAvailable: Bool { Executables.find("gh") != nil }

    private static func gh(_ arguments: [String], root: String) async throws -> ProcessResult {
        guard let executable = Executables.find("gh") else {
            throw ProcessFailure.missing("The GitHub CLI (gh)")
        }
        return try await ProcessRunner.run(executable, arguments: arguments, directory: URL(fileURLWithPath: root),
                                           environment: environment, timeout: 120)
    }
    /// The open pull request whose head is `branch`, if any. `--head` keeps a numeric branch
    /// name from being read as a pull request number.
    public static func open(branch: String, root: String) async throws -> PullRequest? {
        let result = try await gh(["pr", "list", "--head=\(branch)", "--state=open", "--limit=1",
                                   "--json=number,url,title,isDraft,baseRefName"], root: root)
        guard result.status == 0 else { throw ProcessFailure.exited(GitService.message(result)) }
        return try JSONDecoder().decode([PullRequest].self, from: result.output).first
    }
    /// Creates the pull request from an already pushed `head`. Flag values use the `--flag=value`
    /// form so a title beginning with "-" cannot be read as an option.
    public static func create(title: String, body: String, base: String, head: String, draft: Bool, root: String) async throws -> PullRequest {
        var arguments = ["pr", "create", "--title=\(title)", "--body=\(body)", "--base=\(base)", "--head=\(head)"]
        if draft { arguments.append("--draft") }
        let result = try await gh(arguments, root: root)
        guard result.status == 0 else { throw ProcessFailure.exited(GitService.message(result)) }
        let output = String(decoding: result.output, as: UTF8.self)
        guard let url = output.split(whereSeparator: \.isNewline).map(String.init).last(where: { $0.hasPrefix("https://") }),
              let number = number(from: url) else {
            throw ProcessFailure.exited("GitHub CLI did not report the new pull request's address.\n\n" + output)
        }
        return PullRequest(number: number, url: url, title: title, isDraft: draft, baseRefName: base)
    }
    static func number(from url: String) -> Int? {
        guard let range = url.range(of: "/pull/") else { return nil }
        return Int(url[range.upperBound...].prefix { $0.isNumber })
    }
}
