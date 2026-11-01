#!/usr/bin/env python3
"""把修复用的 PyTorch 模型转换成 Core ML（.mlpackage），供 ReFrame 在 Mac 上本地运行。

转换的模型：
  1. Real-ESRGAN x4plus（BSD-3-Clause，© Xintao Wang）—— 通用超分 ×4
     固定输入 256×144（宽×高）。原始帧 240×135 一次推理即可，更大的图由 App 分块处理。
  2. GFPGAN v1.4（Apache-2.0，© Tencent ARC）—— 人脸修复，输入/输出 512×512 对齐人脸

网络结构在本文件内重新实现（与官方 clean 版本参数名一一对应，可严格加载权重），
不需要安装 basicsr / gfpgan，也不会执行下载来的任何代码：权重用 `weights_only=True` 安全读取。

StyleGAN2 的"调制卷积"在官方实现里每次推理都会生成新的卷积核，Core ML 不擅长这种动态权重。
这里改写成数学上等价的形式（batch=1）：
    out = conv(x * s, W) * demod,   demod = rsqrt((s²) @ sum_k(W²)ᵀ + eps)
卷积核保持常量，转换后可以跑在神经网络引擎上。

用法：
    python3 scripts/convert_models.py --out build/models [--weights-dir build/weights] [--validate]

--validate 只在 macOS 上可用：用 Core ML 实际推理一次，与 PyTorch 输出对比（PSNR），差距过大则失败。
"""

import argparse
import hashlib
import math
import platform
import sys
import urllib.request
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.nn import functional as F

WEIGHTS = {
    "realesrgan_x4plus": (
        "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1",
    ),
    "gfpgan_v1_4": (
        "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth",
        "e2cd4703ab14f4d01fd1383a8a8b266f9a5833dacee8e6a79d3bf21a1b6be5ad",
    ),
}

SR_TILE_W, SR_TILE_H = 256, 144
FACE_SIZE = 512


# ----------------------------------------------------------------------------
# 下载与安全加载
# ----------------------------------------------------------------------------

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(name: str, weights_dir: Path) -> Path:
    url, digest = WEIGHTS[name]
    weights_dir.mkdir(parents=True, exist_ok=True)
    path = weights_dir / url.rsplit("/", 1)[1]
    if not path.exists() or sha256(path) != digest:
        print(f"下载 {url}")
        tmp = path.with_suffix(".part")
        urllib.request.urlretrieve(url, tmp)
        tmp.rename(path)
    actual = sha256(path)
    if actual != digest:
        raise SystemExit(f"{path.name} 校验失败：{actual} != {digest}")
    return path


def load_state(path: Path) -> dict:
    ckpt = torch.load(path, map_location="cpu", weights_only=True)
    return ckpt.get("params_ema", ckpt.get("params", ckpt))


# ----------------------------------------------------------------------------
# Real-ESRGAN (RRDBNet)
# ----------------------------------------------------------------------------

class ResidualDenseBlock(nn.Module):
    def __init__(self, num_feat=64, num_grow_ch=32):
        super().__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        return x5 * 0.2 + x


class RRDB(nn.Module):
    def __init__(self, num_feat, num_grow_ch=32):
        super().__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        out = self.rdb3(self.rdb2(self.rdb1(x)))
        return out * 0.2 + x


class RRDBNet(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_block=23, num_grow_ch=32):
        super().__init__()
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = nn.Sequential(*[RRDB(num_feat, num_grow_ch) for _ in range(num_block)])
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)
        self.lrelu = nn.LeakyReLU(negative_slope=0.2)

    def forward(self, x):
        feat = self.conv_first(x)
        feat = feat + self.conv_body(self.body(feat))
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode="nearest")))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode="nearest")))
        return self.conv_last(self.lrelu(self.conv_hr(feat)))


class SRWrapper(nn.Module):
    """输入 0...1 的 RGB，输出 0...255 的 RGB（Core ML 图像输出需要 0...255）。"""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.clamp(self.net(x), 0.0, 1.0) * 255.0


# ----------------------------------------------------------------------------
# GFPGAN v1.4 (GFPGANv1Clean, out_size=512, channel_multiplier=2, different_w, sft_half)
# 参数名与官方 gfpgan/archs/gfpganv1_clean_arch.py、stylegan2_clean_arch.py 一致
# ----------------------------------------------------------------------------

class NormStyleCode(nn.Module):
    def forward(self, x):
        return x * torch.rsqrt(torch.mean(x ** 2, dim=1, keepdim=True) + 1e-8)


class ModulatedConv2d(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size, num_style_feat, demodulate=True,
                 sample_mode=None, eps=1e-8):
        super().__init__()
        self.in_channels = in_channels
        self.out_channels = out_channels
        self.kernel_size = kernel_size
        self.demodulate = demodulate
        self.sample_mode = sample_mode
        self.eps = eps
        self.modulation = nn.Linear(num_style_feat, in_channels, bias=True)
        self.weight = nn.Parameter(torch.zeros(1, out_channels, in_channels, kernel_size, kernel_size))
        self.padding = kernel_size // 2

    def forward(self, x, style):
        # batch = 1：调制作用在输入通道上，卷积核保持常量（与官方实现数学等价）
        s = self.modulation(style)                       # (1, c_in)
        w = self.weight[0]                               # (c_out, c_in, k, k)
        if self.sample_mode == "upsample":
            x = F.interpolate(x, scale_factor=2, mode="bilinear", align_corners=False)
        elif self.sample_mode == "downsample":
            x = F.interpolate(x, scale_factor=0.5, mode="bilinear", align_corners=False)
        out = F.conv2d(x * s.view(1, -1, 1, 1), w, padding=self.padding)
        if self.demodulate:
            w_sq = w.pow(2).sum(dim=(2, 3))              # (c_out, c_in)
            demod = torch.rsqrt(torch.matmul(s * s, w_sq.t()) + self.eps)  # (1, c_out)
            out = out * demod.view(1, -1, 1, 1)
        return out


class StyleConv(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size, num_style_feat, demodulate=True, sample_mode=None):
        super().__init__()
        self.modulated_conv = ModulatedConv2d(in_channels, out_channels, kernel_size, num_style_feat,
                                              demodulate=demodulate, sample_mode=sample_mode)
        self.weight = nn.Parameter(torch.zeros(1))
        self.bias = nn.Parameter(torch.zeros(1, out_channels, 1, 1))
        self.activate = nn.LeakyReLU(negative_slope=0.2)

    def forward(self, x, style, noise):
        out = self.modulated_conv(x, style) * 2 ** 0.5
        out = out + self.weight * noise
        out = out + self.bias
        return self.activate(out)


class ToRGB(nn.Module):
    def __init__(self, in_channels, num_style_feat, upsample=True):
        super().__init__()
        self.upsample = upsample
        self.modulated_conv = ModulatedConv2d(in_channels, 3, 1, num_style_feat, demodulate=False)
        self.bias = nn.Parameter(torch.zeros(1, 3, 1, 1))

    def forward(self, x, style, skip=None):
        out = self.modulated_conv(x, style) + self.bias
        if skip is not None:
            if self.upsample:
                skip = F.interpolate(skip, scale_factor=2, mode="bilinear", align_corners=False)
            out = out + skip
        return out


class ConstantInput(nn.Module):
    def __init__(self, num_channel, size):
        super().__init__()
        self.weight = nn.Parameter(torch.zeros(1, num_channel, size, size))

    def forward(self):
        return self.weight


class StyleGAN2GeneratorCSFT(nn.Module):
    def __init__(self, out_size, num_style_feat=512, num_mlp=8, channel_multiplier=2, narrow=1, sft_half=True):
        super().__init__()
        self.num_style_feat = num_style_feat
        layers = [NormStyleCode()]
        for _ in range(num_mlp):
            layers.extend([nn.Linear(num_style_feat, num_style_feat, bias=True), nn.LeakyReLU(0.2)])
        self.style_mlp = nn.Sequential(*layers)  # 本模型 input_is_latent=True，推理时不用，仅为严格加载权重

        channels = {
            "4": int(512 * narrow), "8": int(512 * narrow), "16": int(512 * narrow), "32": int(512 * narrow),
            "64": int(256 * channel_multiplier * narrow), "128": int(128 * channel_multiplier * narrow),
            "256": int(64 * channel_multiplier * narrow), "512": int(32 * channel_multiplier * narrow),
            "1024": int(16 * channel_multiplier * narrow),
        }
        self.constant_input = ConstantInput(channels["4"], size=4)
        self.style_conv1 = StyleConv(channels["4"], channels["4"], 3, num_style_feat)
        self.to_rgb1 = ToRGB(channels["4"], num_style_feat, upsample=False)

        self.log_size = int(math.log(out_size, 2))
        self.num_layers = (self.log_size - 2) * 2 + 1
        self.style_convs = nn.ModuleList()
        self.to_rgbs = nn.ModuleList()
        self.noises = nn.Module()
        for layer_idx in range(self.num_layers):
            resolution = 2 ** ((layer_idx + 5) // 2)
            self.noises.register_buffer(f"noise{layer_idx}", torch.zeros(1, 1, resolution, resolution))
        in_channels = channels["4"]
        for i in range(3, self.log_size + 1):
            out_channels = channels[f"{2 ** i}"]
            self.style_convs.append(StyleConv(in_channels, out_channels, 3, num_style_feat, sample_mode="upsample"))
            self.style_convs.append(StyleConv(out_channels, out_channels, 3, num_style_feat))
            self.to_rgbs.append(ToRGB(out_channels, num_style_feat, upsample=True))
            in_channels = out_channels
        self.sft_half = sft_half

    def forward(self, latent, conditions):
        # latent: (1, num_latent, 512)；使用权重里固定的噪声，输出确定，序列播放不闪烁
        noise = [getattr(self.noises, f"noise{i}") for i in range(self.num_layers)]
        out = self.constant_input()
        out = self.style_conv1(out, latent[:, 0], noise[0])
        skip = self.to_rgb1(out, latent[:, 1])
        i = 1
        for conv1, conv2, noise1, noise2, to_rgb in zip(self.style_convs[::2], self.style_convs[1::2],
                                                        noise[1::2], noise[2::2], self.to_rgbs):
            out = conv1(out, latent[:, i], noise1)
            if i < len(conditions):
                if self.sft_half:
                    half = conv1.modulated_conv.out_channels // 2  # 常量，避免追踪出动态形状
                    out_same, out_sft = out[:, :half], out[:, half:]
                    out_sft = out_sft * conditions[i - 1] + conditions[i]
                    out = torch.cat([out_same, out_sft], dim=1)
                else:
                    out = out * conditions[i - 1] + conditions[i]
            out = conv2(out, latent[:, i + 1], noise2)
            skip = to_rgb(out, latent[:, i + 2], skip)
            i += 2
        return skip


class ResBlock(nn.Module):
    def __init__(self, in_channels, out_channels, mode="down"):
        super().__init__()
        self.conv1 = nn.Conv2d(in_channels, in_channels, 3, 1, 1)
        self.conv2 = nn.Conv2d(in_channels, out_channels, 3, 1, 1)
        self.skip = nn.Conv2d(in_channels, out_channels, 1, bias=False)
        self.scale_factor = 0.5 if mode == "down" else 2

    def forward(self, x):
        out = F.leaky_relu(self.conv1(x), negative_slope=0.2)
        out = F.interpolate(out, scale_factor=self.scale_factor, mode="bilinear", align_corners=False)
        out = F.leaky_relu(self.conv2(out), negative_slope=0.2)
        x = F.interpolate(x, scale_factor=self.scale_factor, mode="bilinear", align_corners=False)
        return out + self.skip(x)


class GFPGANv1Clean(nn.Module):
    def __init__(self, out_size=512, num_style_feat=512, channel_multiplier=2, num_mlp=8, narrow=1, sft_half=True):
        super().__init__()
        self.num_style_feat = num_style_feat
        unet_narrow = narrow * 0.5
        channels = {
            "4": int(512 * unet_narrow), "8": int(512 * unet_narrow), "16": int(512 * unet_narrow),
            "32": int(512 * unet_narrow), "64": int(256 * channel_multiplier * unet_narrow),
            "128": int(128 * channel_multiplier * unet_narrow), "256": int(64 * channel_multiplier * unet_narrow),
            "512": int(32 * channel_multiplier * unet_narrow), "1024": int(16 * channel_multiplier * unet_narrow),
        }
        self.log_size = int(math.log(out_size, 2))
        first_out_size = 2 ** self.log_size
        self.conv_body_first = nn.Conv2d(3, channels[f"{first_out_size}"], 1)
        in_channels = channels[f"{first_out_size}"]
        self.conv_body_down = nn.ModuleList()
        for i in range(self.log_size, 2, -1):
            out_channels = channels[f"{2 ** (i - 1)}"]
            self.conv_body_down.append(ResBlock(in_channels, out_channels, mode="down"))
            in_channels = out_channels
        self.final_conv = nn.Conv2d(in_channels, channels["4"], 3, 1, 1)
        in_channels = channels["4"]
        self.conv_body_up = nn.ModuleList()
        for i in range(3, self.log_size + 1):
            out_channels = channels[f"{2 ** i}"]
            self.conv_body_up.append(ResBlock(in_channels, out_channels, mode="up"))
            in_channels = out_channels
        self.toRGB = nn.ModuleList([nn.Conv2d(channels[f"{2 ** i}"], 3, 1) for i in range(3, self.log_size + 1)])
        self.num_latent = self.log_size * 2 - 2
        self.final_linear = nn.Linear(channels["4"] * 4 * 4, self.num_latent * num_style_feat)
        self.stylegan_decoder = StyleGAN2GeneratorCSFT(out_size, num_style_feat, num_mlp, channel_multiplier,
                                                       narrow, sft_half)
        self.condition_scale = nn.ModuleList()
        self.condition_shift = nn.ModuleList()
        for i in range(3, self.log_size + 1):
            out_channels = channels[f"{2 ** i}"]
            sft_out = out_channels if sft_half else out_channels * 2
            for lst in (self.condition_scale, self.condition_shift):
                lst.append(nn.Sequential(nn.Conv2d(out_channels, out_channels, 3, 1, 1), nn.LeakyReLU(0.2),
                                         nn.Conv2d(out_channels, sft_out, 3, 1, 1)))

    def forward(self, x):
        unet_skips = []
        feat = F.leaky_relu(self.conv_body_first(x), negative_slope=0.2)
        for i in range(self.log_size - 2):
            feat = self.conv_body_down[i](feat)
            unet_skips.insert(0, feat)
        feat = F.leaky_relu(self.final_conv(feat), negative_slope=0.2)
        latent = self.final_linear(feat.reshape(1, -1)).reshape(1, self.num_latent, self.num_style_feat)
        conditions = []
        for i in range(self.log_size - 2):
            feat = feat + unet_skips[i]
            feat = self.conv_body_up[i](feat)
            conditions.append(self.condition_scale[i](feat))
            conditions.append(self.condition_shift[i](feat))
        return self.stylegan_decoder(latent, conditions)


class FaceWrapper(nn.Module):
    """输入 0...1 RGB → GFPGAN 需要的 -1...1 → 输出 0...255 RGB。"""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        out = self.net(x * 2.0 - 1.0)
        return (torch.clamp(out, -1.0, 1.0) + 1.0) * 127.5


# ----------------------------------------------------------------------------
# 转换
# ----------------------------------------------------------------------------

def build_realesrgan(weights_dir: Path) -> nn.Module:
    net = RRDBNet()
    net.load_state_dict(load_state(fetch("realesrgan_x4plus", weights_dir)), strict=True)
    return SRWrapper(net).eval()


def build_gfpgan(weights_dir: Path) -> nn.Module:
    net = GFPGANv1Clean()
    net.load_state_dict(load_state(fetch("gfpgan_v1_4", weights_dir)), strict=True)
    return FaceWrapper(net).eval()


def convert(model: nn.Module, width: int, height: int, out_path: Path, description: str, author: str,
            license_text: str):
    import coremltools as ct

    example = torch.rand(1, 3, height, width)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="input", shape=example.shape, scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.ImageType(name="output", color_layout=ct.colorlayout.RGB)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = description
    mlmodel.author = author
    mlmodel.license = license_text
    mlmodel.version = "1"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out_path))
    print(f"已保存 {out_path}")
    return mlmodel


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return float("inf") if mse == 0 else 10 * math.log10(255.0 ** 2 / mse)


def validate(model: nn.Module, mlmodel, width: int, height: int, min_psnr: float, name: str):
    """在 macOS 上用 Core ML 实际推理，与 PyTorch 结果对比。"""
    from PIL import Image

    rng = np.random.default_rng(0)
    # 平滑的测试图（纯随机噪声对超分模型不具代表性）
    yy, xx = np.mgrid[0:height, 0:width]
    base = np.stack([
        127 + 100 * np.sin(xx / 9.0) * np.cos(yy / 13.0),
        127 + 90 * np.cos(xx / 17.0 + yy / 11.0),
        127 + 80 * np.sin((xx + yy) / 7.0),
    ], axis=-1)
    img = np.clip(base + rng.normal(0, 6, base.shape), 0, 255).astype(np.uint8)

    with torch.no_grad():
        ref = model(torch.from_numpy(img).permute(2, 0, 1)[None].float() / 255.0)
    ref = ref[0].permute(1, 2, 0).numpy().round().clip(0, 255).astype(np.uint8)

    out = mlmodel.predict({"input": Image.fromarray(img)})["output"]
    got = np.asarray(out.convert("RGB"))
    value = psnr(ref, got)
    print(f"{name}: Core ML vs PyTorch PSNR = {value:.2f} dB（要求 ≥ {min_psnr}）")
    if value < min_psnr:
        raise SystemExit(f"{name} 转换后误差过大")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("build/models"))
    parser.add_argument("--weights-dir", type=Path, default=Path("build/weights"))
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--only", choices=["sr", "face"], default=None)
    args = parser.parse_args()

    if args.validate and platform.system() != "Darwin":
        raise SystemExit("--validate 需要在 macOS 上运行")

    torch.set_grad_enabled(False)

    if args.only in (None, "sr"):
        sr = build_realesrgan(args.weights_dir)
        ml = convert(sr, SR_TILE_W, SR_TILE_H, args.out / "RealESRGANx4.mlpackage",
                     "Real-ESRGAN x4plus：通用真实照片超分辨率 ×4（输入 256×144）",
                     "Xintao Wang et al.", "BSD-3-Clause")
        if args.validate:
            validate(sr, ml, SR_TILE_W, SR_TILE_H, 30.0, "Real-ESRGAN")

    if args.only in (None, "face"):
        face = build_gfpgan(args.weights_dir)
        ml = convert(face, FACE_SIZE, FACE_SIZE, args.out / "GFPGANv14.mlpackage",
                     "GFPGAN v1.4：人脸修复（输入 512×512 对齐人脸）",
                     "Xintao Wang et al. (Tencent ARC)", "Apache-2.0")
        if args.validate:
            validate(face, ml, FACE_SIZE, FACE_SIZE, 28.0, "GFPGAN")


if __name__ == "__main__":
    sys.exit(main())
