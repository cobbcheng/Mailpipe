import Foundation
import MailpipeCore

public struct HarnessInstallation: Identifiable, Sendable, Equatable {
    public let kind: HarnessKind
    public let executable: URL
    public let openCodeModel: String?
    public var id: String { "\(kind.rawValue):\(executable.path)" }
    public init(kind: HarnessKind, executable: URL, openCodeModel: String? = nil) {
        self.kind = kind; self.executable = executable; self.openCodeModel = openCodeModel
    }

    public func inspect() async throws -> CapabilityReport {
        switch kind {
        case .deepseek:
            try await DeepSeekHarnessAdapter(executable: executable, dialect: DeepSeekHarnessDialect()).inspect()
        case .claude:
            try await ClaudeCodeHarnessAdapter(executable: executable, dialect: ClaudeCodeDialect()).inspect()
        case .opencode:
            try await OpenCodeHarnessAdapter(executable: executable, dialect: OpenCodeDialect()).inspect()
        case .codex:
            try await CodexCLIAdapter(executable: executable, dialect: CodexCLIDialect()).inspect()
        }
    }
}
public enum HarnessDiscovery {
    private static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Retain the launcher the user chose across GUI PATH changes and CLI upgrades.
    public static func replyLaunchers(in installations: [HarnessInstallation], keeping executable: String?,
                                      kind: HarnessKind = .deepseek) -> [HarnessInstallation] {
        let candidates = installations.filter { $0.kind.supportsReplyDrafts }
        guard kind.supportsReplyDrafts, let executable, executable.hasPrefix("/") else { return candidates }
        let saved = URL(fileURLWithPath: executable)
        let resolved = saved.resolvingSymlinksInPath()
        guard isExecutable(saved), saved.lastPathComponent == kind.rawValue ||
                candidates.contains(where: { $0.kind == kind && $0.executable.resolvingSymlinksInPath() == resolved })
        else { return candidates }
        return [HarnessInstallation(kind: kind, executable: saved)] +
            candidates.filter { $0.kind != kind || $0.executable.resolvingSymlinksInPath() != resolved }
    }

    /// Finds files only. Does not launch a binary, inspect auth, or silently select among installations.
    public static func find(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [HarnessInstallation] {
        let nvm = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nodeBins = ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { nvm.appendingPathComponent($0).appendingPathComponent("bin").path }
        let directories = path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") } + [
            home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".npm-global/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin"
        ] + nodeBins
        var found: [HarnessInstallation] = [], seen: Set<String> = []
        for kind in HarnessKind.allCases {
            let searchDirectories = kind == .opencode ? directories + [home.appendingPathComponent(".opencode/bin").path] : directories
            for directory in searchDirectories {
                let launchPath = URL(fileURLWithPath: directory).appendingPathComponent(kind.rawValue)
                let resolved = launchPath.resolvingSymlinksInPath()
                let file = kind == .codex ? resolved : launchPath
                guard isExecutable(file), seen.insert("\(kind.rawValue):\(resolved.path)").inserted else { continue }
                found.append(HarnessInstallation(kind: kind, executable: file))
            }
        }
        return found
    }
}

public struct CapabilityReport: Sendable {
    public let installation: HarnessInstallation
    public let version: String
    public let missingFlags: [String]
    public var supportsHeadlessRun: Bool { missingFlags.isEmpty }
    /// CLI flags alone are never a safety certification.
    public var realMailStatus: String { "此检查仅核验 CLI 版本和参数；回复授权与示例试写见 App 设置。" }
}
