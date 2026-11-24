import Foundation
#if os(macOS)
import CoreFoundation
#endif
import MailpipeCore

public struct SemVer: Comparable, Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let pieces = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = pieces[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Int(core[0]), let minor = Int(core[1]), let patch = Int(core[2]),
              major >= 0, minor >= 0, patch >= 0,
              core.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        var pre: [String] = []
        if pieces.count == 2 {
            let parts = pieces[1].split(whereSeparator: { $0 == "." || $0 == "-" })
            guard !parts.isEmpty else { return nil }
            pre = parts.map(String.init)
        }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = pre
    }

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        // A stable release has higher precedence than any pre-release of the same version.
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let ai = Int(a), let bi = Int(b) { return ai < bi }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// Extract a version from a known launcher banner pattern with one capture group,
    /// then verify it is within the supported compatibility range.
    public static func matchesBanner(_ banner: String, pattern: String, minimum: SemVer,
                                     major: Int? = nil, minor: Int? = nil) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: banner, range: NSRange(banner.startIndex..., in: banner)),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: banner),
              let version = SemVer(String(banner[range])) else {
            return false
        }
        if let major, version.major != major { return false }
        if let minor, version.minor != minor { return false }
        return version >= minimum
    }
}

public protocol HarnessDialect: Sendable {
    var kind: HarnessKind { get }
    var requiredFlags: [String] { get }
    var helpArguments: [String] { get }
    func acceptsVersion(_ version: String) -> Bool
    func probeInvocation(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                         outputLimit: Int) throws -> ProcessInvocation
    func prepare(directory: URL, executable: URL, environment: [String: String]) throws -> [String: String]
}

func tokenCount(_ value: Any?) -> Int? {
#if os(macOS)
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
#else
    if value is Bool { return nil }
    guard let number = value as? NSNumber else { return nil }
#endif
    guard number.doubleValue >= 0, number.doubleValue < Double(Int.max),
          number.doubleValue.rounded() == number.doubleValue else { return nil }
    return number.intValue
}

func classifyFailure(_ data: Data) -> MailpipeError {
    let message = String(decoding: data.prefix(65_536), as: UTF8.self).lowercased()
    if message.contains("not logged in") || message.contains("authentication") || message.contains("unauthorized") {
        return .authRequired
    }
    if message.contains("quota") || message.contains("insufficient_quota") || message.contains("usage limit") { return .quotaExhausted }
    if message.contains("rate limit") || message.contains("rate_limit") || message.contains("429") { return .rateLimited }
    return .processFailed
}

public extension HarnessDialect {
    func acceptsVersion(_ version: String) -> Bool { true }
    func probeInvocation(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                         outputLimit: Int) throws -> ProcessInvocation {
        ProcessInvocation(executable: executable, arguments: arguments, workingDirectory: directory,
                          environment: environment, outputLimit: outputLimit)
    }
    func prepare(directory: URL, executable: URL, environment: [String: String]) throws -> [String: String] { environment }
}
