// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HWYD",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "HWYD", targets: ["HWYDApp"]),
               .executable(name: "hwyd-pipeline", targets: ["HWYDPipeline"]),
               .executable(name: "hwyd-mcp", targets: ["HWYDMCP"])],
    dependencies: [.package(path: "Packages/HWYDCore"), .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"), .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")],
    targets: [
        .target(name: "HWYDRealtime", publicHeadersPath: "include"),
        .executableTarget(name: "HWYDApp", dependencies: ["HWYDCore", "HWYDRealtime"]),
        .executableTarget(name: "HWYDPipeline", dependencies: ["HWYDCore", .product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "HWYDMCP", dependencies: ["HWYDCore", .product(name: "MCP", package: "swift-sdk")], resources: [.copy("tools.json")]),
        .testTarget(name: "HWYDPipelineTests", dependencies: ["HWYDPipeline", "HWYDCore"])
    ],
    swiftLanguageModes: [.v6]
)
