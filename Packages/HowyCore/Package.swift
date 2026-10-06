// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HowyCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "HowyCore", targets: ["HowyCore"]),
    ],
    targets: [
        .target(name: "HowyCore"),
        .testTarget(name: "HowyCoreTests", dependencies: ["HowyCore"]),
    ]
)
