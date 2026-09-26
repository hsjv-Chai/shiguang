// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "PhotoArchive", platforms: [.macOS(.v14)], products: [.executable(name: "PhotoArchive", targets: ["PhotoArchive"]), .library(name: "PhotoCore", targets: ["PhotoCore"])], targets: [.systemLibrary(name: "CSQLite"), .target(name: "PhotoCore", dependencies: ["CSQLite"]), .executableTarget(name: "PhotoArchive", dependencies: ["PhotoCore"]), .executableTarget(name: "PhotoCoreChecks", dependencies: ["PhotoCore"], path: "Tests/PhotoCoreTests", resources: [.copy("Fixtures")])])
