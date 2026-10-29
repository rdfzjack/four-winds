#!/usr/bin/env bash
# 在云端（Linux）安装和作者本机同版本的 Godot，用来跑无头测试。
# 用法：bash tools/setup_godot.sh [版本号，默认 4.7]
# 下载地址是 Godot 官网 downloads.godotengine.org（github.com 的下载在云端会被拦截）。
set -euo pipefail

VERSION="${1:-4.7}"
if command -v godot >/dev/null 2>&1 && godot --version | grep -q "^${VERSION}\.stable"; then
  echo "已安装：$(godot --version)"
  exit 0
fi

DIR="${TMPDIR:-/tmp}/godot-${VERSION}"
mkdir -p "$DIR"
URL="https://downloads.godotengine.org/?version=${VERSION}&flavor=stable&slug=linux.x86_64.zip&platform=linux.64"
curl -sSfL --max-time 300 -o "$DIR/godot.zip" "$URL"
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$DIR/godot.zip" "$DIR"
BIN="$(ls "$DIR"/Godot_v"${VERSION}"*linux.x86_64 | head -1)"
chmod +x "$BIN"
ln -sf "$BIN" /usr/local/bin/godot
echo "安装完成：$(godot --version)"
