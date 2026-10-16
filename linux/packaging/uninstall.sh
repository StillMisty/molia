#!/bin/sh
# 移除 Molia 的 Linux 桌面集成（install.sh 的逆操作）。
#
# 只删除本应用安装的 .desktop 与图标文件；程序文件与用户数据（播放库、
# 设置、缓存）不受影响。
set -eu

data="${XDG_DATA_HOME:-$HOME/.local/share}"
applications="$data/applications"
icons="$data/icons/hicolor"

rm -f "$applications/top.stillmisty.molia.desktop"
if [ -d "$icons" ]; then
  find "$icons" -name 'top.stillmisty.molia.png' -delete
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$applications" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$icons" >/dev/null 2>&1 || true
fi

echo "已移除桌面集成（程序文件与用户数据未改动）。"
