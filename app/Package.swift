// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Monty",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "Monty", path: "Sources/Monty"),
    ]
)
