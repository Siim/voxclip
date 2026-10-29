// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoxClip",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "VoxClip", targets: ["VoxClip"]),
        .executable(name: "voxclip-cli", targets: ["voxclip-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.19.2"),
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .target(name: "VoxClipCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "VoxClipMedia", dependencies: ["VoxClipCore", "whisper", .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "VoxClip", dependencies: ["VoxClipCore", "VoxClipMedia"], exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/VoxClip/Info.plist"])]
        ),
        .executableTarget(
            name: "voxclip-cli",
            dependencies: ["VoxClipCore", "VoxClipMedia", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "Sources/VoxClip/Info.plist"])]
        ),
        .testTarget(name: "VoxClipCoreTests", dependencies: ["VoxClipCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "VoxClipMediaTests", dependencies: ["VoxClipMedia", "voxclip-cli"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
