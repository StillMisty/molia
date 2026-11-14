#!/usr/bin/env python3
"""文档引用与工具链一致性检查。

两组检查，默认都跑：

1. 文档引用：反引号里的仓库路径、Markdown 链接、``§数字`` 章节号、孤儿文档、
   ADR 编号。ADR 是历史决策记录，允许引用当时存在、后来改名/删除的路径。
2. 工具链：`AGENTS.md`「工具链」与 pubspec / Gradle / Android / CI 工作流逐项
   比对；其它文档与 `molia-*` 技能不得复列当前版本号（只允许 AGENTS 维护）。

用法：
  python3 tool/agent/check_docs.py              # 全部
  python3 tool/agent/check_docs.py --docs       # 只查文档引用
  python3 tool/agent/check_docs.py --toolchain  # 只查工具链

退出码：0 = 全部通过；1 = 有错误（CI 直接失败）。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# 扫描范围：仓库入口文档 + docs/ + 本仓 molia-* 技能。
# dart-* / flutter-* 等第三方技能由 skills-lock.json 管理，不在此检查。
ROOT_DOCS = ("AGENTS.md", "README.md", "GLOSSARY.md")

PATH_PREFIXES = (
    "lib/",
    "test/",
    "integration_test/",
    "tool/",
    "docs/",
    "android/",
    "ios/",
    "macos/",
    "windows/",
    "linux/",
    "assets/",
    ".github/",
    ".agents/",
)

# 文中明确提到、但并不存在于本仓的路径（第三方包内路径 / 假设路径 / 反例）。
PATH_ALLOWLIST = {
    "android/consumer-rules.pro": "第三方包内的文件（文中是复评记录）",
    "android/iOS/macOS": "文字列举，不是路径",
    "assets/fonts/": "文中举例的未来字体目录",
    "ios/Podfile": "文中说明仓库里没有 Podfile",
    "macos/Podfile": "文中说明仓库里没有 Podfile",
    "lib/arm64-v8a/libmpv.so": "APK 内路径，不是仓库路径",
    "lib/just_audio_media_kit.dart": "文中假设的 dependency_overrides 文件",
    "lib/media_kit_libs_audio.dart": "文中假设的 dependency_overrides 文件",
    "lib/src/player/native/core/native_library.dart": "media_kit 上游包内路径",
    "linux/include/quickjs_engine/quickjs_engine_plugin.h": "quickjs 插件包内路径",
}

# 工具链版本禁止在文档中复列；这些文件是带日期的测量快照，允许保留当时版本。
VERSION_ALLOWLIST = {
    "docs/performance-audit.md": "历史体检归档，记录当时环境",
    "docs/media_kit_native_libs.md": "测量快照，记录当时环境",
}

SECTION_RE = re.compile(r"§(\d+(?:\.\d+)*)")
HEADING_RE = re.compile(r"^#{1,6}\s+(\d+(?:\.\d+)*)", re.MULTILINE)
BACKTICK_RE = re.compile(r"`([^`\n]+)`")
ADR_NUMBER_RE = re.compile(r"ADR-(\d{4})")


def iter_doc_files() -> list[Path]:
    files = [ROOT / name for name in ROOT_DOCS]
    files += sorted((ROOT / "docs").rglob("*.md"))
    files += sorted((ROOT / ".agents" / "skills").glob("molia-*/*.md"))
    files += sorted((ROOT / ".agents" / "skills").glob("molia-*/**/*.md"))
    return sorted({p for p in files if p.is_file()})


def rel(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def is_adr(path: Path) -> bool:
    return rel(path).startswith("docs/adr/")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_code_fences(text: str) -> str:
    """去掉 ``` 围栏内容，避免把示例里的 [x](y) 当成真链接。"""
    return re.sub(r"```.*?```", "", text, flags=re.DOTALL)


def check_paths(files: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in files:
        if is_adr(path):
            continue  # ADR 允许引用当时存在、后来改名的路径
        text = read(path)
        for match in BACKTICK_RE.finditer(text):
            raw = match.group(1).strip()
            if not raw:
                continue
            token = raw.split()[0].split("::")[0]
            token = token.rstrip(".,;:)]}，。；：）")
            if not token.startswith(PATH_PREFIXES):
                continue
            if any(ch in token for ch in "*<>{}|$~"):
                continue
            if "://" in token or "..." in token:
                continue
            if token in PATH_ALLOWLIST:
                continue
            # `docs/adr/0003` 这种只写编号、不写 .md 的引用按前缀解析。
            adr_ref = re.fullmatch(r"docs/adr/(\d{4})", token)
            if adr_ref:
                if not any((ROOT / "docs/adr").glob(f"{adr_ref.group(1)}-*.md")):
                    errors.append(f"{rel(path)}: ADR 不存在: {token}")
                continue
            target = ROOT / token
            ok = target.is_dir() if token.endswith("/") else target.exists()
            if not ok:
                errors.append(f"{rel(path)}: 路径不存在: {token}")
    return errors


def check_markdown_links(files: list[Path]) -> list[str]:
    errors: list[str] = []
    link_re = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
    for path in files:
        text = strip_code_fences(read(path))
        for match in link_re.finditer(text):
            target = match.group(1)
            if target.startswith(("http://", "https://", "mailto:", "#", "/")):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            resolved = (path.parent / target).resolve()
            if not resolved.exists():
                errors.append(f"{rel(path)}: 链接不存在: {target}")
    return errors


def heading_numbers(path: Path) -> set[str]:
    return set(HEADING_RE.findall(read(path)))


def check_sections(files: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in files:
        text = strip_code_fences(read(path))
        for match in SECTION_RE.finditer(text):
            ref = match.group(1)
            # 只在本行内找目标文件，避免把上一行的 `docs/xxx.md` 误当成这一行的目标。
            line_start = text.rfind("\n", 0, match.start()) + 1
            context = text[line_start : match.start()]
            target: Path | None = None
            md_match = re.search(r"`([^`]+\.md)`", context)
            if md_match:
                candidate = ROOT / md_match.group(1)
                if not candidate.exists():
                    candidate = path.parent / md_match.group(1)
                target = candidate
            else:
                adr_match = ADR_NUMBER_RE.search(context)
                if adr_match:
                    found = sorted(
                        (ROOT / "docs/adr").glob(f"{adr_match.group(1)}-*.md")
                    )
                    target = found[-1] if found else None
                else:
                    target = path
            if target is None or not target.exists():
                continue
            numbers = heading_numbers(target)
            if numbers and ref not in numbers:
                errors.append(
                    f"{rel(path)}: 章节不存在: §{ref}"
                    f"（目标 {rel(target)}）"
                )
    return errors


def check_orphans(files: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in sorted((ROOT / "docs").glob("*.md")):
        if path.name == "README.md":
            continue
        others = "\n".join(read(p) for p in files if p != path)
        if path.name not in others:
            errors.append(
                f"{rel(path)}: 孤儿文档（没有文档指向它；加进 docs/README.md 或删除）"
            )
    return errors


def check_adr_numbers() -> list[str]:
    errors: list[str] = []
    numbers = []
    for path in sorted((ROOT / "docs/adr").glob("[0-9][0-9][0-9][0-9]-*.md")):
        numbers.append(int(path.name[:4]))
    expected = list(range(1, len(numbers) + 1))
    if numbers != expected:
        errors.append(
            "docs/adr/: ADR 编号应从 0001 起连续且唯一，"
            f"当前为 {numbers}"
        )
    return errors


def toolchain_from_agents() -> dict[str, str]:
    text = read(ROOT / "AGENTS.md")
    section = text.split("## 工具链", 1)[1].split("\n## ", 1)[0]
    values: dict[str, str] = {}

    def grab(key: str, pattern: str) -> None:
        match = re.search(pattern, section)
        if not match:
            raise SystemExit(f"check_docs: 无法从 AGENTS.md 工具链段解析 {key}")
        values[key] = match.group(1)

    grab("flutter", r"Flutter\s*/\s*Dart\s+([\d.]+)\s*/")
    grab("dart", r"Flutter\s*/\s*Dart\s+[\d.]+\s*/\s*([\d.]+)")
    grab("jdk", r"JDK\s+(\d+)\+?")
    grab("gradle", r"Gradle\s+([\d.]+)")
    grab("agp", r"AGP\s+([\d.]+)")
    grab("kotlin", r"Kotlin\s+([\d.]+)")
    grab("compile_sdk", r"compileSdk\s+([\d.]+)")
    grab("target_sdk", r"targetSdk\s+([\d.]+)")
    grab("min_sdk", r"minSdk\s+([\d.]+)")
    grab("build_tools", r"build-tools\s+([\d.]+)")
    grab("ndk", r"NDK\s+([\d.]+)")
    return values


def check_toolchain() -> list[str]:
    errors: list[str] = []
    expected = toolchain_from_agents()

    def compare(label: str, actual: str | None, want: str, source: str) -> None:
        if actual != want:
            errors.append(f"{source}: {label} = {actual}，AGENTS.md 为 {want}")

    pubspec = read(ROOT / "pubspec.yaml")
    env = pubspec.split("environment:", 1)[1].split("\n\n", 1)[0]
    sdk = re.search(r"^\s+sdk:\s*[\^>=<]*\s*([\d.]+)", env, re.MULTILINE)
    flutter = re.search(
        r"^\s+flutter:\s*[\"']?[>=<^]*\s*([\d.]+)", env, re.MULTILINE
    )
    compare("Dart SDK", sdk.group(1) if sdk else None, expected["dart"], "pubspec.yaml")
    compare(
        "Flutter", flutter.group(1) if flutter else None, expected["flutter"],
        "pubspec.yaml",
    )

    wrapper = read(ROOT / "android/gradle/wrapper/gradle-wrapper.properties")
    gradle = re.search(r"gradle-([\d.]+)-bin\.zip", wrapper)
    compare(
        "Gradle", gradle.group(1) if gradle else None, expected["gradle"],
        "android/gradle/wrapper/gradle-wrapper.properties",
    )

    settings = read(ROOT / "android/settings.gradle")
    agp = re.search(
        r"com\.android\.application\"?\s+version\s+['\"]([\d.]+)['\"]", settings
    )
    kotlin = re.search(
        r"org\.jetbrains\.kotlin\.android\"?\s+version\s+['\"]([\d.]+)['\"]", settings
    )
    compare("AGP", agp.group(1) if agp else None, expected["agp"], "android/settings.gradle")
    compare(
        "Kotlin", kotlin.group(1) if kotlin else None, expected["kotlin"],
        "android/settings.gradle",
    )

    build_gradle = read(ROOT / "android/app/build.gradle")
    major = re.search(r"^\s*compileSdk\s*=\s*(\d+)", build_gradle, re.MULTILINE)
    minor = re.search(r"^\s*compileSdkMinor\s*=\s*(\d+)", build_gradle, re.MULTILINE)
    compile_sdk = f"{major.group(1)}.{minor.group(1)}" if major and minor else None
    compare("compileSdk", compile_sdk, expected["compile_sdk"], "android/app/build.gradle")
    target = re.search(r"^\s*targetSdk\s*=\s*(\d+)", build_gradle, re.MULTILINE)
    compare(
        "targetSdk", target.group(1) if target else None, expected["target_sdk"],
        "android/app/build.gradle",
    )
    minimum = re.search(r"^\s*minSdk\s*=\s*(\d+)", build_gradle, re.MULTILINE)
    compare(
        "minSdk", minimum.group(1) if minimum else None, expected["min_sdk"],
        "android/app/build.gradle",
    )
    build_tools = re.search(r'buildToolsVersion\s*=\s*"([\d.]+)"', build_gradle)
    compare(
        "build-tools", build_tools.group(1) if build_tools else None,
        expected["build_tools"], "android/app/build.gradle",
    )
    ndk = re.search(r'ndkVersion\s*=\s*"([\d.]+)"', build_gradle)
    compare(
        "NDK", ndk.group(1) if ndk else None, expected["ndk"],
        "android/app/build.gradle",
    )

    for workflow in sorted((ROOT / ".github/workflows").glob("*.yml")):
        text = read(workflow)
        for version in re.findall(r"flutter-version:\s*[\"']?([\d.]+)", text):
            compare("Flutter", version, expected["flutter"], rel(workflow))
        for version in re.findall(r"java-version:\s*[\"']?(\d+)", text):
            compare("JDK", version, expected["jdk"], rel(workflow))
        for version in re.findall(
            r"compile_sdk_platform=platforms/android-([\d.]+)", text
        ):
            compare("compileSdk", version, expected["compile_sdk"], rel(workflow))
        for version in re.findall(r"build_tools_version=([\d.]+)", text):
            compare("build-tools", version, expected["build_tools"], rel(workflow))
        for version in re.findall(r"^\s*ndk_version=([\d.]+)", text, re.MULTILINE):
            compare("NDK", version, expected["ndk"], rel(workflow))

    # 文档不得复列当前版本；带日期的测量快照与 ADR 除外。
    version_tokens = {
        "Flutter": expected["flutter"],
        "Dart": expected["dart"],
        "Gradle": expected["gradle"],
        "AGP": expected["agp"],
        "Kotlin": expected["kotlin"],
        "build-tools": expected["build_tools"],
        "NDK": expected["ndk"],
    }
    for path in iter_doc_files():
        if rel(path) == "AGENTS.md":
            continue  # 版本来源本身
        if is_adr(path) or rel(path) in VERSION_ALLOWLIST:
            continue
        text = read(path)
        for label, version in version_tokens.items():
            pattern = rf"(?<![\w.]){re.escape(version)}(?![\w.])"
            if re.search(pattern, text):
                errors.append(
                    f"{rel(path)}: 复列了 {label} 当前版本 {version}；"
                    "只保留 AGENTS.md「工具链」一处"
                )
        if re.search(r"(compileSdk|platforms/android-)\s*=?\s*37\.2", text):
            errors.append(
                f"{rel(path)}: 复列了 compileSdk 37.2；"
                "只保留 AGENTS.md「工具链」一处"
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--docs", action="store_true", help="只查文档引用")
    parser.add_argument("--toolchain", action="store_true", help="只查工具链")
    args = parser.parse_args()
    run_docs = args.docs or not args.toolchain
    run_toolchain = args.toolchain or not args.docs

    errors: list[str] = []
    if run_docs:
        files = iter_doc_files()
        errors += check_paths(files)
        errors += check_markdown_links(files)
        errors += check_sections(files)
        errors += check_orphans(files)
        errors += check_adr_numbers()
    if run_toolchain:
        errors += check_toolchain()

    if errors:
        for error in errors:
            print(f"ERROR {error}", file=sys.stderr)
        print(f"\ncheck_docs: {len(errors)} 项失败", file=sys.stderr)
        return 1
    print("check_docs: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
