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
        .package(url: "https://github.com/supabase-community/supabase-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", .upToNextMajor(from: "10.0.0"))
    ],
    targets: [
        .target(
            name: "VibeWatch",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk")
            ],
            path: "VibeWatchApp"
        )
    ]
)
