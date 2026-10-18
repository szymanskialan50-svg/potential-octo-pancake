// swift-tools-version:5.9
import PackageDescription

// Lokalna kopia YouTubeKit (https://github.com/alexeichhorn/YouTubeKit), wbudowana w projekt,
// żeby build na GitHubie nie zależał od niczego z zewnątrz.
let package = Package(
    name: "YouTubeKit",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "YouTubeKit", targets: ["YouTubeKit"]),
    ],
    targets: [
        .target(
            name: "YouTubeKit",
            dependencies: [],
            resources: [.process("Resources")]),
    ]
)
