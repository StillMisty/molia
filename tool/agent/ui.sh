#!/usr/bin/env bash
# 设备交互薄封装：UI 树 / 点击 / 滑动 / 文本 / 按键 / 应用启停
#
# 用法:
#   tool/agent/ui.sh layout [--pretty] [--full]   输出 UI 布局树 JSON（默认 pretty）
#   tool/agent/ui.sh tap X Y                      点击坐标
#   tool/agent/ui.sh swipe X1 Y1 X2 Y2 [ms]       滑动（默认 300ms）
#   tool/agent/ui.sh text "要输入的文字"          输入文本（空格自动转 %s）
#   tool/agent/ui.sh key KEYCODE                  发送按键（如 66=回车，4=返回）
#   tool/agent/ui.sh launch                       启动已安装的应用
#   tool/agent/ui.sh force-stop                   强制停止应用
#   tool/agent/ui.sh resolve 截图.png "#3"        把标注截图里的 #N 解析为 "tap X Y"
#
# 说明:
# - Flutter 的 semantics 节点在 layout 中可能不完整，视觉定位用
#   `shot.sh --annotate` + `ui.sh resolve` 配合；
# - 输入文本前确保输入框已聚焦（见 android-cli skill 的 interact 参考）。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift
case "$cmd" in
  layout)
    ensure_adb; wait_for_device 30
    "$ANDROID_CLI" layout --pretty "$@"
    ;;
  tap)
    [[ $# -eq 2 ]] || usage
    ensure_adb
    "$ADB" -s "$DEVICE_ID" shell input tap "$1" "$2"
    ;;
  swipe)
    [[ $# -ge 4 ]] || usage
    ensure_adb
    "$ADB" -s "$DEVICE_ID" shell input swipe "$1" "$2" "$3" "$4" "${5:-300}"
    ;;
  text)
    [[ $# -ge 1 ]] || usage
    ensure_adb
    local t="$*"
    "$ADB" -s "$DEVICE_ID" shell input text "${t// /%s}"
    ;;
  key)
    [[ $# -eq 1 ]] || usage
    ensure_adb
    "$ADB" -s "$DEVICE_ID" shell input keyevent "$1"
    ;;
  launch)
    ensure_adb
    "$ADB" -s "$DEVICE_ID" shell am start -n "$APP_ID/.MainActivity"
    ;;
  force-stop)
    ensure_adb
    "$ADB" -s "$DEVICE_ID" shell am force-stop "$APP_ID"
    ;;
  resolve)
    [[ $# -eq 2 ]] || usage
    "$ANDROID_CLI" screen resolve --screen "$1" --string "$2"
    ;;
  *) usage ;;
esac
