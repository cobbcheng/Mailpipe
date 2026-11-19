import Foundation
import MailpipeCore

public struct HarnessInstallation: Identifiable, Sendable, Equatable {
    public let kind: HarnessKind
    public let executable: URL
    public var id: String { "\(kind.rawValue):\(executable.path)" }
    public init(kind: HarnessKind, executable: URL) { self.kind = kind; self.executable = executable }
}
public enum HarnessDiscovery {
    private static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Setup offers the first entry. Settings can still inspect distinct installed copies.
    public static func deepSeekLaunchers(in installations: [HarnessInstallation], keeping executable: String?) -> [HarnessInstallation] {
        let candidates = installations.filter { $0.kind == .deepseek }
        guard let executable, executable.hasPrefix("/") else { return candidates }
        let saved = URL(fileURLWithPath: executable)
        let resolved = saved.resolvingSymlinksInPath()
        // GUI launches can have a different PATH. Keep the exact launcher originally
        // selected, including a legacy resolved npm entry point from a discovered dsh.
        guard isExecutable(saved), saved.lastPathComponent == HarnessKind.deepseek.rawValue ||
                candidates.contains(where: { $0.executable.resolvingSymlinksInPath() == resolved }) else { return candidates }
        return [HarnessInstallation(kind: .deepseek, executable: saved)] +
            candidates.filter { $0.executable.resolvingSymlinksInPath() != resolved }
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
            for directory in directories {
                let launchPath = URL(fileURLWithPath: directory).appendingPathComponent(kind.rawValue)
                let resolved = launchPath.resolvingSymlinksInPath()
                let file = kind == .deepseek ? launchPath : resolved
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
    public var realMailStatus: String { "unsafeCapability: M0-08 尚未验收" }
}
