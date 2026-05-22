// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VideoPlayerUI",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/kingslay/KSPlayer", from: "2.3.4")
    ],
    targets: [
        .executableTarget(
            name: "VideoPlayerUI",
            dependencies: [
                .product(name: "KSPlayer", package: "KSPlayer")
            ],
            path: "Sources/VideoPlayerUI",
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
            name: "VideoPlayerUITests",
            dependencies: ["VideoPlayerUI"],
            path: "Tests/VideoPlayerUITests"
        )
    ]
)
