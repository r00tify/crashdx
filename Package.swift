// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "crashdx",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrashDXCore", targets: ["CrashDXCore"]),
        .executable(name: "crashdx", targets: ["crashdx"]),
        .executable(name: "crashdx-mcp", targets: ["crashdx-mcp"]),
    ],
    dependencies: [
        // Only the `crashdx-mcp` TARGET imports this — `CrashDXCore` and `crashdx` import
        // nothing but Foundation. Note that SwiftPM resolves dependencies per *package*,
        // not per product, so a consumer of `CrashDXCore` still resolves this graph.
        //
        // Ranged rather than `exact:` deliberately: an exact pin is unsatisfiable for any
        // consumer that also depends on swift-sdk at another version, and there is no way
        // for them to override it. Reproducibility comes from the committed
        // Package.resolved, which is what a lockfile is for. `upToNextMinor` is the right
        // range for a 0.x package, where minor bumps carry the breaking changes.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
    ],
    targets: [
        .target(name: "CrashDXCore"),
        .executableTarget(name: "crashdx", dependencies: ["CrashDXCore"]),
        .executableTarget(
            name: "crashdx-mcp",
            dependencies: [
                "CrashDXCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(
            name: "CrashDXCoreTests",
            dependencies: ["CrashDXCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
