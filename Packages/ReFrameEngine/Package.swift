// swift-tools-version:5.9

import PackageDescription

// 修复引擎：Core ML 推理（Real-ESRGAN 超分、GFPGAN 人脸修复）、Vision 人脸检测、
// Core Image 合成、图片读写、AVFoundation 导出视频。与界面无关。
let package = Package(
    name: "ReFrameEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ReFrameEngine", targets: ["ReFrameEngine"]),
    ],
    dependencies: [
        .package(path: "../ReFrameCore"),
    ],
    targets: [
        .target(name: "ReFrameEngine", dependencies: ["ReFrameCore"]),
        .testTarget(name: "ReFrameEngineTests", dependencies: ["ReFrameEngine"]),
    ]
)
