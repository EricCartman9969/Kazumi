// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KazumiCore",
    platforms: [.tvOS(.v17), .macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "KazumiCore", targets: ["KazumiCore"]),
        .executable(name: "kazumi-cli", targets: ["kazumi-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tid-kijyun/Kanna.git", from: "5.3.0"),
    ],
    targets: [
        .target(name: "KazumiCore", dependencies: ["Kanna"]),
        .executableTarget(name: "kazumi-cli", dependencies: ["KazumiCore"]),
        .testTarget(name: "KazumiCoreTests", dependencies: ["KazumiCore"]),
    ]
)
