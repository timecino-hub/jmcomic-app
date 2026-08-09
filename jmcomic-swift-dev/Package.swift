// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JMComicDev",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "JMComicDev", path: "Sources/JMComic")
    ]
)
