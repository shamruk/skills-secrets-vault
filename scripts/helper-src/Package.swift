// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "secrets-vault-helper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "secrets-vault-helper", path: "Sources")
    ]
)
