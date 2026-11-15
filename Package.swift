// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Nimmersatt",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "NimmersattShared"),
        .executableTarget(name: "Nimmersatt", dependencies: ["NimmersattShared"]),
        .executableTarget(name: "NimmersattHelper", dependencies: ["NimmersattShared"]),
    ]
)
