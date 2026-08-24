// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Roost",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Roost",
            path: "Sources/Roost"
        )
    ]
)
