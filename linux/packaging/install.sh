#!/bin/sh
# Molia Linux 桌面集成：把 share/ 下的 .desktop 与 hicolor 图标装到用户数据目录。
#
# 用法（在解压后的便携目录里执行，不需要 root）：
#   ./install.sh        安装 / 更新
#   ./uninstall.sh      移除
#
# **为什么 Exec 写成绝对路径**：应用内更新是「覆盖同一便携目录」
# （update_installer_io.dart 的 cp -a），路径不变，装一次即可长期有效；
# 若写成 `Exec=molia` 则依赖会话 PATH 里有程序目录，启动器里不成立。
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exe="$here/molia"
share="$here/share"
data="${XDG_DATA_HOME:-$HOME/.local/share}"

if [ ! -x "$exe" ]; then
  echo "找不到可执行文件：$exe" >&2
  exit 1
fi

mkdir -p "$data/applications" "$data/icons"
# sed 替换串里的 & 与 \ 要转义（路径里可能出现）。
exec_escaped=$(printf '%s' "$exe" | sed 's/[&\\]/\\&/g')
sed "s|^Exec=.*|Exec=\"$exec_escaped\"|" \
  "$share/applications/top.stillmisty.molia.desktop" \
  > "$data/applications/top.stillmisty.molia.desktop"
cp -R "$share/icons/hicolor" "$data/icons/"

# 缓存刷新 best-effort：工具缺失或维护者不装都不影响桌面条目生效。
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$data/applications" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$data/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "已安装桌面集成：应用菜单 / dock 里搜索 Molia 即可启动。"
echo "卸载：$here/uninstall.sh"
