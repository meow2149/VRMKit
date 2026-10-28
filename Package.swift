// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VRMKit",
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "VRMKit", targets: ["VRMKit"]),
        .library(name: "VRMRealityKit", targets: ["VRMRealityKit"])
    ],
    targets: [
        .target(name: "VRMKit"),
        .target(name: "VRMRealityKit", dependencies: ["VRMKit"], resources: [.copy("Toon.metal")])
    ]
)
