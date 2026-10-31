// swift-tools-version:5.9
import PackageDescription

// Touch Sample bridge: MPC Touch (CoreMIDI) <-> emulated MPC Sample (WebSocket).
// Command Line Tools only; no external dependencies. A later TouchSampleApp
// executable target (AppKit + WKWebView) will depend on TouchIO and BridgeCore.
let package = Package(
    name: "TouchSample",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .library(name: "TouchIO", targets: ["TouchIO"]),
        .executable(name: "touch-capture", targets: ["touch-capture"]),
        .executable(name: "touch-bridge", targets: ["touch-bridge"]),
    ],
    targets: [
        // C: CoreMIDI find/connect/send for the MPC Touch (adapted from PaperCut, attributed in the source).
        .target(
            name: "TouchMIDI",
            path: "Sources/TouchMIDI",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreMIDI"), .linkedFramework("CoreFoundation")]
        ),
        // Pure logic: profile/mapping loading, Touch->Sample and Sample->Touch rules. No CoreMIDI, no network.
        .target(name: "BridgeCore", path: "Sources/BridgeCore"),
        // I/O: CoreMIDI wrapper, paced output, owner check + flock, WebSocket client, BridgeRunner.
        .target(
            name: "TouchIO",
            dependencies: ["TouchMIDI", "BridgeCore"],
            path: "Sources/TouchIO",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "TouchSampleApp", dependencies: ["TouchIO"], path: "Sources/TouchSampleApp", linkerSettings: [.linkedFramework("WebKit")]),
        .executableTarget(
            name: "touch-capture",
            dependencies: ["TouchIO", "BridgeCore", "TouchMIDI"],
            path: "Sources/touch-capture"
        ),
        .executableTarget(
            name: "touch-bridge",
            dependencies: ["TouchIO", "BridgeCore", "TouchMIDI"],
            path: "Sources/touch-bridge"
        ),
    ]
)
