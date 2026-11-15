#!/usr/bin/env bash
# 依赖与工具链现状报告（只读，不改任何文件）。
#
# 用法:
#   tool/agent/deps.sh
#
# 输出:
#   $RUN_DIR/deps-<时间戳>/summary.txt   每条命令的 ok/fail
#   $RUN_DIR/deps-<时间戳>/*.txt         原始输出（pub-outdated / analyze-suggestions / ...）
#
# 为什么单独一个脚本：
# - 本仓刻意跟最新 stable，「最新」是否仍然可解析、AGP/KGP 是否仍能被 Flutter 识别、
#   Android CLI 是哪个版本，这三件事跨 pub / Gradle / Android SDK，官方没有统一入口；
# - 升级前先看报告，避免把「依赖不可解析」和「构建脚本坏了」混在一起排查。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"
handle_help "$@"

command -v flutter >/dev/null 2>&1 || die "找不到 flutter"
command -v python3 >/dev/null 2>&1 || die "找不到 python3"

stamp="$(date +%Y%m%d-%H%M%S)"
out="$RUN_DIR/deps-$stamp"
summary="$out/summary.txt"
mkdir -p "$out"
: >"$summary"

run() {
  local slug="$1"
  shift
  log "== $slug"
  local status=ok
  if ! "$@" >"$out/$slug.txt" 2>&1; then
    status=fail
  fi
  printf '%-24s %s\n' "$slug" "$status" | tee -a "$summary"
}

run pub-outdated flutter pub outdated
run analyze-suggestions flutter analyze --suggestions --no-pub
run check-docs python3 "$PROJECT_DIR/tool/agent/check_docs.py" --toolchain

if [[ -x "$PROJECT_DIR/android/gradlew" ]]; then
  (
    cd "$PROJECT_DIR/android"
    ./gradlew -q buildEnvironment
  ) >"$out/gradle-environment.txt" 2>&1 || true
  printf '%-24s %s\n' "gradle-environment" "见 gradle-environment.txt" | tee -a "$summary"
else
  printf '%-24s %s\n' "gradle-environment" "skip（没有 android/gradlew）" | tee -a "$summary"
fi

android_bin="$ANDROID_CLI"
if ! command -v "$android_bin" >/dev/null 2>&1; then
  # 官方 install.sh 默认装到 ~/.local/bin，但不一定进了当前 shell 的 PATH。
  for candidate in "$HOME/.local/bin/android" "/usr/local/bin/android"; do
    if [[ -x "$candidate" ]]; then
      android_bin="$candidate"
      break
    fi
  done
fi
if command -v "$android_bin" >/dev/null 2>&1; then
  run android-cli-version "$android_bin" -V
else
  printf '%-24s %s\n' "android-cli-version" "skip（没有 $ANDROID_CLI）" | tee -a "$summary"
fi

log "报告已写入：$out"
log "先看 summary.txt；失败项在对应 *.txt 里查原始输出。"
