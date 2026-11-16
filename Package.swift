// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mailpipe",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MailpipeCore", targets: ["MailpipeCore"]),
        .library(name: "HarnessAdapters", targets: ["HarnessAdapters"]),
        .library(name: "MailBridge", targets: ["MailBridge"]),
        .executable(name: "mailpipe-m0", targets: ["MailpipeM0"])
    ],
    targets: [
        .target(name: "MailpipeCore", path: "Packages/MailpipeCore/Sources"),
        .target(name: "HarnessAdapters", dependencies: ["MailpipeCore"], path: "Packages/HarnessAdapters/Sources", resources: [.copy("Resources")]),
        .target(name: "MailBridge", dependencies: ["MailpipeCore"], path: "Packages/MailBridge/Sources"),
        .executableTarget(name: "MailpipeM0", dependencies: ["HarnessAdapters"], path: "Tools/MailpipeM0"),
        .testTarget(name: "MailpipeCoreTests", dependencies: ["MailpipeCore"]),
        .testTarget(name: "HarnessAdaptersTests", dependencies: ["HarnessAdapters", "MailpipeCore"]),
        .testTarget(name: "MailBridgeTests", dependencies: ["MailBridge", "MailpipeCore"])
    ],
    swiftLanguageModes: [.v6]
)
