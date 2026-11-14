#!/usr/bin/env bash
# 启动首帧烟测：真实 main() + provider tree，在 Xvfb 里跑一次。
#
# 用法:
#   tool/agent/smoke.sh linux [--timeout N]
#
# 为什么需要：单元 / widget 测试不会走 `main()` 和 `buildAppProviders`；
# runApp 前的 Provider 校验、平台初始化异常会让窗口一直黑屏，但 `flutter test`
# 仍然全绿。本脚本只关心「日志出现 `molia.startup: 首帧`」，并在此之前的
# Unhandled Exception 直接判失败。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  echo "用法: smoke.sh linux [--timeout N]" >&2
  exit 2
}

platform="${1:-}"
shift || true
[[ "$platform" == "linux" ]] || usage

timeout_s=120
while (($#)); do
  case "$1" in
    --timeout) timeout_s="$2"; shift ;;
    *) usage ;;
  esac
  shift
done

cd "$PROJECT_DIR"

# 干净实例：旧 app 可能已经跑着，app.sh run 会直接返回旧会话。
"$AGENT_DIR/app.sh" stop >/dev/null 2>&1 || true

log "启动真实应用（Xvfb + 软件 GL），等待首帧..."
# 无 DISPLAY 时 app.sh 自动套 xvfb-run；这里显式去掉 WSLg 的 DISPLAY /
# WAYLAND_DISPLAY，保证烟测始终 headless、可重复。
if ! env -u DISPLAY -u WAYLAND_DISPLAY \
  GDK_BACKEND=x11 \
  LIBGL_ALWAYS_SOFTWARE=1 \
  XVFBARGS="-screen 0 1920x1080x24" \
  "$AGENT_DIR/app.sh" run -d linux --timeout 300 >/dev/null; then
  log "应用进程未能启动；日志尾部："
  tail -40 "$RUN_LOG" >&2 || true
  exit 1
fi

deadline=$((SECONDS + timeout_s))
while (( SECONDS < deadline )); do
  if grep -q "molia.startup: 首帧" "$RUN_LOG" 2>/dev/null; then
    log "首帧 OK：$(grep "molia.startup: 首帧" "$RUN_LOG" | tail -1)"
    "$AGENT_DIR/app.sh" stop >/dev/null 2>&1 || true
    exit 0
  fi

  if ! "$AGENT_DIR/app.sh" status 2>/dev/null | grep -q "运行中"; then
    log "应用在首帧前退出；日志尾部："
    tail -60 "$RUN_LOG" >&2 || true
    exit 1
  fi

  # 首帧前的 Unhandled Exception 视为启动失败；DBus / 省流检测这类
  # 平台告警是已知无害项，排除掉，避免把正常启动误判成失败。
  fatal="$(grep -n "Unhandled Exception" "$RUN_LOG" 2>/dev/null |
    grep -v "DBus.Error.ServiceUnknown" | head -1 || true)"
  if [[ -n "$fatal" ]]; then
    log "首帧前出现 Unhandled Exception："
    echo "$fatal" >&2
    grep -n -A12 "Unhandled Exception" "$RUN_LOG" | head -40 >&2 || true
    "$AGENT_DIR/app.sh" stop >/dev/null 2>&1 || true
    exit 1
  fi

  sleep 1
done

log "等待首帧超时（${timeout_s}s）；日志尾部："
tail -60 "$RUN_LOG" >&2 || true
"$AGENT_DIR/app.sh" stop >/dev/null 2>&1 || true
exit 1
