// swift-tools-version:5.9

import PackageDescription

// 与界面、模型推理无关的纯逻辑：排序、像素处理、色彩校正、时间水印检测、背景底图、
// 人脸对齐几何、播放序列、输出命名。只依赖 Foundation，CI 里用 `swift test` 快速测试。
let package = Package(
    name: "ReFrameCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReFrameCore", targets: ["ReFrameCore"]),
    ],
    targets: [
        .target(name: "ReFrameCore"),
        .testTarget(name: "ReFrameCoreTests", dependencies: ["ReFrameCore"]),
    ]
)
