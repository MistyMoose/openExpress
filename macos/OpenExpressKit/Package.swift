// swift-tools-version: 6.2
// openExpressKit: the engine client, its models and the view models of the macOS app.
// GPL-3.0-or-later, as the rest of openExpress.
import PackageDescription

let package = Package(
    name: "OpenExpressKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OpenExpressKit", targets: ["OpenExpressKit"]),
    ],
    targets: [
        .target(
            name: "OpenExpressKit",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "OpenExpressKitTests",
            dependencies: ["OpenExpressKit"]
        ),
    ]
)
