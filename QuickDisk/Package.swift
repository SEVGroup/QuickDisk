// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "QuickDisk", platforms: [.macOS(.v14)], products: [.executable(name: "QuickDisk", targets: ["QuickDisk"])], targets: [.executableTarget(name: "QuickDisk")])
