#!/bin/bash
# 把 ReFrame.app 打包成可拖拽安装的 DMG。
# 用法：scripts/make_dmg.sh <ReFrame.app 路径> <输出 dmg 路径>
set -euo pipefail

APP="$1"
DMG="$2"
VOLNAME="ReFrame"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/首次打开必读.txt" <<'TXT'
安装：把 ReFrame 拖到右边的“应用程序”文件夹。

第一次打开：因为没有付费的苹果开发者签名，系统会提示“无法验证开发者”。
任选一种方式放行（只需一次）：
  1. 在“应用程序”里右键点 ReFrame → 打开 → 再点“打开”；
     macOS 15 起若没有“打开”按钮：系统设置 → 隐私与安全性 → 下方点“仍要打开”。
  2. 或在“终端”执行：xattr -cr /Applications/ReFrame.app

使用：
  1. 打开图片或文件夹（原图只读，不会被修改）；
  2. 右侧选择输出文件夹，点“试修当前图”看效果；
  3. 满意后点“修复全部”；处理期间电脑不会自动睡眠；
  4. 切到“播放”页循环播放，可导出为视频。
TXT

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
echo "DMG: $DMG"
