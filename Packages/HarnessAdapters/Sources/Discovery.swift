import Foundation
import MailpipeCore

public struct HarnessInstallation: Identifiable, Sendable, Equatable {
    public let kind: HarnessKind
    public let executable: URL
    public var id: String { "\(kind.rawValue):\(executable.path)" }
    public init(kind: HarnessKind, executable: URL) { self.kind = kind; self.executable = executable }
}
public enum HarnessDiscovery {
    /// Finds files only. Does not launch a binary, inspect auth, or silently select among installations.
    public static func find(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [HarnessInstallation] {
        let nvm = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nodeBins = ((try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.path < $1.path }.map { $0.appendingPathComponent("bin").path }
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
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      FileManager.default.isExecutableFile(atPath: file.path), seen.insert("\(kind.rawValue):\(resolved.path)").inserted else { continue }
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
    public var supportsSyntheticProbe: Bool { missingFlags.isEmpty }
    /// CLI flags alone are never a safety certification.
    public var realMailStatus: String { "unsafeCapability: M0-08 尚未验收" }
}
