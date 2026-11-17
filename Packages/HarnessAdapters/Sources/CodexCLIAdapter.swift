import Foundation
import MailpipeCore

public struct CodexCLIDialect: HarnessDialect {
    public init() {}
    public var kind: HarnessKind { .codex }
    public var helpArguments: [String] { ["exec", "--help"] }
    public var requiredFlags: [String] {
        ["--json", "--output-schema", "--sandbox", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules"]
    }
}
public typealias CodexCLIAdapter = CLIAdapter<CodexCLIDialect>
