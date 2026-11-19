// swift-tools-version: 6.0
import PackageDescription

// Linux has no Apple SQLite3 overlay. The module map is unused on macOS.
#if os(Linux)
let linuxSQLite: [Target.Dependency] = ["CSQLite"]
#else
let linuxSQLite: [Target.Dependency] = []
#endif

var packageTargets: [Target] = [
        .target(name: "MailpipeCharset", path: "Packages/MailpipeCharset", sources: ["src/mailpipe_iconv.c"], publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("iconv", .when(platforms: [.macOS]))]),
        .target(name: "MailpipeCore", dependencies: ["MailpipeCharset"], path: "Packages/MailpipeCore/Sources"),
        .target(name: "HarnessAdapters", dependencies: ["MailpipeCore"], path: "Packages/HarnessAdapters/Sources", resources: [.copy("Resources")]),
        .target(name: "MailBridge", dependencies: ["MailpipeCore", "HarnessAdapters"], path: "Packages/MailBridge/Sources"),
        .target(name: "MailpipeRuntime", dependencies: ["MailpipeCore", "HarnessAdapters"] + linuxSQLite, path: "Packages/MailpipeRuntime/Sources"),
        .executableTarget(name: "MailpipeM0", dependencies: ["HarnessAdapters", "MailpipeRuntime", "MailBridge"], path: "Tools/MailpipeM0"),
        .testTarget(name: "MailpipeCoreTests", dependencies: ["MailpipeCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "HarnessAdaptersTests", dependencies: ["HarnessAdapters", "MailpipeCore"]),
        .testTarget(name: "MailpipeRuntimeTests", dependencies: ["MailpipeRuntime", "HarnessAdapters", "MailpipeCore"]),
        .testTarget(name: "MailBridgeTests", dependencies: ["MailBridge", "MailpipeCore", "HarnessAdapters"])
]

#if os(Linux)
packageTargets.append(.systemLibrary(name: "CSQLite", path: "Packages/CSQLite"))
#endif

let package = Package(
    name: "Mailpipe",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MailpipeCore", targets: ["MailpipeCore"]),
        .library(name: "HarnessAdapters", targets: ["HarnessAdapters"]),
        .library(name: "MailBridge", targets: ["MailBridge"]),
        .library(name: "MailpipeRuntime", targets: ["MailpipeRuntime"]),
        .executable(name: "mailpipe-m0", targets: ["MailpipeM0"])
    ],
    targets: packageTargets,
    swiftLanguageModes: [.v6]
)
