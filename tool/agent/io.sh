#!/usr/bin/env bash
# 磁盘写入采样：SharedPreferences 整文件重写 / SQLite WAL / 进程 IO 差分
#
# 用法:
#   tool/agent/io.sh                       # 默认每 0.2s 采样，最长 60s
#   tool/agent/io.sh --interval 0.5 --timeout 120
#   tool/agent/io.sh --pid <pid>           # 指定进程（默认取第一个 molia）
#
# 说明:
# - 采样对象是正在运行的应用：先 `tool/agent/app.sh run -d linux`；
# - prefs 每次 set* 都会重写整个 `shared_preferences.json`：脚本按 mtime 变化
#   计一次写，并打印文件大小与相邻两次的增量；桌面封面元数据
#   `molia_artwork_cache.json` 同样按 mtime 计数（touch-only 优化后应保持 0）；
#   DB / WAL / SHM 只打印大小；
# - mtime 是轮询采样，快于 1/interval 的连续写入只能合并计数；本脚本用于
#   前后相对比较，不宣称精确 syscall 次数（需要精确值时用 strace / 应用内埋点）；
# - `/proc/<pid>/io` 在部分 WSL 内核不可读：缺文件时打印一行提示并继续，
#   不影响 prefs / DB 采样；
# - 只做观测，不是 CI 门槛；原始事件直接打印到 stdout。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  sed -n '/^# 用法:/,/^# 说明:/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2
  exit 2
}

interval=0.2
timeout_s=60
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

# sleep 支持小数；timeout 只接受整数秒，0 = 一直采样到进程退出 / Ctrl+C。
[[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
  awk -v value="$interval" 'BEGIN { exit !(value > 0) }' || usage
[[ "$timeout_s" =~ ^[0-9]+$ ]] || usage

data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/$APP_ID"
prefs="$data_dir/shared_preferences.json"
artwork_meta="$data_dir/molia_artwork_cache.json"
artwork_dir="$data_dir/artwork_cache"
db="$data_dir/molia_database_v2.sqlite"

if [[ -z "$pid" ]]; then
  pid="$(pgrep -x "$APP_BINARY" | head -1 || true)"
fi
[[ -n "$pid" ]] || die "找不到运行中的 $APP_BINARY（先 tool/agent/app.sh run -d linux）"
kill -0 "$pid" 2>/dev/null || die "进程 $pid 不存在"

file_size() { # 字节数；文件不存在 / stat 失败输出 -
  if [[ -f "$1" ]]; then
    stat -c %s "$1" 2>/dev/null || printf '%s' '-'
  else
    printf '%s' '-'
  fi
}

file_mtime() { # 纳秒级 mtime，用于识别一次整文件重写
  if [[ -f "$1" ]]; then
    stat -c %y "$1" 2>/dev/null || printf '%s' '-'
  else
    printf '%s' '-'
  fi
}

human_bytes() { # 字节数 → 人类可读；非数字输出 -
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || {
    printf '%s' '-'
    return
  }
  awk -v bytes="$value" 'BEGIN {
    split("B KB MB GB TB", units, " ")
    unit = 1
    while (bytes >= 1024 && unit < 5) {
      bytes /= 1024
      unit++
    }
    if (unit == 1) printf "%.0f%s", bytes, units[unit]
    else printf "%.1f%s", bytes, units[unit]
  }'
}

io_available=1
rchar=0
wchar=0
read_bytes=0
write_bytes=0

read_proc_io() { # 读 /proc/<pid>/io；不可读返回 1
  [[ -r "/proc/$pid/io" ]] || return 1
  local key value
  while read -r key value; do
    case "$key" in
      rchar:) rchar="$value" ;;
      wchar:) wchar="$value" ;;
      read_bytes:) read_bytes="$value" ;;
      write_bytes:) write_bytes="$value" ;;
    esac
  done <"/proc/$pid/io"
  [[ -n "$rchar" && -n "$wchar" && -n "$write_bytes" ]]
}

if ! read_proc_io; then
  io_available=0
  log "本机内核不提供 /proc/$pid/io（WSL 常见），跳过 rchar/wchar/read_bytes/write_bytes 差分"
fi

io_rchar_start=$rchar
io_wchar_start=$wchar
io_read_start=$read_bytes
io_write_start=$write_bytes

last_mtime="$(file_mtime "$prefs")"
last_size="$(file_size "$prefs")"
prefs_writes=0
last_artwork_mtime="$(file_mtime "$artwork_meta")"
last_artwork_size="$(file_size "$artwork_meta")"
artwork_writes=0
start="$(date +%s)"

log "采样 PID $pid，每 ${interval}s 一次${timeout_s:+，最长 ${timeout_s}s}；数据目录 $data_dir"
log "prefs=$prefs"

while kill -0 "$pid" 2>/dev/null; do
  mtime="$(file_mtime "$prefs")"
  size="$(file_size "$prefs")"

  if [[ "$mtime" != "$last_mtime" ]]; then
    prefs_writes=$((prefs_writes + 1))
    if [[ "$last_size" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ ]]; then
      delta="$((size - last_size))"
      delta_label="$(printf '%+d' "$delta")B"
    else
      delta_label='-'
    fi

    io_part=""
    if ((io_available)); then
      read_proc_io || true
      io_part=" · wchar +$(human_bytes "$((wchar - io_wchar_start))")"
      io_part+=" · write_bytes +$(human_bytes "$((write_bytes - io_write_start))")"
    fi

    printf '[%s] prefs 写入 #%d：%s（Δ%s）%s\n' \
      "$(date +%H:%M:%S)" "$prefs_writes" "$(human_bytes "$size")" \
      "$delta_label" "$io_part"
    last_mtime="$mtime"
    last_size="$size"
  fi

  artwork_mtime="$(file_mtime "$artwork_meta")"
  artwork_size="$(file_size "$artwork_meta")"
  if [[ "$artwork_mtime" != "$last_artwork_mtime" ]]; then
    artwork_writes=$((artwork_writes + 1))
    if [[ "$last_artwork_size" =~ ^[0-9]+$ && "$artwork_size" =~ ^[0-9]+$ ]]; then
      artwork_delta="$((artwork_size - last_artwork_size))"
      artwork_delta_label="$(printf '%+d' "$artwork_delta")B"
    else
      artwork_delta_label='-'
    fi
    printf '[%s] artwork 元数据写入 #%d：%s（Δ%s）\n' \
      "$(date +%H:%M:%S)" "$artwork_writes" \
      "$(human_bytes "$artwork_size")" "$artwork_delta_label"
    last_artwork_mtime="$artwork_mtime"
    last_artwork_size="$artwork_size"
  fi

  if ((timeout_s > 0)) && (($(date +%s) - start >= timeout_s)); then
    break
  fi
  sleep "$interval"
done

if ((io_available)); then
  read_proc_io || true
fi

artwork_files=0
artwork_bytes=0
if [[ -d "$artwork_dir" ]]; then
  artwork_files="$(find "$artwork_dir" -type f 2>/dev/null | wc -l)"
  artwork_bytes="$(du -sb "$artwork_dir" 2>/dev/null | cut -f1)"
fi

printf '\n汇总：prefs 写入 %d 次，artwork 元数据写入 %d 次；prefs %s，artwork 元数据 %s（%s 个文件 / %s），DB %s，WAL %s，SHM %s\n' \
  "$prefs_writes" "$artwork_writes" \
  "$(human_bytes "$(file_size "$prefs")")" \
  "$(human_bytes "$(file_size "$artwork_meta")")" \
  "$artwork_files" "$(human_bytes "$artwork_bytes")" \
  "$(human_bytes "$(file_size "$db")")" \
  "$(human_bytes "$(file_size "$db-wal")")" \
  "$(human_bytes "$(file_size "$db-shm")")"

if ((io_available)); then
  printf '进程 IO 差分：rchar +%s（%s）· wchar +%s（%s）· read_bytes +%s（%s）· write_bytes +%s（%s）\n' \
    "$((rchar - io_rchar_start))" "$(human_bytes "$((rchar - io_rchar_start))")" \
    "$((wchar - io_wchar_start))" "$(human_bytes "$((wchar - io_wchar_start))")" \
    "$((read_bytes - io_read_start))" "$(human_bytes "$((read_bytes - io_read_start))")" \
    "$((write_bytes - io_write_start))" "$(human_bytes "$((write_bytes - io_write_start))")"
else
  log "/proc/$pid/io 不可用，未采到进程读写字节差分"
fi
