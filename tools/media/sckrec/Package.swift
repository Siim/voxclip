// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sckrec",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "sckrec", targets: ["sckrec"])],
    targets: [
        .target(name: "RecorderSupport"),
        .executableTarget(name: "sckrec", dependencies: ["RecorderSupport"]),
        .testTarget(name: "RecorderSupportTests", dependencies: ["RecorderSupport"])
    ],
    swiftLanguageModes: [.v6]
)
