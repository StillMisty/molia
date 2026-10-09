#!/usr/bin/env bash
# 模拟器生命周期管理（包装 Android CLI + adb）
#
# 用法:
#   tool/agent/emu.sh start [--headless|--window] [--cold]   启动 AVD（默认 headless，阻塞到完全就绪）
#   tool/agent/emu.sh stop [serial]                          停止模拟器（默认取运行中的 emulator-*）
#   tool/agent/emu.sh status                                 查看 AVD 与设备状态
#
# 设计说明：
# - WSL 内原生模拟器（KVM + swiftshader 软渲染，WSLg 无 GL 直通）；
# - headless 是 agent 默认模式：无窗口、截图仍可用（android screen capture / adb screencap）；
# - window 模式经 WSLg 显示，供人工观察。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat >&2 <<'EOF'
用法:
  emu.sh start [--headless|--window] [--cold]   # 启动（默认 --headless）
  emu.sh stop [serial]                          # 停止
  emu.sh status                                 # 状态
EOF
  exit 2
}

cmd_start() {
  local headless=1 cold=0
  while (($#)); do
    case "$1" in
      --headless) headless=1 ;;
      --window) headless=0 ;;
      --cold) cold=1 ;;
      *) usage ;;
    esac
    shift
  done

  ensure_adb
  local serial
  serial="$(running_emulator)"
  if [[ -n "$serial" ]]; then
    log "模拟器已在运行: $serial"
    return 0
  fi

  local args=(emulator start)
  (( cold )) && args+=(--cold)
  (( headless )) && args+=(--headless)
  args+=("$AVD_NAME")

  log "启动模拟器: $ANDROID_CLI ${args[*]}（冷启动通常 1-3 分钟）"
  "$ANDROID_CLI" "${args[@]}"
  log "模拟器就绪: $(running_emulator)"
}

cmd_stop() {
  local serial="${1:-}"
  if [[ -z "$serial" ]]; then
    ensure_adb
    serial="$(running_emulator)"
  fi
  [[ -n "$serial" ]] || die "没有找到运行中的模拟器"

  # 优先走 Android CLI；失败时退回 adb emu kill
  if ! "$ANDROID_CLI" emulator stop "$serial" 2>/dev/null; then
    "$ADB" -s "$serial" emu kill >/dev/null 2>&1 || true
  fi
  log "已停止: $serial"
}

cmd_status() {
  ensure_adb
  echo "== AVD =="
  "$ANDROID_CLI" emulator list 2>/dev/null || true
  echo "== 设备 =="
  "$ADB" devices
  local serial
  serial="$(running_emulator)"
  if [[ -n "$serial" ]]; then
    echo "== 启动状态 ($serial) =="
    "$ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r'
  fi
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift
case "$cmd" in
  start) cmd_start "$@" ;;
  stop) cmd_stop "$@" ;;
  status) cmd_status "$@" ;;
  *) usage ;;
esac
