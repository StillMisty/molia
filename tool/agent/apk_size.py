#!/usr/bin/env python3
"""APK 体积 / native 库明细（只依赖 Python 标准库，不要求 unzip）。

用法:
    tool/agent/apk_size.py app-arm64-v8a-release.apk [more.apk ...]
    tool/agent/apk_size.py --check app-arm64-v8a-release.apk
    tool/agent/apk_size.py --json app-arm64-v8a-release.apk

`--check` 按 Molia 的发布约束检查：
- Android 包不得出现 libmpv.so / libmediakitandroidhelper.so（media_kit
  的 umbrella libs 会把 Android 体积 +~3MB）；
- 不得出现 libcnativeapi.so（桌面 nativeapi 专用，见 build.gradle）；
- 必须保留 libsqlite3.so（drift，见 docs/pitfalls.md #28）与
  libquickjs_c_bridge_plugin.so（LX 引擎）。
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import sys
import zipfile

FORBIDDEN = {
    "libmpv.so": "media_kit Android libs 不应进入 APK",
    "libmediakitandroidhelper.so": "media_kit Android helper 不应进入 APK",
    "libcnativeapi.so": "nativeapi 桌面专用，Android 应排除",
}
REQUIRED = {
    "libsqlite3.so": "drift 运行期必需（docs/pitfalls.md #28）",
    "libquickjs_c_bridge_plugin.so": "LX 音源引擎必需",
}


def human(n: int) -> str:
    value = float(n)
    for suffix in ("B", "KB", "MB", "GB"):
        if value < 1024 or suffix == "GB":
            if suffix == "B":
                return f"{int(value)}B"
            return f"{value:.2f}{suffix}"
        value /= 1024
    return f"{n}B"


def group_of(name: str) -> str:
    if name.startswith("lib/"):
        return "lib/"
    if name.startswith("assets/flutter_assets/"):
        return "flutter_assets/"
    if name.startswith("res/"):
        return "res/"
    if name.startswith("META-INF/"):
        return "META-INF/"
    if name.startswith("kotlin/"):
        return "kotlin/"
    if name.endswith(".dex"):
        return "dex"
    return name.split("/", 1)[0]


def inspect(path: str) -> dict:
    with zipfile.ZipFile(path) as apk:
        entries = apk.infolist()
    groups: dict[str, dict[str, int]] = collections.defaultdict(
        lambda: {"count": 0, "uncompressed": 0, "compressed": 0}
    )
    libs: list[dict] = []
    for entry in entries:
        group = group_of(entry.filename)
        current = groups[group]
        current["count"] += 1
        current["uncompressed"] += entry.file_size
        current["compressed"] += entry.compress_size
        if entry.filename.startswith("lib/"):
            libs.append(
                {
                    "name": entry.filename,
                    "uncompressed": entry.file_size,
                    "compressed": entry.compress_size,
                }
            )
    libs.sort(key=lambda item: item["compressed"], reverse=True)
    top = sorted(
        (
            {
                "name": entry.filename,
                "uncompressed": entry.file_size,
                "compressed": entry.compress_size,
            }
            for entry in entries
        ),
        key=lambda item: item["compressed"],
        reverse=True,
    )[:10]
    return {
        "path": path,
        "size": os.path.getsize(path),
        "groups": dict(groups),
        "libs": libs,
        "top": top,
    }


def check(report: dict) -> list[str]:
    names = {item["name"].rsplit("/", 1)[-1] for item in report["libs"]}
    errors: list[str] = []
    for name, reason in FORBIDDEN.items():
        if name in names:
            errors.append(f"发现禁止库 {name}：{reason}")
    for name, reason in REQUIRED.items():
        if name not in names:
            errors.append(f"缺少必需库 {name}：{reason}")
    return errors


def print_report(report: dict) -> None:
    print(f"# {report['path']}")
    print(f"APK: {human(report['size'])} ({report['size']} B)")
    print()
    print("| 分组 | 文件数 | 未压缩 | 压缩后 |")
    print("| --- | ---: | ---: | ---: |")
    for group, value in sorted(
        report["groups"].items(), key=lambda item: item[1]["compressed"], reverse=True
    ):
        print(
            f"| {group} | {value['count']} | {human(value['uncompressed'])} | "
            f"{human(value['compressed'])} |"
        )
    print()
    print("## lib/ 明细")
    print("| 库 | 未压缩 | 压缩后 |")
    print("| --- | ---: | ---: |")
    for item in report["libs"]:
        print(
            f"| {item['name'].rsplit('/', 1)[-1]} | "
            f"{human(item['uncompressed'])} | {human(item['compressed'])} |"
        )
    print()
    print("## 最大条目（压缩后）")
    for item in report["top"]:
        print(f"- {human(item['compressed'])}  {item['name']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="校验禁止 / 必需 native 库")
    parser.add_argument("--json", action="store_true", help="输出 JSON")
    parser.add_argument("apks", nargs="+", help="APK 路径")
    args = parser.parse_args()

    reports = [inspect(path) for path in args.apks]
    failed = False
    for report in reports:
        if args.check:
            errors = check(report)
            if errors:
                failed = True
                for error in errors:
                    print(f"[FAIL] {report['path']}: {error}", file=sys.stderr)
            else:
                print(f"[OK] {report['path']}: native 库约束通过", file=sys.stderr)
        if args.json:
            print(json.dumps(report, ensure_ascii=False))
        else:
            print_report(report)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
