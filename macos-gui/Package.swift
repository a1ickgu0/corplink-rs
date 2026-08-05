// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "corplink-gui",
    platforms: [.macOS(.v13)],
    targets: [
        // 原生 SwiftUI 单窗口应用：仅以子进程方式驱动 corplink-rs，不链接任何 Rust 代码。
        .executableTarget(
            name: "corplink-gui",
            path: "Sources/corplink-gui"
        ),
        .testTarget(
            name: "corplink-guiTests",
            dependencies: ["corplink-gui"],
            path: "Tests/corplink-guiTests"
        ),
    ]
)
