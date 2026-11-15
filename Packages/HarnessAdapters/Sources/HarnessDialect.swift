import Foundation
import CoreFoundation
import MailpipeCore

public struct AdapterResult: Sendable {
    public let response: ClassificationResponse
    public let inputTokens: Int?
    public let outputTokens: Int?
}

public protocol HarnessDialect: Sendable {
    var kind: HarnessKind { get }
    var requiredFlags: [String] { get }
    var helpArguments: [String] { get }
    func arguments(schemaFile: URL) -> [String]
    func decode(_ output: Data, request: ClassificationRequest) throws -> AdapterResult
}

func tokenCount(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue >= 0, number.doubleValue < Double(Int.max),
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
