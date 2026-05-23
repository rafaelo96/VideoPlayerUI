// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rift",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/kingslay/KSPlayer", from: "2.3.4")
    ],
    targets: [
        .executableTarget(
            name: "Rift",
            dependencies: [
                .product(name: "KSPlayer", package: "KSPlayer")
            ],
            path: "Sources/Rift",
            resources: [
                .copy("Resources"),
                .copy("FramePlusMEMC.metal")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .testTarget(
            name: "RiftTests",
            dependencies: ["Rift"],
            path: "Tests/RiftTests"
        )
    ]
)
