# ReFrame

给 Apple 芯片 Mac 用的**低清人物图片修复 + 循环播放**工具。专门针对从老视频里抽出来的 240×135 小图：
本地 AI 放大到 1920×1080，修复人脸，去掉摄像头时间水印，原图一律不改；修好的图可以挑几张或整个文件夹循环播放，并导出成视频。

需求与设计见 [docs/PRD.md](docs/PRD.md)。

## 下载安装

1. 到仓库的 **Releases → 最新构建（latest-build）** 下载 `ReFrame-*.dmg`（或 Actions → Build DMG 最新一次成功运行里的 `ReFrame-dmg`）。
2. 打开 DMG，把 ReFrame 拖进“应用程序”。
3. **第一次打开**（没有付费开发者签名，只需一次）：在“应用程序”里右键 ReFrame → 打开 → 再点“打开”；
   macOS 15 起如果没有“打开”按钮：系统设置 → 隐私与安全性 → 下方点“仍要打开”；或在终端执行 `xattr -cr /Applications/ReFrame.app`。

要求：macOS 14 及以上，Apple 芯片（M1～M4）。8GB 内存可用。

## 使用

1. **导入**：打开图片 / 文件夹，或直接拖进窗口。按文件名里的数字自然排序（frame_2 在 frame_10 前面）。
   如果这批图片是倒着的，在打开对话框底部勾选“这批图片是倒着的”（或在右侧“画面方向”里打开），修复后自动旋转 180° 放正；
   也支持顺时针 / 逆时针 90° 和左右镜像。时间水印选“原样保留”时，文字仍正着放在右下角。
2. **输出文件夹**：默认是原文件夹旁边的“<文件夹名>_修复”，可在右侧面板修改。原图只读，输出路径若会覆盖原图会被拒绝。
3. **试修**：选一张图点“试修当前图”（⌘T），在“对比”页左右拖动分隔线比较原图和修复后。
4. **批量修复**：点“修复全部”（⌘R）。可暂停 / 继续 / 取消；已修好的会自动跳过，中断后再点一次就能接着修。
   处理期间电脑不会自动睡眠；电脑过热时会自动放慢。
5. **播放**：切到“播放”页，选择范围（选中的图 / 全部素材 / 输出文件夹）和画面（修复后 / 原图 / 并排对比），
   单次 / 循环 / 往返，帧率 1～60。空格播放暂停，← → 逐帧，F 或双击全屏，Esc 退出全屏。
6. **导出视频**：在播放页点胶片图标，选择帧率、正放 / 重复 / 往返、HEVC 或 H.264、画质。

## 修复流程

```
原始帧 240×135
 → 时间水印：自动检测位置，用整批画面合成的背景底图补上（或原样保留）
 → 去色偏 / 拉开明暗 / 偏暗提亮（参数由整批画面统一估计，每帧一致，播放不闪烁）
 → Real-ESRGAN ×4（Core ML，960×540）
 → GFPGAN v1.4 人脸修复（Vision 找脸，正向 + 倒置各找一次；FFHQ 模板对齐；颜色匹配；柔和回贴；强度可调）
 → Lanczos ×2 + 锐化（1920×1080）
 → 按“画面方向”放正（AI 按原方向处理，写文件时再转，不损失画质）
 → 写入输出文件夹（先写临时文件再移动）
```

每次批处理在输出文件夹写一份 `reframe-manifest.json`，记录参数、水印位置、色彩参数和每张图的结果。

## 开发

工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成：

```bash
brew install xcodegen
python3 scripts/convert_models.py --out build/models --validate
for m in build/models/*.mlpackage; do xcrun coremlcompiler compile "$m" ReFrame/Resources/Models/; done
xcodegen generate
open ReFrame.xcodeproj
```

- `ReFrame/`：应用（SwiftUI）。`App/` 状态与播放器，`UI/` 界面。
- `Packages/ReFrameCore/`：纯逻辑（自然排序、色彩校正、时间水印检测、背景底图、人脸对齐几何、播放序列、输出命名与原图保护），`swift test --package-path Packages/ReFrameCore`。
- `Packages/ReFrameEngine/`：Core ML 推理、Vision、Core Image 合成、图片读写、视频导出。
  设置 `REFRAME_MODELS_DIR` 后 `swift test` 会用真实模型跑端到端测试。
- `scripts/convert_models.py`：下载官方权重（SHA-256 校验、安全加载），在脚本内重新实现网络结构，转换为 Core ML，并在 macOS 上与 PyTorch 对比验证。
- CI：`.github/workflows/build-dmg.yml` 在 macOS 上转换模型、测试、编译、打包 DMG；默认分支自动更新“最新构建”预发布版，推送 `v*` 标签时发布正式 Release。

## 许可与致谢

- 超分：[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)（BSD-3-Clause，© Xintao Wang）
- 人脸修复：[GFPGAN](https://github.com/TencentARC/GFPGAN)（Apache-2.0，© Tencent ARC）
- 工程结构与打包流程参考姊妹项目 [Vo Player](https://github.com/linlea666/vo)
