// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Swapless",
    platforms: [.macOS(.v27)],
    products: [
        .executable(name: "Swapless", targets: ["Swapless"]),
        .executable(name: "swapless-leak-helper", targets: ["swapless-leak-helper"]),
        .executable(name: "swapless-rig", targets: ["swapless-rig"]),
    ],
    targets: [
        // The only place private symbols are touched (spec § A).
        .target(name: "CSwaplessProc"),
        .target(
            name: "SwaplessCore",
            dependencies: ["CSwaplessProc"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "Swapless", dependencies: ["SwaplessCore"]),
        .executableTarget(name: "swapless-leak-helper"),
        .executableTarget(name: "swapless-rig", dependencies: ["SwaplessCore"]),
        .testTarget(
            name: "SwaplessCoreTests",
            dependencies: ["SwaplessCore", "CSwaplessProc"],
            resources: [.copy("Fixtures")]
        ),
        // The app's AppKit glue (menu reconcile), on real NSMenus that are never shown.
        .testTarget(name: "SwaplessAppTests", dependencies: ["Swapless"]),
    ],
    swiftLanguageModes: [.v6]
)
