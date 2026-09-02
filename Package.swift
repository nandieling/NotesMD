// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotesMD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NotesMD", path: "Sources/NotesMD")
    ]
)
