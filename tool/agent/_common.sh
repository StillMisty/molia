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

# 运行产物目录
RUN_DIR="${RUN_DIR:-/tmp/opencode/molia}"
SHOT_DIR="${SHOT_DIR:-$RUN_DIR/shots}"
PID_FILE="$RUN_DIR/flutter-run.pid"
RUN_LOG="$RUN_DIR/flutter-run.log"

log() { printf '[agent] %s\n' "$*" >&2; }
die() { printf '[agent] ERROR: %s\n' "$*" >&2; exit 1; }

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
