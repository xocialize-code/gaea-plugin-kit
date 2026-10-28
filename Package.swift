// swift-tools-version: 6.2
import PackageDescription

// GaeaPluginKit turns MLXEngine model packages into a Gaea plugin worker: a process that speaks
// the Gaea Plugin Protocol (GPP v1, xocialize/gaea spec/GPP-1.md) on stdin and stdout, and writes
// its own manifest.json at build time.
//
// - GaeaProtocol is MLX-free: JSON values, the manifest's types and GPP's vocabulary. The Gaea host
//   links no MLX, so it can share these.
// - GaeaPluginKit is the worker: the protocol loop over MLXServeEngine(workerBudget:), and the
//   manifest generator (`<worker> --manifest`).
// - gaea-plugin-check is a tiny host a plugin's build runs against its signed bundle.
let package = Package(
    name: "gaea-plugin-kit",
    platforms: [.macOS(.v26)], // mlx-engine-swift 0.72.0's MLXToolKit requires macOS 26
    products: [
        .library(name: "GaeaPluginKit", targets: ["GaeaPluginKit"]),
        .library(name: "GaeaProtocol", targets: ["GaeaProtocol"]),
        // A tiny MLX-free host: verify a built .gaeaplugin, launch it under launchRequirement, drive GPP.
        .executable(name: "gaea-plugin-check", targets: ["gaea-plugin-check"]),
    ],
    dependencies: [
        .package(url: "https://github.com/xocialize/mlx-engine-swift.git", from: "0.72.0"),
    ],
    targets: [
        .target(
            name: "GaeaProtocol",
            dependencies: [.product(name: "MLXToolKit", package: "mlx-engine-swift")]
        ),
        .target(
            name: "GaeaPluginKit",
            dependencies: [
                "GaeaProtocol",
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
                .product(name: "MLXHubMetadata", package: "mlx-engine-swift"),
            ]
        ),
        // Top-level script code: Swift 5 mode spares it main-actor ceremony.
        .executableTarget(name: "gaea-plugin-check", dependencies: ["GaeaProtocol"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "GaeaPluginKitTests",
            dependencies: [
                "GaeaPluginKit", "GaeaProtocol",
                .product(name: "MLXToolKit", package: "mlx-engine-swift"),
                .product(name: "MLXServeCore", package: "mlx-engine-swift"),
                .product(name: "MLXHubMetadata", package: "mlx-engine-swift"),
            ]
        ),
    ]
)
