// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "Janela",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "Janela", targets: ["Janela"])],
  targets: [
    .target(name: "JanelaCamera", path: "Sources/JanelaCamera"),
    .target(name: "JanelaCore", dependencies: ["JanelaCamera"], path: "Sources/JanelaCore"),
    .executableTarget(name: "Janela", dependencies: ["JanelaCore", "JanelaCamera"], path: "Sources/Janela"),
    .executableTarget(name: "janela-render", dependencies: ["JanelaCore", "JanelaCamera"], path: "Sources/janela-render"),
    .executableTarget(name: "camera-probe", dependencies: ["JanelaCamera"], path: "Sources/camera-probe"),
  ]
)
