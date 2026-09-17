// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MatlubCrashZ",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "MatlubCrashZ", targets: ["MatlubCrashZ"])
    ],
    dependencies: [
        .package(url: "https://github.com/kstenerud/KSCrash.git", .upToNextMajor(from: "2.6.0"))
    ],
    targets: [
        .target(
            name: "MatlubCrashZ",
            dependencies: [
                .product(name: "Recording", package: "KSCrash")
            ],
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
