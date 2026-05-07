// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeWatchTools",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "VibeWatchTools",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Supabase", package: "supabase-swift")
            ]
        )
    ]
)
