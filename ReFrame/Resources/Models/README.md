# AI 模型

本目录在 CI 构建时自动生成，不提交到仓库：

1. `scripts/convert_models.py` 下载官方权重（校验 SHA-256），转换为 Core ML `.mlpackage`，并在 macOS 上与 PyTorch 输出对比验证；
2. `xcrun coremlcompiler compile` 编译成 `.mlmodelc`，放到这里，随 App 一起打包。

| 文件 | 模型 | 许可 |
| --- | --- | --- |
| `RealESRGANx4.mlmodelc` | Real-ESRGAN x4plus（超分 ×4） | BSD-3-Clause |
| `GFPGANv14.mlmodelc` | GFPGAN v1.4（人脸修复） | Apache-2.0 |

本地自己构建时可以运行：

```bash
python3 scripts/convert_models.py --out build/models --validate
for m in build/models/*.mlpackage; do xcrun coremlcompiler compile "$m" ReFrame/Resources/Models/; done
```

没有模型时 App 仍可运行，会退化为普通放大。
