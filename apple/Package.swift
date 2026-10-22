// swift-tools-version: 6.1
import PackageDescription
import Foundation

let logseqNativeLinkInputs = ProcessInfo.processInfo.environment["LOGSEQ_NATIVE_LINK_INPUTS"]?
    .split(separator: ":")
    .map(String.init) ?? []
let logseqSimulatorEntitlements = ProcessInfo.processInfo.environment["LOGSEQ_SIMULATOR_ENTITLEMENTS"]
// Ctypes resolves these by name, so the static linker cannot see their uses.
// Retain and export them even when a Release executable strips unused code.
let logseqRuntimeExports = [
    "_logseq_https_send", "_logseq_https_upload_file", "_logseq_crypto_call", "_logseq_metric_log", "_logseq_graph_import_progress"
]
// Only the C entry points resolved by OCaml need dynamic lookup. Exporting the
// entire executable retains otherwise unused code and a large dyld export trie.
let logseqRuntimeExportFlags = logseqRuntimeExports.flatMap {
    ["-Xlinker", "-u", "-Xlinker", $0, "-Xlinker", "-exported_symbol", "-Xlinker", $0]
}
let logseqLinkerSettings: [LinkerSetting] = logseqNativeLinkInputs.isEmpty ? [] : [
    .unsafeFlags(logseqNativeLinkInputs + logseqRuntimeExportFlags, .when(platforms: [.iOS])),
    .linkedFramework("Foundation", .when(platforms: [.iOS])),
    .linkedFramework("Security", .when(platforms: [.iOS])),
    .linkedLibrary("sqlite3", .when(platforms: [.iOS])),
    .linkedLibrary("ffi", .when(platforms: [.iOS]))
]
let logseqCoreSwiftSettings: [SwiftSetting] = logseqNativeLinkInputs.isEmpty ? [] : [
    .define("LOGSEQ_CORE", .when(platforms: [.iOS]))
]
let logseqShellLinkerSettings: [LinkerSetting] = logseqSimulatorEntitlements.map {
    [.unsafeFlags([
        "-Xlinker", "-sectcreate",
        "-Xlinker", "__TEXT", "-Xlinker", "__entitlements",
        "-Xlinker", $0
    ], .when(platforms: [.iOS]))]
} ?? []

let package = Package(
    name: "logseq",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "LogseqShell", targets: ["LogseqShell"]),
        .library(name: "Logseq", type: .static, targets: ["Logseq"]),
        .library(name: "LogseqModel", type: .dynamic, targets: ["LogseqModel"]),
    ],
    dependencies: [
        .package(url: "ssh://git@github.com/logseq/lui.git", revision: "eea10c7bf99ad1a2a40cc84b1c9657a764073d72"),
        .package(url: "https://github.com/gonzalezreal/swiftui-math", from: "0.1.0"),
        .package(url: "https://github.com/appstefan/highlightswift.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "LogseqShell",
            dependencies: ["Logseq"],
            path: "App/Sources",
            linkerSettings: logseqShellLinkerSettings
        ),
        .target(name: "Logseq", dependencies: [
            "LogseqModel",
            .product(name: "LUIAppleBackendStatic", package: "lui"),
            .product(
                name: "SwiftUIMath",
                package: "swiftui-math",
                condition: .when(platforms: [.iOS])
            ),
            .product(
                name: "HighlightSwift",
                package: "highlightswift",
                condition: .when(platforms: [.iOS])
            )
        ],
        resources: [.process("Resources")],
        linkerSettings: logseqLinkerSettings),
        .testTarget(
            name: "LogseqTests",
            dependencies: ["Logseq", .product(name: "LUIAppleBackendStatic", package: "lui")],
            resources: [.process("Resources")]
        ),
        .target(name: "LogseqModel", dependencies: [
            "LogseqCoreABI"
        ], resources: [.process("Resources")],
        swiftSettings: logseqCoreSwiftSettings),
        .target(
            name: "LogseqCoreABI",
            path: "Sources/LogseqCoreABI",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .testTarget(
            name: "LogseqModelTests",
            dependencies: ["LogseqModel"],
            resources: [.process("Resources")]
        ),
    ]
)
