#!/usr/bin/env python3
"""生成应用内更新清单 latest.json（release.yml 在发布时调用）。

清单是客户端唯一的版本信息来源：放在 Release 资产里（稳定版经
`releases/latest/download/latest.json`、测试版经滚动 `beta` 标签），
Web 端另由 Pages 同源提供，避免 GitHub API 的匿名限流。

用法（见 .github/workflows/release.yml）：

    python3 tool/ci/gen_update_manifest.py \
      --repo StillMisty/molia --tag v1.0.0 --version 1.0.0 --build 42 \
      --channel stable --published-at 2026-10-14T00:00:00Z \
      --notes-file notes.md --assets-dir dist --output dist/latest.json

产物文件名约定（由 release.yml 统一改名）：
    molia-<version>-android-arm64.apk / -armv7 / -x86_64
    molia-<version>-android.aab            （不入清单，仅上架用）
    molia-<version>-android-symbols.zip    （不入清单，调试符号）
    molia-<version>-windows-x64.zip
    molia-<version>-linux-x64.tar.gz
    molia-<version>-web.zip
    molia-<version>-ios-unsigned.zip       （不入清单：iOS 不走应用内更新）
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

# 清单里不出现、但会随 Release 一起分发的产物。
_SKIP_TOKENS = {"symbols", "unsigned"}
_SKIP_KINDS = {"aab"}

_KINDS = ("tar.gz", "apk", "zip", "aab")

_ARCHES = {"arm64", "armv7", "x86_64", "x64"}


def _split_kind(name: str) -> tuple[str, str] | None:
    for kind in _KINDS:
        suffix = "." + kind
        if name.endswith(suffix):
            return kind, name[: -len(suffix)]
    return None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_asset(name: str, version: str) -> dict[str, str] | None:
    prefix = f"molia-{version}-"
    if not name.startswith(prefix):
        return None
    split = _split_kind(name)
    if split is None:
        return None
    kind, stem = split
    if kind in _SKIP_KINDS:
        return None

    tokens = stem[len(prefix) :].split("-")
    if any(token in _SKIP_TOKENS for token in tokens):
        return None

    platform = tokens[0]
    arch = next((token for token in tokens[1:] if token in _ARCHES), "any")
    return {
        "platform": platform,
        "arch": arch,
        "kind": kind,
        "file": name,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="生成应用内更新清单")
    parser.add_argument("--repo", required=True, help="owner/repo")
    parser.add_argument("--tag", required=True, help="Git tag，如 v1.0.0")
    parser.add_argument("--version", required=True, help="不带 v 的版本号")
    parser.add_argument("--build", required=True, type=int, help="构建号（Android versionCode 同源）")
    parser.add_argument("--channel", required=True, choices=["stable", "beta"])
    parser.add_argument("--published-at", required=True, help="ISO8601 时间戳")
    parser.add_argument("--notes-file", help="发布说明 markdown 文件")
    parser.add_argument("--assets-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    if not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?", args.version):
        print(f"版本号不符合 semver：{args.version}", file=sys.stderr)
        return 1

    notes = ""
    if args.notes_file:
        notes = Path(args.notes_file).read_text(encoding="utf-8").strip()

    assets: list[dict[str, object]] = []
    for path in sorted(args.assets_dir.iterdir()):
        if not path.is_file():
            continue
        parsed = _parse_asset(path.name, args.version)
        if parsed is None:
            continue
        parsed["url"] = (
            f"https://github.com/{args.repo}/releases/download/{args.tag}/{path.name}"
        )
        parsed["size"] = path.stat().st_size
        parsed["sha256"] = _sha256(path)
        assets.append(parsed)

    if not assets:
        print("assets 目录里没有可入清单的产物，检查文件名约定", file=sys.stderr)
        return 1

    manifest = {
        "schema": 1,
        "channel": args.channel,
        "version": args.version,
        "build": args.build,
        "releasedAt": args.published_at,
        "notes": notes,
        "notesUrl": f"https://github.com/{args.repo}/releases/tag/{args.tag}",
        "assets": assets,
    }
    args.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"已生成 {args.output}（{len(assets)} 个产物）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
