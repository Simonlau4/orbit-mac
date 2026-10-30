// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OrbitCore", targets: ["OrbitCore"]), .executable(name: "Orbit", targets: ["Orbit"]), .executable(name: "OrbitFanAgent", targets: ["OrbitFanAgent"]), .executable(name: "OrbitUpdateAgent", targets: ["OrbitUpdateAgent"])],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "OrbitCore", dependencies: ["CArchive"]),
        .executableTarget(name: "Orbit", dependencies: ["OrbitCore"], resources: [.copy("Assets")]),
        .executableTarget(name: "OrbitFanAgent", dependencies: ["OrbitCore"]),
        .executableTarget(name: "OrbitUpdateAgent", dependencies: ["OrbitCore"]),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"]),
        .testTarget(name: "OrbitAppTests", dependencies: ["Orbit", "OrbitCore"])
    ]
)
