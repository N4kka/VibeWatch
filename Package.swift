// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeWatch",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "VibeWatch",
            targets: ["VibeWatch"])
    ],
    dependencies: [
        .package(url: "https://github.com/supabase-community/supabase-swift.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "VibeWatch",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift")
            ],
            path: "VibeWatch"
        )
    ]
)
