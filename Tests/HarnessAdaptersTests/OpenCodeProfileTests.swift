import Foundation
import XCTest
@testable import HarnessAdapters
import MailpipeCore

final class OpenCodeProfileTests: XCTestCase {
    func testIsolatesProviderConfigAndSuppressesSkillToolAndExternalPlugins() throws {
        let root = try TemporaryDirectory()
        let work = root.url.appendingPathComponent("work")
        let configDirectory = root.url.appendingPathComponent(".config/opencode")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let config = configDirectory.appendingPathComponent("opencode.jsonc")
        let providerSettings = Data(#"{"provider":{"fixture":{"name":"synthetic provider marker"}}}"#.utf8)
        try providerSettings.write(to: config)
        let executable = root.url.appendingPathComponent("opencode")
        let env = try OpenCodeProfile.prepare(directory: work, executable: executable, environment: [
            "HOME": root.url.path, "OPENCODE_CONFIG_CONTENT": "unused", "ANTHROPIC_API_KEY": "fixture"
        ])
        XCTAssertEqual(env["OPENCODE_CONFIG"], config.path)
        XCTAssertEqual(env["OPENCODE_DISABLE_AUTOUPDATE"], "1")
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        let content = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        XCTAssertFalse(content.contains("synthetic provider marker"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let plugins = try XCTUnwrap(settings["plugins"] as? [String])
        XCTAssertTrue(plugins.contains("-opencode.tool.skill"))
        XCTAssertTrue(plugins.contains("-opencode.config.instruction"))
        let guardFile = work.appendingPathComponent("config/opencode/opencode.json")
        let guardSettings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: guardFile)) as? [String: Any])
        let policies = try XCTUnwrap(guardSettings["policies"] as? [[String: String]])
        XCTAssertTrue(policies.contains(["action": "plugin.use", "resource": "*", "effect": "deny"]))
        XCTAssertTrue(policies.contains(["action": "mcp.use", "resource": "*", "effect": "deny"]))
        XCTAssertEqual(try Data(contentsOf: config), providerSettings)

        try Data("{}".utf8).write(to: configDirectory.appendingPathComponent("opencode.json"))
        XCTAssertThrowsError(try OpenCodeProfile.prepare(directory: work, executable: executable,
                                                        environment: ["HOME": root.url.path])) {
            XCTAssertEqual($0 as? MailpipeError, .unsafeCapability)
        }
    }
}
