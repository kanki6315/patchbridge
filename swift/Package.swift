// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Patchbridge", platforms: [.macOS(.v13), .iOS(.v16)], products: [
    .library(name: "PatchbridgeCore", targets: ["PatchbridgeCore"]),
    .executable(name: "bridge-demo", targets: ["BridgeDemo"])
], targets: [.target(name: "PatchbridgeCore"), .executableTarget(name: "BridgeDemo", dependencies: ["PatchbridgeCore"], linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", Context.packageDirectory + "/Resources/BridgeInfo.plist"])]), .testTarget(name: "PatchbridgeCoreTests", dependencies: ["PatchbridgeCore"])])
