// swift-tools-version: 5.9
import PackageDescription

// 三个核心模块都不依赖 UIKit/SwiftUI，所以 `swift test` 在 Windows/Linux 上也能跑。
// 渲染层（DshRender/DshShell）将来作为 Xcode target 单独存在，不进这个 Package——
// 一旦它们进来，本机就跑不了测试了，迭代速度会掉一档。这条边界要守住。
let package = Package(
    name: "dsh-swift",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "DshProtocol", targets: ["DshProtocol"]),
        .library(name: "DshSession", targets: ["DshSession"]),
        .library(name: "DshPresenter", targets: ["DshPresenter"]),
    ],
    targets: [
        // L1 传输：鉴权换发、RPC 信封、mux 帧、$events 通道
        .target(name: "DshProtocol"),

        // L2 会话窗口：snapshot/增量/live chunk/revision/rebaseline/surfaceOp
        .target(name: "DshSession", dependencies: ["DshProtocol"]),

        // L3 装配：事件窗口 → ChatNode[]
        .target(name: "DshPresenter", dependencies: ["DshSession"]),

        .testTarget(name: "DshProtocolTests", dependencies: ["DshProtocol"]),
        .testTarget(name: "DshSessionTests", dependencies: ["DshSession"]),
        .testTarget(name: "DshPresenterTests", dependencies: ["DshPresenter"]),
    ]
)
