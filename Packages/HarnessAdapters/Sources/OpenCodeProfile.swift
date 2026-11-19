import Foundation
import MailpipeCore

enum OpenCodeProfile {
    static func prepare(directory: URL, executable: URL, environment: [String: String]) throws -> [String: String] {
        let files = FileManager.default
        // The CLI loads system documents after the explicit and inline settings.
        // Route selection and empty-tool evidence below cover unmanaged installations.
        #if os(macOS)
        let managedDirectory = "/Library/Application Support/opencode"
        let preferences = "/Library/Managed Preferences"
        let plist = "ai.opencode.managed.plist"
        guard !files.fileExists(atPath: "\(preferences)/\(NSUserName())/\(plist)"),
              !files.fileExists(atPath: "\(preferences)/\(plist)") else { throw MailpipeError.unsafeCapability }
        #else
        let managedDirectory = "/etc/opencode"
        #endif
        if files.fileExists(atPath: managedDirectory),
           (try? files.contentsOfDirectory(atPath: managedDirectory).isEmpty) != true {
            throw MailpipeError.unsafeCapability
        }
        let configRoot = directory.appendingPathComponent("config")
        let globalConfig = configRoot.appendingPathComponent("opencode")
        let temporaryHome = directory.appendingPathComponent("home")
        let tmp = directory.appendingPathComponent("tmp")
        for url in [globalConfig, temporaryHome, tmp] {
            try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        // 2.3.0 evaluates policies in reverse document order; its earliest global policy wins.
        // Put the guard in the global file, ahead of the CLI's native provider configuration.
        let policies = ["plugin.use", "mcp.use", "skill.use", "tool.use"].map {
            ["action": $0, "resource": "*", "effect": "deny"]
        }
        try JSONSerialization.data(withJSONObject: ["policies": policies])
            .write(to: globalConfig.appendingPathComponent("opencode.json"), options: .atomic)
        guard let policyFile = Bundle.module.url(forResource: "reply-policy", withExtension: "md", subdirectory: "Resources")
        else { throw MailpipeError.unsafeCapability }
        let policy = try String(contentsOf: policyFile, encoding: .utf8)
        let denies = [["action": "*", "resource": "*", "effect": "deny"]]
        // The skill tool is still advertised under a blanket permission denial in 2.3.0.
        // Remove its registration, plus the native tools and sources of user-supplied context.
        let disabled = [
            "opencode.browser", "opencode.tools", "opencode.tools.mcp-resources", "opencode.tools.mcp-events",
            "opencode.tool.artifact", "opencode.tool.edit", "opencode.tool.glob", "opencode.tool.grep",
            "opencode.tool.image-generate", "opencode.tool.patch", "opencode.tool.question", "opencode.tool.read",
            "opencode.tool.schedule", "opencode.tool.shell", "opencode.tool.skill", "opencode.tool.subagent",
            "opencode.tool.todo", "opencode.tool.webfetch", "opencode.tool.websearch", "opencode.tool.write",
            "opencode.config.command", "opencode.config.compatibility", "opencode.config.instruction",
            "opencode.config.mcp", "opencode.config.reference", "opencode.config.skill", "opencode.skill",
            "opencode.prompt.identity", "opencode.warming", "opencode.provider.dynamic",
            "opencode.provider.claude-agent", "opencode.provider.sap.ai.core"
        ]
        let content: [String: Any] = [
            "permissions": denies, "snapshot": false, "compaction": ["auto": false],
            "experimental": ["all_flags": false],
            "plugins": disabled.map { "-" + $0 },
            "agents": ["mailpipe": [
                "mode": "primary", "description": "Mailpipe ordinary email replies", "permissions": denies,
                "system": policy + "\n本次没有查询工具。只依据输入邮件起草。缺少回信人署名时省略署名。"
            ] as [String: Any]]
        ]
        var result = ProbeEnvironment.minimal(from: environment)
        result["HOME"] = temporaryHome.path
        result["TMPDIR"] = tmp.path
        result["XDG_CONFIG_HOME"] = configRoot.path
        result["XDG_DATA_HOME"] = directory.appendingPathComponent("data").path
        result["XDG_CACHE_HOME"] = directory.appendingPathComponent("cache").path
        result["XDG_STATE_HOME"] = directory.appendingPathComponent("state").path
        result["OPENCODE_DB"] = directory.appendingPathComponent("opencode.db").path
        result["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        result["OPENCODE_DISABLE_MODELS_FETCH"] = "1"
        result["OPENCODE_DISABLE_PROJECT_CONFIG"] = "1"
        result["OPENCODE_DISABLE_CLAUDE_CODE"] = "1"
        result["OPENCODE_DISABLE_FILEWATCHER"] = "1"
        result["OPENCODE_CONFIG_CONTENT"] = String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)

        if let home = environment["HOME"], home.hasPrefix("/") {
            let original = URL(fileURLWithPath: home)
            let userConfig = original.appendingPathComponent(".config/opencode")
            let candidates = ["opencode.json", "opencode.jsonc"].map { userConfig.appendingPathComponent($0) }
                .filter { files.fileExists(atPath: $0.path) }
            // The explicit-file option accepts one source. Never silently drop a provider override.
            guard candidates.count <= 1 else { throw MailpipeError.unsafeCapability }
            result["OPENCODE_CONFIG"] = candidates.first?.path
            let catalog = original.appendingPathComponent(".cache/opencode/models.json")
            if files.isReadableFile(atPath: catalog.path) { result["OPENCODE_MODELS_PATH"] = catalog.path }
        }
        return result
    }
}
