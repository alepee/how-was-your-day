// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "HWYDCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "HWYDCore", targets: ["HWYDCore"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1")],
    targets: [
        .target(name: "HWYDCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "HWYDCoreTests", dependencies: ["HWYDCore"])
    ],
    swiftLanguageModes: [.v6]
)
