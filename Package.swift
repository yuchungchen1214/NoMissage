// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoMissage",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NoMissage", targets: ["NoMissage"])],
    targets: [.executableTarget(name: "NoMissage", path: "Sources/MessengerCollector")]
)
