#!/usr/bin/env bash
# 剥离 Linux release bundle 里第三方插件 / 原生库的调试符号。
#
# 用法:
#   tool/strip_linux_bundle.sh [bundle 目录]   # 默认 build/linux/x64/release/bundle
#
# 只处理白名单里的库；libapp.so（Dart AOT）与 libflutter_linux_gtk.so（Flutter
# 引擎）必须保留原样——前者由 gen_snapshot 产出，后者 release 引擎本身已 stripped，
# 对它们再 strip 没有收益，还可能破坏符号信息。
#
# 幂等：重复执行只会报 0 字节变化；strip 缺失、库损坏或剥离后新增缺失依赖
# 都会直接非零退出。
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent/_common.sh"

bundle="${1:-$LINUX_RELEASE_BUNDLE}"
lib_dir="$bundle/lib"

command -v strip >/dev/null 2>&1 || die "找不到 strip（binutils），无法剥离第三方库"
command -v file >/dev/null 2>&1 || die "找不到 file，无法校验剥离结果"
command -v ldd >/dev/null 2>&1 || die "找不到 ldd，无法校验动态库依赖"

[[ -d "$lib_dir" ]] || die "找不到 bundle lib 目录：$lib_dir（先 flutter build linux --release）"

# 白名单：只动第三方插件 / 原生库。新增插件需要在这里显式登记，
# 避免把 Flutter 自身的库误 strip。
LIBS=(
  libcnativeapi.so
  libdartjni.so
  libsqlite3.so
  libquickjs_c_bridge_plugin.so
  libquickjs_engine_plugin.so
  libflutter_secure_storage_linux_plugin.so
  liburl_launcher_linux_plugin.so
  libdynamic_color_plugin.so
  libmedia_kit_libs_linux_plugin.so
)
PROTECTED=(libapp.so libflutter_linux_gtk.so)

missing_libs() { # 输出该 ELF 当前找不到的依赖（目标机缺少的系统库不算剥离问题）
  ldd "$1" 2>/dev/null | awk '/not found/ {print $1}' | sort -u || true
}

human_bytes() {
  numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%sB' "$1"
}

in_list() { # needle item...
  local needle="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

for keep in "${PROTECTED[@]}"; do
  [[ -f "$lib_dir/$keep" ]] || die "bundle 缺少受保护的 $keep：$lib_dir"
done
printf '[strip] 保留 %s（不 strip）\n' "${PROTECTED[*]}"

total_before=0
total_after=0
handled=0

for name in "${LIBS[@]}"; do
  path="$lib_dir/$name"
  [[ -f "$path" ]] || continue
  in_list "$name" "${PROTECTED[@]}" &&
    die "内部错误：$name 是受保护库，不应出现在 strip 白名单"

  before="$(stat -c%s "$path")"
  missing_before="$(missing_libs "$path")"
  strip --strip-unneeded "$path"
  after="$(stat -c%s "$path")"
  missing_after="$(missing_libs "$path")"

  desc="$(file -b "$path")"
  [[ "$desc" == *ELF* ]] || die "$name 剥离后不是 ELF：$desc"
  [[ "$missing_after" == "$missing_before" ]] ||
    die "$name 剥离后缺少依赖（strip 前：${missing_before:-无}；strip 后：${missing_after:-无}）"

  total_before=$((total_before + before))
  total_after=$((total_after + after))
  handled=$((handled + 1))
  printf '[strip] %-48s %9s -> %9s (%+d B)\n' \
    "$name" "$(human_bytes "$before")" "$(human_bytes "$after")" \
    "$((after - before))"
done

(( handled > 0 )) || die "白名单里的库一个都没找到：$lib_dir"

saved=$((total_before - total_after))
if (( saved > 0 )); then
  printf '[strip] 共处理 %d 个库：%s -> %s（节省 %s）\n' \
    "$handled" "$(human_bytes "$total_before")" "$(human_bytes "$total_after")" \
    "$(human_bytes "$saved")"
else
  printf '[strip] 共处理 %d 个库：已是最新（幂等，无变化）\n' "$handled"
fi

exe="$bundle/$APP_BINARY"
if [[ -f "$exe" ]]; then
  exe_desc="$(file -b "$exe")"
  [[ "$exe_desc" == *ELF* ]] || die "$APP_BINARY 不是 ELF：$exe_desc"
  exe_missing="$(missing_libs "$exe")"
  if [[ -n "$exe_missing" ]]; then
    log "警告：ldd $APP_BINARY 缺少依赖（与 strip 无关，目标机需自行提供）：$exe_missing"
  else
    printf '[strip] ldd 校验通过：%s 的直接依赖都可解析\n' "$APP_BINARY"
  fi
fi

# 未登记的库保持原样，只提示，方便以后新增插件时补白名单。
shopt -s nullglob
unknown=()
for path in "$lib_dir"/*.so; do
  name="$(basename "$path")"
  in_list "$name" "${LIBS[@]}" && continue
  in_list "$name" "${PROTECTED[@]}" && continue
  unknown+=("$name")
done
if (( ${#unknown[@]} > 0 )); then
  printf '[strip] 跳过未登记白名单的库：%s\n' "${unknown[*]}"
fi
