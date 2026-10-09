#!/usr/bin/env bash
# Flutter 应用热重载控制（后台 flutter run + pid-file 信号）
#
# 用法:
#   tool/agent/app.sh run [--timeout N]   后台启动 flutter run，等待应用就绪后返回
#   tool/agent/app.sh reload              热重载（等同终端里按 r）
#   tool/agent/app.sh restart             热重启（等同终端里按 R）
#   tool/agent/app.sh stop                退出 flutter run 并停掉应用
#   tool/agent/app.sh log [N]             查看日志（默认最后 40 行）
#   tool/agent/app.sh status              查看运行状态
#
# 设计说明：
# - flutter run 在无 TTY 的后台运行，交互按键不可用；改用官方 --pid-file +
#   SIGUSR1（热重载）/ SIGUSR2（热重启）通道，适合 agent 脚本化调用；
# - 日志与 pid 文件固定在 /tmp/opencode/molia，便于其它脚本/agent 读取。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat >&2 <<'EOF'
用法:
  app.sh run [--timeout N]   # 启动并等待应用就绪（N 秒，默认 900）
  app.sh reload              # 热重载
  app.sh restart             # 热重启
  app.sh stop                # 停止
  app.sh log [N]             # 日志
  app.sh status              # 状态
EOF
  exit 2
}

run_pid() {
  [[ -f "$PID_FILE" ]] && cat "$PID_FILE"
}

run_alive() {
  local pid; pid="$(run_pid)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
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
    # pid 文件尚未写出时进程可能仍在构建，不能判定为退出
    if [[ -f "$PID_FILE" ]] && ! run_alive; then
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
  local timeout=900
  while (($#)); do
    case "$1" in
      --timeout) timeout="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done

  if run_alive; then
    log "flutter run 已在运行 (pid $(run_pid))，日志: $RUN_LOG"
    return 0
  fi

  ensure_adb
  wait_for_device 60

  mkdir -p "$RUN_DIR"
  rm -f "$PID_FILE" "$RUN_LOG"

  log "启动 flutter run -d $DEVICE_ID（首包需 Gradle 构建，日志: $RUN_LOG）"
  (
    cd "$PROJECT_DIR"
    # setsid 让进程脱离当前会话；脚本退出后 flutter run 继续存活
    setsid nohup flutter run -d "$DEVICE_ID" --pid-file "$PID_FILE" >"$RUN_LOG" 2>&1 &
  )

  wait_for_log 'Flutter run key commands|A Dart VM Service on' "$timeout" "应用已启动"
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
  local pid; pid="$(run_pid)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
  ensure_adb
  "$ADB" -s "$DEVICE_ID" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  log "flutter run 已停止"
}

cmd_log() {
  local n="${1:-40}"
  [[ -f "$RUN_LOG" ]] || die "还没有日志：$RUN_LOG"
  tail -n "$n" "$RUN_LOG"
}

cmd_status() {
  if run_alive; then
    echo "flutter run: 运行中 (pid $(run_pid))"
    grep -E 'Dart VM Service|Flutter run key commands|Error|error' "$RUN_LOG" 2>/dev/null | tail -3 || true
  else
    echo "flutter run: 未运行"
  fi
  [[ -f "$RUN_LOG" ]] && echo "日志: $RUN_LOG（app.sh log 查看）"
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
