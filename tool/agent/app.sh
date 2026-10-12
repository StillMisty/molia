#!/usr/bin/env bash
# Flutter 应用热重载控制（后台 flutter run + pid-file 信号）
#
# 用法:
#   tool/agent/app.sh run [-d linux|<serial>] [--timeout N]  后台启动 flutter run，就绪后返回
#   tool/agent/app.sh reload                                  热重载（等同终端里按 r）
#   tool/agent/app.sh restart                                 热重启（等同终端里按 R）
#   tool/agent/app.sh stop                                    退出 flutter run 并停掉应用
#   tool/agent/app.sh log [N]                                 查看日志（默认最后 40 行）
#   tool/agent/app.sh status                                  查看运行状态
#
# 设计说明：
# - flutter run 在无 TTY 的后台运行，交互按键不可用；改用官方 --pid-file +
#   SIGUSR1（热重载）/ SIGUSR2（热重启）通道，适合 agent 脚本化调用；
# - 设备默认取 $DEVICE_ID（Android 模拟器）；-d linux 走桌面热重载（免模拟器，
#   无 DISPLAY 时自动套 xvfb-run）。运行设备记入 $RUN_DEVICE_FILE，
#   reload/stop/status 均按记录设备行事；
# - 日志与 pid 文件固定在 /tmp/opencode/molia，便于其它脚本/agent 读取。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat >&2 <<'EOF'
用法:
  app.sh run [-d linux|<serial>] [--timeout N]   # 启动并等待就绪（默认 $DEVICE_ID）
  app.sh reload                                   # 热重载
  app.sh restart                                  # 热重启
  app.sh stop                                     # 停止
  app.sh log [N]                                  # 日志
  app.sh status                                   # 状态
EOF
  exit 2
}

run_pid() {
  # 文件不存在时保持返回 0：调用方一律在 set -e 下用赋值接住
  cat "$PID_FILE" 2>/dev/null || true
}

run_device() {
  cat "$RUN_DEVICE_FILE" 2>/dev/null || true
}

run_alive() {
  local pid; pid="$(run_pid)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || return 1
  # pid 复用防护：flutter 正常退出会删 pid 文件，残留 pid 若被系统复用，
  # SIGUSR1/SIGUSR2 会打到无关进程，故核对一次 cmdline
  [[ -r "/proc/$pid/cmdline" ]] || return 0
  grep -qa flutter "/proc/$pid/cmdline"
}

# pid 文件尚未写出时的兜底存活判断：构建/设备阶段就失败时 flutter 直接退出、
# pid 文件不会出现，只能按命令行里唯一的 --pid-file 路径匹配进程
flutter_run_alive() {
  command -v pgrep >/dev/null 2>&1 || return 0 # 没有 pgrep 时保守认为存活
  pgrep -f -- "--pid-file $PID_FILE" >/dev/null 2>&1
}

log_lines() { # 当前日志行数（文件不存在时返回 0）
  if [[ -f "$RUN_LOG" ]]; then
    wc -l < "$RUN_LOG"
  else
    echo 0
  fi
}

wait_for_log() { # pattern timeout message [start_line]
  local pattern="$1" timeout="$2" message="$3" from="${4:-1}" start
  start=$(date +%s)
  while :; do
    # 只匹配 from 之后的新日志，避免命中上一次操作的旧记录
    if tail -n +"$from" "$RUN_LOG" 2>/dev/null | grep -qE "$pattern"; then
      log "$message"
      return 0
    fi
    # 进程消失即失败（20s 竞态余量：启动命令刚 fork 时进程尚未出现），
    # 避免构建失败时白等满超时
    if (( $(date +%s) - start > 20 )) && ! flutter_run_alive; then
      log "flutter run 已退出，日志尾部："
      tail -30 "$RUN_LOG" >&2 || true
      return 1
    fi
    if (( $(date +%s) - start > timeout )); then
      log "等待超时（${timeout}s）：$message；日志：$RUN_LOG"
      tail -15 "$RUN_LOG" >&2 || true
      return 1
    fi
    sleep 3
  done
}

cmd_run() {
  local timeout=900 device="$DEVICE_ID" headless=0
  while (($#)); do
    case "$1" in
      --timeout) timeout="$2"; shift ;;
      -d|--device) device="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done

  if run_alive; then
    local d; d="$(run_device)"
    log "flutter run 已在运行 (pid $(run_pid)${d:+, 设备 $d})，日志: $RUN_LOG"
    return 0
  fi

  case "$device" in
    linux)
      if ! has_display; then
        command -v xvfb-run >/dev/null 2>&1 ||
          die "无 DISPLAY/WAYLAND_DISPLAY 且缺少 xvfb-run（Arch: pacman -S xorg-server-xvfb）"
        headless=1
      fi
      ;;
    macos|windows)
      die "本脚本只支持 linux 桌面与 Android 设备（当前: $device）"
      ;;
    *)
      DEVICE_ID="$device" # wait_for_device 以 DEVICE_ID 为准
      ensure_adb
      wait_for_device 60
      ;;
  esac

  local -a cmd=(flutter run -d "$device" --pid-file "$PID_FILE")
  (( headless )) && cmd=(xvfb-run -a "${cmd[@]}")

  mkdir -p "$RUN_DIR"
  rm -f "$PID_FILE" "$RUN_LOG" "$RUN_DEVICE_FILE"
  printf '%s\n' "$device" > "$RUN_DEVICE_FILE"

  local build_hint=Gradle headless_hint=
  [[ "$device" == linux ]] && build_hint=CMake
  (( headless )) && headless_hint="；headless: xvfb-run"
  log "启动 flutter run -d $device（首包需 ${build_hint} 构建${headless_hint}，日志: $RUN_LOG）"
  (
    cd "$PROJECT_DIR"
    # setsid 让进程脱离当前会话；脚本退出后 flutter run 继续存活
    setsid nohup "${cmd[@]}" >"$RUN_LOG" 2>&1 &
  )

  wait_for_log 'Flutter run key commands|A Dart VM Service on' "$timeout" "应用已启动（$device）"
}

cmd_reload() {
  run_alive || die "flutter run 未在运行（先执行 app.sh run）"
  local pid from; pid="$(run_pid)"
  from=$(( $(log_lines) + 1 ))
  kill -USR1 "$pid"
  wait_for_log 'Reloaded [0-9]+( of [0-9]+)? libraries' 120 "热重载完成" "$from"
}

cmd_restart() {
  run_alive || die "flutter run 未在运行（先执行 app.sh run）"
  local pid from; pid="$(run_pid)"
  from=$(( $(log_lines) + 1 ))
  kill -USR2 "$pid"
  wait_for_log 'Restarted application in' 180 "热重启完成" "$from"
}

cmd_stop() {
  local pid device; pid="$(run_pid)"; device="$(run_device)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
      # SIGTERM 无效才强杀；强杀不触发 flutter 收尾，桌面进程可能残留，兜底清理
      kill -9 "$pid" 2>/dev/null || true
      if [[ "$device" == linux ]]; then
        pkill -xf "$PROJECT_DIR/build/linux/x64/debug/bundle/$APP_BINARY" 2>/dev/null || true
      fi
    fi
  fi
  rm -f "$PID_FILE" "$RUN_DEVICE_FILE"
  if [[ "$device" != linux ]]; then
    ensure_adb
    "$ADB" -s "${device:-$DEVICE_ID}" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  fi
  log "flutter run 已停止${device:+（设备 $device）}"
}

cmd_log() {
  local n="${1:-40}"
  [[ -f "$RUN_LOG" ]] || die "还没有日志：$RUN_LOG"
  tail -n "$n" "$RUN_LOG"
}

cmd_status() {
  local device; device="$(run_device)"
  if run_alive; then
    echo "flutter run: 运行中 (pid $(run_pid)${device:+, 设备 $device})"
    local uri
    uri="$(grep -oE 'http://127\.[0-9.]+:[0-9]+/[A-Za-z0-9_=/-]+' "$RUN_LOG" 2>/dev/null | head -1 || true)"
    [[ -n "$uri" ]] && echo "VM Service: $uri"
  else
    if [[ -f "$PID_FILE" ]]; then
      echo "flutter run: 未运行（残留 pid 文件，app.sh run 时自动清理）"
    else
      echo "flutter run: 未运行"
    fi
    [[ -n "$device" ]] && echo "上次设备: $device"
  fi
  [[ -f "$RUN_LOG" ]] && echo "日志: $RUN_LOG（app.sh log 查看）"
  return 0
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift
case "$cmd" in
  run) cmd_run "$@" ;;
  reload) cmd_reload "$@" ;;
  restart) cmd_restart "$@" ;;
  stop) cmd_stop "$@" ;;
  log) cmd_log "$@" ;;
  status) cmd_status "$@" ;;
  *) usage ;;
esac
