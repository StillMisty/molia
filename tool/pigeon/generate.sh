#!/usr/bin/env bash
# Widget 域 Pigeon native interop 生成（issue #78 / ADR-0038 §9）。
#
# 生成链固定 JDK 21（JNIgen 官方支持 17–21；构建仍用 AGENTS.md 的 JDK 27）：
# 1. Kotlin 源先由 Gradle 编译成 class（JNIgen 的 asm 后端只读字节码）；
# 2. Pigeon 生成 Kotlin bridge，再自动调用 JNIgen 生成 Dart JNI 绑定；
# 3. 校正 jnigen 1.1.0 写死的 JniVersionCheck（见文末说明）。
#
# 用法（在任意目录）：
#   tool/pigeon/generate.sh
#
# 可选环境变量：JAVA_HOME_21 / ANDROID_SDK_ROOT / ANDROID_HOME。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

JAVA_HOME="${JAVA_HOME_21:-/usr/lib/jvm/java-21-openjdk}"
export JAVA_HOME
if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
  echo "generate.sh: 找不到 JDK 21（$JAVA_HOME）；用 JAVA_HOME_21 指定。" >&2
  exit 2
fi

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}"
export ANDROID_SDK_ROOT
if [[ ! -d "$ANDROID_SDK_ROOT" ]]; then
  echo "generate.sh: 找不到 Android SDK（$ANDROID_SDK_ROOT）。" >&2
  exit 2
fi

input="tool/pigeon/widget.dart"
dart_out="lib/platform/pigeon/widget.g.dart"
kotlin_out="android/app/src/main/kotlin/top/stillmisty/molia/pigeon/WidgetApi.g.kt"
kotlin_package="top.stillmisty.molia.pigeon"
jni_dart="lib/platform/pigeon/widget.g.jni.dart"

run_pigeon() {
  dart run pigeon \
    --input "$input" \
    --dart_out "$dart_out" \
    --kotlin_out "$kotlin_out" \
    --kotlin_package "$kotlin_package"
}

mkdir -p "$(dirname "$dart_out")" "$(dirname "$kotlin_out")"

# jnigen 通过临时 Gradle stub 解析依赖；Gradle 9.9 + org.gradle.parallel=true
# 会报 “Resolution ... without an exclusive lock”。只在生成期间关闭并行，
# 退出时恢复（包括失败 / Ctrl-C）。
gradle_properties="android/gradle.properties"
gradle_properties_backup="$(mktemp)"
cp "$gradle_properties" "$gradle_properties_backup"
restore_gradle_properties() {
  cp "$gradle_properties_backup" "$gradle_properties"
  rm -f "$gradle_properties_backup"
}
trap restore_gradle_properties EXIT
printf '\n# tool/pigeon/generate.sh 临时关闭（jnigen Gradle stub）\norg.gradle.parallel=false\n' \
  >> "$gradle_properties"

flutter build apk --config-only --no-pub

# schema 改过时先跑一次 bootstrap：Pigeon 会写出新的 Kotlin bridge，但随后
# JNIgen 会因为对应的 .class 还不存在而失败。这里允许它失败，编译后再正式
# 生成；如果 schema 本身有错，正式生成会再次失败并退出。
if [[ ! -f "$kotlin_out" || "$input" -nt "$kotlin_out" ]]; then
  echo "generate.sh: schema 比 Kotlin 生成物新，先做一次 bootstrap（JNIgen 预计失败）…"
  run_pigeon || true
fi

(cd android && ./gradlew :app:compileReleaseKotlin --quiet --console=plain)

run_pigeon

# jnigen 1.1.0 把期望的 package:jni 版本硬编码为 1.2.0，但 pub 最新仍是
# 1.1.2；不校正时生成文件的常量断言会在 analyze / 运行期失败。移除条件：
# package:jni 发布 1.2.0（或 jnigen 修正常量）。与 tool/jnigen.dart 同一处理。
sed -i -E 's/JniVersionCheck\(1, 2\)/JniVersionCheck(1, 1)/' "$jni_dart"

# jnigen 1.1.0 还会调用 jni 1.2.0 才有的 JReference.nonNullPointer；用
# lib/platform/pigeon/jni_compat.dart 的扩展补上（语义与 1.2.0 一致）。
# 同时压掉生成物在 Flutter 模板分析器下的已知诊断（不改生成逻辑）。
if ! grep -q "^import 'jni_compat.dart';$" "$jni_dart"; then
  sed -i "/^import 'package:jni\/jni.dart' as jni\\\$_;$/a import 'jni_compat.dart';" "$jni_dart"
fi
if ! grep -q 'ignore_for_file: override_on_non_overriding_member' "$jni_dart"; then
  sed -i "/^\/\/ ignore_for_file: use_super_parameters$/a // ignore_for_file: override_on_non_overriding_member" "$jni_dart"
fi
if ! grep -q 'ignore_for_file: invalid_internal_annotation' "$dart_out"; then
  sed -i "/^\/\/ ignore_for_file: type=lint$/a // ignore_for_file: invalid_internal_annotation" "$dart_out"
fi
if ! grep -q 'ignore_for_file: unused_element' lib/platform/pigeon/widget.native_interop.g.dart; then
  sed -i "/^\/\/ ignore_for_file: type=lint$/a // ignore_for_file: unused_element" lib/platform/pigeon/widget.native_interop.g.dart
fi

# Pigeon / jnigen 输出不保证行尾干净；统一格式化，提交物无 trailing whitespace。
dart format "$dart_out" lib/platform/pigeon/widget.native_interop.g.dart "$jni_dart" >/dev/null

echo "generate.sh: 完成；生成物："
echo "  $dart_out"
echo "  lib/platform/pigeon/widget.native_interop.g.dart"
echo "  $jni_dart"
echo "  tool/pigeon/widget_jnigen_config.dart"
echo "  $kotlin_out"
