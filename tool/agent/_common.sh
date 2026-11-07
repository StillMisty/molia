#!/usr/bin/env bash
# 公共变量与辅助函数（被同目录脚本 source）
#
# 设计说明：
# - 全部基于 WSL 内的 Android CLI + 本机 KVM 模拟器，不依赖 Windows 侧任何组件；
# - 日志/截图/pid 统一放在 /tmp/opencode/molia（临时目录，重启可清），
#   截图路径会打印出来供 agent 用 read 工具直接查看 PNG。
set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$AGENT_DIR/../.." && pwd)"

# Android SDK：优先环境变量；默认用户态安装目录
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/Android/Sdk}"
ADB="${ADB:-$ANDROID_SDK_ROOT/platform-tools/adb}"
# AUR 管理的 android-cli（更新走 paru，不用 CLI 自带 android update）
ANDROID_CLI="${ANDROID_CLI:-android}"

# 模拟器与目标应用
AVD_NAME="${AVD_NAME:-molia_api37}"
DEVICE_ID="${DEVICE_ID:-emulator-5554}"
APP_ID="${APP_ID:-top.stillmisty.molia}"
APP_BINARY="${APP_BINARY:-molia}" # 桌面构建产物名（linux/CMakeLists.txt 的 BINARY_NAME）

# 运行产物目录
RUN_DIR="${RUN_DIR:-/tmp/opencode/molia}"
SHOT_DIR="${SHOT_DIR:-$RUN_DIR/shots}"
PID_FILE="$RUN_DIR/flutter-run.pid"
RUN_LOG="$RUN_DIR/flutter-run.log"
RUN_DEVICE_FILE="$RUN_DIR/flutter-run.device" # app.sh 记录本次 flutter run 的设备

# 单实例逃生口：本机开发实例在跑时，agent 启动的测试 / 热重载实例必须仍能
# 起来（否则会被单实例逻辑当成第二实例直接退出）。只影响 agent 脚本拉起的
# 进程，正常双击启动的应用不受影响。
export MOLIA_SINGLE_INSTANCE_DISABLED=1

log() { printf '[agent] %s\n' "$*" >&2; }
die() { printf '[agent] ERROR: %s\n' "$*" >&2; exit 1; }

# 是否有图形显示（Linux 桌面运行需要；test.sh 默认套 xvfb-run，app.sh 无显示时套）
has_display() { [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; }

# 停应用：按可执行名精确匹配，避免 `pkill -f <长路径>` 把调用它的 shell 一起
# 杀掉（agent 手动调试时踩过）。脚本统一走这里。
kill_app() {
  command -v pkill >/dev/null 2>&1 || return 0
  pkill -x "$APP_BINARY" 2>/dev/null || true
}

# Linux 显示前缀：默认无条件 Xvfb，避免 WSLg 下把窗口弹到 Windows 桌面；
# 传 1 表示用当前真实显示（脚本的 --window）。调用方展开
# `"${LINUX_DISPLAY_PREFIX[@]}"`；GDK_BACKEND / WAYLAND_DISPLAY 的细节见
# test.sh：只改 DISPLAY 不够，GDK 见到 WAYLAND_DISPLAY 会优先连真实合成器。
linux_display_prefix() {
  local real_display="${1:-0}"
  LINUX_DISPLAY_PREFIX=()
  if ((real_display)); then
    return 0
  fi
  command -v xvfb-run >/dev/null 2>&1 ||
    die "缺少 xvfb-run（装 xorg-server-xvfb，或显式使用 --window 跑真实显示）"
  LINUX_DISPLAY_PREFIX=(env -u WAYLAND_DISPLAY GDK_BACKEND=x11 xvfb-run -a)
}

# ---- Linux release 构建卫生（perf.sh / startup.sh 共用）--------------------
# release install 会原样复制 build/flutter_assets，debug/profile 留下的
# kernel_blob.bin 会一直带进 bundle；--analyze-size 还会把非 release 引擎
# 留在 linux/flutter/ephemeral（正常 release 约 17MB，污染时约 42MB）。
LINUX_RELEASE_BUNDLE="$PROJECT_DIR/build/linux/x64/release/bundle"
LINUX_RELEASE_ENGINE_MAX_BYTES=$((20 * 1024 * 1024))

# 体积测量 / 发布打包用：三处都可能被上一次不同模式的构建污染，全部重建。
# 只删这三个路径，保留 build/linux/x64/release 其余内容——media_kit 的
# mimalloc tarball 在那里，受限网络下重新下载会失败。
linux_clean_release_inputs() {
  rm -rf "$PROJECT_DIR/build/flutter_assets" \
         "$PROJECT_DIR/linux/flutter/ephemeral" \
         "$LINUX_RELEASE_BUNDLE"
}

# 启动采样用：只清 install 产物与 assets；正常引擎保留给增量构建，
# 只有明显不是 release 的引擎（--analyze-size 等）才删 ephemeral。
linux_clean_release_inputs_incremental() {
  rm -rf "$PROJECT_DIR/build/flutter_assets" "$LINUX_RELEASE_BUNDLE"
  local engine="$PROJECT_DIR/linux/flutter/ephemeral/libflutter_linux_gtk.so"
  if [[ -f "$engine" ]] &&
     (( $(stat -c%s "$engine") > LINUX_RELEASE_ENGINE_MAX_BYTES )); then
    log "linux/flutter/ephemeral 引擎 $(du -h "$engine" | cut -f1) 不是 release（通常约 17MB），删掉后重建"
    rm -rf "$PROJECT_DIR/linux/flutter/ephemeral"
  fi
}

# 构建后校验：脏产物直接失败，避免把体积 / 启动数据记到错误基线。
linux_assert_release_bundle() {
  local bundle="${1:-$LINUX_RELEASE_BUNDLE}"
  [[ ! -e "$bundle/data/flutter_assets/kernel_blob.bin" ]] ||
    die "release bundle 含 kernel_blob.bin：build/flutter_assets 残留 debug 产物（删掉后重新构建）"
  local engine="$bundle/lib/libflutter_linux_gtk.so"
  [[ -f "$engine" ]] || die "bundle 缺少 libflutter_linux_gtk.so：$bundle"
  local bytes
  bytes="$(stat -c%s "$engine")"
  if (( bytes > LINUX_RELEASE_ENGINE_MAX_BYTES )); then
    die "libflutter_linux_gtk.so $((bytes / 1024 / 1024))MB 超过 20MB：linux/flutter/ephemeral 是非 release 引擎（常见于跑过 --analyze-size）；删掉 linux/flutter/ephemeral 后重新构建"
  fi
}

# 列出已连接设备（序列号）
adb_devices() {
  "$ADB" devices | awk 'NR>1 && $2=="device" {print $1}'
}

# 找到第一个运行中的模拟器序列号
running_emulator() {
  adb_devices | grep -m1 '^emulator-' || true
}

# 确保 SDK 内 adb server 已就绪（只用 WSL 侧 server）
ensure_adb() {
  [[ -x "$ADB" ]] || die "未找到 adb：$ADB（先执行 tool/agent/setup.sh，或设 ADB=/path/to/adb）"
  "$ADB" start-server >/dev/null 2>&1 || true
}

# 等目标设备就绪（默认等 DEVICE_ID）
wait_for_device() {
  local timeout="${1:-180}" start
  start=$(date +%s)
  while :; do
    if "$ADB" -s "$DEVICE_ID" get-state >/dev/null 2>&1; then
      return 0
    fi
    if (( $(date +%s) - start > timeout )); then
      die "等待设备 ${DEVICE_ID} 超时（${timeout}s）"
    fi
    sleep 2
  done
}
