#!/usr/bin/env python3
"""生成 Windows 任务栏缩略图工具栏的按钮图标（`windows/runner/resources/thumbbar/*.ico`）。

产物提交进仓库：改本文件的字形 / 尺寸后重跑本脚本（需要 `rsvg-convert`，由 librsvg 提供）。

    python3 tool/gen_taskbar_icons.py

为什么是两套：任务栏按钮图标是**原样绘制**的（不做主题反色），浅色字形在浅色
任务栏下看不见、深色字形在深色任务栏下看不见。因此每个字形出两套，运行时按
`SystemUsesLightTheme` 选择（见 windows/runner/taskbar_thumb_bar.cc）。

字形与界面一致：取 Material Symbols 的几何（skip_previous / skip_next /
play_arrow / pause / favorite / favorite_border），圆角近似界面里的 `*_rounded`。
"""

from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
import tempfile

# 任务栏按钮的图标档位：Windows 要求图标为 SM_CXICON × SM_CYICON（100% 缩放
# 时 32×32，150% 时 48，200% 时 64），这里把常用缩放档位全出齐，避免系统拉伸。
SIZES = (16, 20, 24, 32, 40, 48, 64)

# 字形颜色：亮字形给深色任务栏，暗字形给浅色任务栏。
LIGHT_GLYPH = "#F2F2F2"
DARK_GLYPH = "#1B1B1B"

OUT_DIR = os.path.join("windows", "runner", "resources", "thumbbar")


def sty(color: str) -> str:
    """统一字形样式：填充 + 同色描边（把折角描圆，靠近 *_rounded 的观感）。"""
    return (
        f'fill="{color}" stroke="{color}" stroke-width="1.4" '
        'stroke-linejoin="round" stroke-linecap="round"'
    )


def glyphs(color: str) -> dict[str, str]:
    """按颜色生成全部字形（24×24 网格，与 Material 图标同栅格）。"""
    s = sty(color)
    return {
        # 上一首：左竖条 + 左向三角（Material skip_previous）。
        "previous": (
            f'<rect x="4.6" y="4.6" width="3.4" height="14.8" rx="1.3" fill="{color}"/>'
            f'<path d="M20.4 6.2v11.6a1 1 0 0 1-1.53.85l-8.2-5.8a1 1 0 0 1 0-1.7l8.2-5.8A1 1 0 0 1 20.4 6.2z" {s}/>'
        ),
        # 下一首：右向三角 + 右竖条（skip_previous 镜像）。
        "next": (
            f'<path d="M3.6 6.2v11.6a1 1 0 0 0 1.53.85l8.2-5.8a1 1 0 0 0 0-1.7l-8.2-5.8A1 1 0 0 0 3.6 6.2z" {s}/>'
            f'<rect x="16" y="4.6" width="3.4" height="14.8" rx="1.3" fill="{color}"/>'
        ),
        # 播放：右向三角（play_arrow）。
        "play": (
            f'<path d="M7.6 5.2v13.6a1 1 0 0 0 1.53.85l10.4-6.8a1 1 0 0 0 0-1.7L9.13 4.35A1 1 0 0 0 7.6 5.2z" {s}/>'
        ),
        # 暂停：两根圆角竖条（pause）。
        "pause": (
            f'<rect x="6.1" y="4.8" width="4" height="14.4" rx="1.4" fill="{color}"/>'
            f'<rect x="13.9" y="4.8" width="4" height="14.4" rx="1.4" fill="{color}"/>'
        ),
        # 收藏（未收藏）：空心爱心（favorite_border）。
        "favorite": (
            f'<path d="M16.5 3.2c-1.74 0-3.41.81-4.5 2.09C10.91 4.01 9.24 3.2 7.5 3.2 '
            f'4.42 3.2 2 5.62 2 8.7c0 3.78 3.4 6.86 8.55 11.54L12 21.55l1.45-1.32C18.6 15.56 '
            f'22 12.48 22 8.7c0-3.08-2.42-5.5-5.5-5.5zm-4.4 15.55l-.1.1-.1-.1C7.14 14.44 4 11.59 '
            f'4 8.7 4 6.7 5.5 5.2 7.5 5.2c1.54 0 3.04.99 3.57 2.36h1.87C13.46 6.19 14.96 5.2 '
            f'16.5 5.2c2 0 3.5 1.5 3.5 3.5 0 2.89-3.14 5.74-7.9 10.05z" fill="{color}"/>'
        ),
        # 收藏（已收藏）：实心爱心（favorite）。
        "favorite_on": (
            f'<path d="M12 21.55l-1.45-1.32C5.4 15.56 2 12.48 2 8.7 2 5.62 4.42 3.2 7.5 3.2c1.74 0 '
            f'3.41.81 4.5 2.09C13.09 4.01 14.76 3.2 16.5 3.2 19.58 3.2 22 5.62 22 8.7c0 3.78-3.4 '
            f'6.86-8.55 11.54L12 21.55z" {s}/>'
        ),
    }


def svg(body: str) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">'
        f"{body}</svg>\n"
    )


def render_png(svg_text: str, size: int, out_path: str) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as handle:
        handle.write(svg_text)
        svg_path = handle.name
    try:
        subprocess.run(
            ["rsvg-convert", "-w", str(size), "-h", str(size), "-o", out_path, svg_path],
            check=True,
        )
    finally:
        os.unlink(svg_path)


def pack_ico(png_paths: list[tuple[int, str]], out_path: str) -> None:
    """把若干 PNG 打包成 .ico（PNG 条目，Vista+ 支持；仓库现有 app_icon.ico 同格式）。"""
    count = len(png_paths)
    header = struct.pack("<HHH", 0, 1, count)
    entries = bytearray()
    body = bytearray()
    offset = 6 + 16 * count
    for size, path in png_paths:
        data = open(path, "rb").read()
        entries += struct.pack(
            "<BBBBHHII",
            size if size < 256 else 0,
            size if size < 256 else 0,
            0,
            0,
            1,
            32,
            len(data),
            offset,
        )
        body += data
        offset += len(data)
    with open(out_path, "wb") as handle:
        handle.write(header + bytes(entries) + bytes(body))


def main() -> int:
    if shutil.which("rsvg-convert") is None:
        print("需要 rsvg-convert（librsvg）", file=sys.stderr)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory() as work_dir:
        for theme, color in (("dark", LIGHT_GLYPH), ("light", DARK_GLYPH)):
            for name, body in glyphs(color).items():
                pngs = []
                for size in SIZES:
                    png_path = os.path.join(work_dir, f"{name}_{theme}_{size}.png")
                    render_png(svg(body), size, png_path)
                    pngs.append((size, png_path))
                out_path = os.path.join(OUT_DIR, f"{name}_{theme}.ico")
                pack_ico(pngs, out_path)
                print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
