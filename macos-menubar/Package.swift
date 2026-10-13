// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CorpLinkMenuBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "corplink-menubar", targets: ["CorpLinkMenuBar"])],
    targets: [.executableTarget(name: "CorpLinkMenuBar")]
)
