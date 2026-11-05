// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PhotoSelect", platforms: [.macOS(.v13)], products: [
    .executable(name: "PhotoSelect", targets: ["PhotoSelect"])
], targets: [
    .executableTarget(name: "PhotoSelect"),
    .testTarget(name: "PhotoSelectTests", dependencies: ["PhotoSelect"])
])
