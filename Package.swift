// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "JoeCore", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "JoeCore", targets: ["JoeCore"])],
    targets: [.target(name: "JoeCore"), .testTarget(name: "JoeCoreTests", dependencies: ["JoeCore"], resources: [.copy("Fixtures")])])
