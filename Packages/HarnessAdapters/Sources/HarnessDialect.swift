import Foundation
#if os(macOS)
import CoreFoundation
#endif
import MailpipeCore

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
