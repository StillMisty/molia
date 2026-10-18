#!/usr/bin/env bash
# 托盘内存采样：桌面进程 RSS 曲线 + `molia.memory` 转换日志
#
# 用法:
#   tool/agent/memory.sh                       # 持续采样（默认 5s 一次，Ctrl+C 汇总）
#   tool/agent/memory.sh --interval 2 --timeout 120
#   tool/agent/memory.sh --pid <pid>           # 指定进程（默认取第一个 molia）
#
# 说明:
# - 采样对象是正在运行的应用：先 `tool/agent/app.sh run -d linux`（真实显示加
#   `--window`，WSLg 会弹窗）；
# - 托盘隐藏 / 恢复需要在真实会话里点关闭 / 从托盘唤起；每次翻转应用会打一行
#   `molia.memory`（RSS + 图片缓存占用），脚本把新出现的行与原样 RSS 一起打印；
# - 结束时输出 min / 中位 / max，用于和 `docs/memory.md` 的基线对比；
# - Android 不在支持范围（托盘是桌面能力，移动端后台内存由系统托管）。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  sed -n '/^# 用法:/,/^# 说明:/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2
  exit 2
}

interval=5
timeout_s=0
pid=""

while (($#)); do
  case "$1" in
    --interval) interval="$2"; shift ;;
    --timeout) timeout_s="$2"; shift ;;
    --pid) pid="$2"; shift ;;
    -*) usage ;;
    *) usage ;;
  esac
  shift
done

[[ "$interval" =~ ^[0-9]+$ ]] && (( interval > 0 )) || usage
if [[ -z "$pid" ]]; then
  pid="$(pgrep -x "$APP_BINARY" | head -1 || true)"
fi
[[ -n "$pid" ]] || die "找不到运行中的 $APP_BINARY（先 tool/agent/app.sh run -d linux）"
kill -0 "$pid" 2>/dev/null || die "进程 $pid 不存在"

samples="$(mktemp "${TMPDIR:-/tmp}/molia-memory.XXXXXX")"
trap 'rm -f "$samples"' EXIT

# 只打印本次运行新出现的 molia.memory 行（日志跨轮次追加）。
log_from=0
if [[ -f "$RUN_LOG" ]]; then
  log_from=$(wc -l <"$RUN_LOG")
fi

read_rss_mb() { # 当前进程 RSS（MB，取一位小数）
  awk '/VmRSS/{printf "%.1f", $2/1024}' "/proc/$pid/status" 2>/dev/null || true
}

log "采样 PID $pid，每 ${interval}s 一次${timeout_s:+，最长 ${timeout_s}s}；日志 $RUN_LOG"
start=$(date +%s)
while kill -0 "$pid" 2>/dev/null; do
  rss="$(read_rss_mb)"
  [[ -n "$rss" ]] || break
  printf '%s\n' "$rss" >>"$samples"
  printf '[%s] RSS=%sMB\n' "$(date +%H:%M:%S)" "$rss"

  if [[ -f "$RUN_LOG" ]]; then
    current=$(wc -l <"$RUN_LOG")
    if (( current > log_from )); then
      tail -n "+$((log_from + 1))" "$RUN_LOG" | grep -a 'molia\.memory' || true
      log_from="$current"
    fi
  fi

  if (( timeout_s > 0 )) && (( $(date +%s) - start >= timeout_s )); then
    break
  fi
  sleep "$interval"
done

if [[ -s "$samples" ]]; then
  python3 - "$samples" <<'PY'
import statistics, sys
values = [float(line) for line in open(sys.argv[1]) if line.strip()]
ordered = sorted(values)
print(
    '汇总：样本 %d，min %.1fMB，中位 %.1fMB，max %.1fMB'
    % (len(values), ordered[0], statistics.median(ordered), ordered[-1])
)
PY
else
  log "没有采到样本（进程在首个采样周期内退出？）"
fi
