#!/usr/bin/env bash
# 集成测试运行器：官方 flutter test 路径（Linux 桌面 / Android 模拟器）
#
# 用法:
#   tool/agent/test.sh linux                 # -d linux；无 DISPLAY 时自动套 xvfb-run
#   tool/agent/test.sh android [serial]      # 默认取运行中的模拟器（未起则提示 emu.sh start）
#   tool/agent/test.sh all [serial]          # 先 linux 后 android（任一失败即停）
#
# 选项:
#   --file <path>      集成测试文件（默认 integration_test/lx_engine_integration_test.dart）
#   --timeout <秒>     墙钟超时（默认 linux 900 / android 1800；Android 首次 Gradle 构建需放宽）
#   --no-pub           跳过 flutter pub get（仅本地快速迭代；发布/首次构建勿用，见 pitfalls #15）
#   --no-xvfb          无 DISPLAY 时不套 xvfb-run（用于直接观察启动报错）
#   --no-uninstall     Android 跑完保留安装（调试安装态时用；默认卸载）
#
# 设计说明:
# - 判定只看 flutter test 退出码：设备侧异常会被捕获上报，失败必为非零，不依赖人工看截图；
# - 日志写 /tmp/opencode/molia/it-<platform>-<时间戳>.log，失败时回显尾部 40 行；
# - Android 由 flutter test 自动构建并安装 debug APK（不需要先 flutter build apk）。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat >&2 <<'EOF'
用法:
  test.sh linux [--timeout N] [--no-pub] [--no-xvfb]
  test.sh android [serial] [--timeout N] [--no-pub] [--no-uninstall]
  test.sh all [serial] [--timeout N] [--no-pub]

公共选项:
  --file <path>   集成测试文件（默认 integration_test/lx_engine_integration_test.dart）
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
platform="$1"; shift

test_file="integration_test/lx_engine_integration_test.dart"
timeout_s=""
serial=""
no_pub=0
use_xvfb=1
extra_flags=()

case "$platform" in
  linux|android|all) ;;
  *) usage ;;
esac

while (($#)); do
  case "$1" in
    --file) test_file="$2"; shift ;;
    --timeout) timeout_s="$2"; shift ;;
    --no-pub) no_pub=1 ;;
    --no-xvfb) use_xvfb=0 ;;
    --no-uninstall) extra_flags+=(--no-uninstall) ;;
    -*) usage ;;
    *)
      [[ "$platform" == "android" || "$platform" == "all" ]] || usage
      [[ -z "$serial" ]] || usage
      serial="$1"
      ;;
  esac
  shift
done

run_one() { # platform
  local platform="$1"
  local timeout="${timeout_s:-}"
  if [[ -z "$timeout" ]]; then
    if [[ "$platform" == "android" ]]; then timeout=1800; else timeout=900; fi
  fi

  cd "$PROJECT_DIR"

  local device prefix=()
  if [[ "$platform" == "linux" ]]; then
    device="linux"
    if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" && $use_xvfb -eq 1 ]]; then
      command -v xvfb-run >/dev/null 2>&1 ||
        die "无 DISPLAY 且缺少 xvfb-run：先装 xvfb（pacman -S xorg-server-xvfb / apt install xvfb），或用 --no-xvfb 直接跑看报错"
      prefix=(xvfb-run -a)
      log "未检测到 DISPLAY，使用 xvfb-run -a"
    fi
  else
    device="${serial:-}"
    ensure_adb
    if [[ -z "$device" ]]; then
      device="$(running_emulator)"
    fi
    [[ -n "$device" ]] ||
      die "没有运行中的模拟器（也未指定 serial）：先执行 tool/agent/emu.sh start"
    DEVICE_ID="$device" # wait_for_device 以 DEVICE_ID 为准
    log "等待设备 $device 就绪"
    wait_for_device 120
  fi

  local -a reporter=()
  [[ -t 1 ]] || reporter=(-r expanded) # 非 TTY（CI/子代理）逐行输出，便于日志检索

  local -a cmd=(timeout --foreground "$timeout" "${prefix[@]}"
    flutter test "$test_file" -d "$device" "${reporter[@]}")
  (( no_pub )) && cmd+=(--no-pub)
  cmd+=("${extra_flags[@]}")

  mkdir -p "$RUN_DIR"
  local log_file="$RUN_DIR/it-$platform-$(date +%Y%m%d-%H%M%S).log"
  log "运行: ${cmd[*]}"
  log "日志: $log_file"

  local rc=0
  set +e
  "${cmd[@]}" 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e

  if ((rc == 124)); then
    log "墙钟超时（${timeout}s）被终止；Android 首次 Gradle/冷启动请加 --timeout"
    tail -40 "$log_file" >&2 || true
  elif ((rc != 0)); then
    log "测试失败（exit=$rc），日志尾部："
    tail -40 "$log_file" >&2 || true
  else
    log "测试通过（$platform，日志: $log_file）"
  fi
  return "$rc"
}

case "$platform" in
  linux) run_one linux ;;
  android) run_one android ;;
  all)
    run_one linux
    run_one android
    ;;
esac
