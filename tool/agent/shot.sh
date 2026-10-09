#!/usr/bin/env bash
# 设备截图（agent 的"眼睛"）：PNG 写到 /tmp/opencode/molia/shots/ 并打印路径
#
# 用法:
#   tool/agent/shot.sh [name] [--annotate]
#
# 说明:
# - 默认用 Android CLI 的 `android screen capture`（官方 agent 工具）；
#   失败时回退到 `adb exec-out screencap -p`；
# - --annotate 会叠加带编号的 UI 元素框，配合 `ui.sh resolve` 定位点击坐标；
# - 只在 stdout 打印最终 PNG 路径，便于脚本/agent 直接读取。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  echo "用法: shot.sh [name] [--annotate]" >&2
  exit 2
}

name="screen"
annotate=0
while (($#)); do
  case "$1" in
    --annotate) annotate=1 ;;
    -*) usage ;;
    *) name="$1" ;;
  esac
  shift
done

ensure_adb
wait_for_device 30
mkdir -p "$SHOT_DIR"

out="$SHOT_DIR/${name}-$(date +%H%M%S).png"

ok=0
if (( annotate )); then
  "$ANDROID_CLI" screen capture --annotate -o "$out" >/dev/null 2>&1 && ok=1
else
  "$ANDROID_CLI" screen capture -o "$out" >/dev/null 2>&1 && ok=1
fi

if (( ! ok )) || [[ ! -s "$out" ]]; then
  "$ADB" -s "$DEVICE_ID" exec-out screencap -p > "$out" 2>/dev/null || true
fi

[[ -s "$out" ]] || die "截图失败（设备: $DEVICE_ID）"
echo "$out"
