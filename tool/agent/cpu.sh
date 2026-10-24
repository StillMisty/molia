#!/usr/bin/env bash
# CPU 占用采样：按线程拆 UI / raster / IO / mpv / Dart worker，便于定位
# 「谁在烧 CPU」而不是只看进程总占用。
#
# 用法:
#   tool/agent/cpu.sh linux [--pid PID] [--name molia] [--duration 10] [--interval 1]
#   tool/agent/cpu.sh android [serial] [--pid PID] [--duration 10] [--interval 1]
#
# 说明:
# - Linux 读 /proc/<pid>/task/*/stat 的 utime+stime 差分（不依赖 pidstat）；
#   100% = 一个核，多核机器上进程总占比可以超过 100%；
# - Android 用 `adb shell top -H -b -n 2`（两次采样取差分；模拟器绝对数只做
#   相对比较，且软件渲染会显著放大 raster / gpu 线程）；
# - 不启动 / 不停止应用：采样期间应用由调用方（perf.sh / app.sh）负责；
# - 输出一段可直接贴进文档的表格；原始数据落在 $RUN_DIR/cpu-<平台>-<时间戳>.txt。

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  sed -n '/^# 用法:/,/^# 说明:/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2
  exit 2
}

platform=""
serial=""
pid=""
name="molia"
duration=10
interval=1

[[ $# -ge 1 ]] || usage
platform="$1"; shift
case "$platform" in
  linux) ;;
  android) ensure_adb ;;
  *) usage ;;
esac

while (($#)); do
  case "$1" in
    --pid) pid="$2"; shift ;;
    --name) name="$2"; shift ;;
    --duration) duration="$2"; shift ;;
    --interval) interval="$2"; shift ;;
    -*) usage ;;
    *)
      [[ "$platform" == android ]] || usage
      serial="$1"
      ;;
  esac
  shift
done

case "$duration" in
  ''|*[!0-9]*) die "--duration 必须是整数秒" ;;
esac
(( duration > 0 )) || die "--duration 必须 > 0"

stamp="$(date +%Y%m%d-%H%M%S)"
out="$RUN_DIR/cpu-${platform}-$stamp.txt"
mkdir -p "$RUN_DIR"

# ---- Linux -----------------------------------------------------------------
sample_linux() {
  if [[ -z "$pid" ]]; then
    pid="$(pgrep -f "$PROJECT_DIR/build/linux/x64/release/bundle/$APP_BINARY" |
      head -1 || true)"
    # 进程可能以相对路径（tool/agent/perf.sh 的 "./build/..."）启动。
    [[ -n "$pid" ]] || pid="$(pgrep -x "$APP_BINARY" | head -1 || true)"
  fi
  [[ -n "$pid" ]] || die "找不到进程（--pid 指定，或先启动 release 产物）"
  kill -0 "$pid" 2>/dev/null || die "进程 $pid 不存在"

  python3 - "$pid" "$duration" "$interval" "$out" <<'PY'
import os, sys, time

pid = int(sys.argv[1])
duration = int(sys.argv[2])
interval = float(sys.argv[3])
out_path = sys.argv[4]
clk = os.sysconf('SC_CLK_TCK')


def read_threads(pid):
    result = {}
    try:
        tids = os.listdir(f'/proc/{pid}/task')
    except FileNotFoundError:
        return result
    for tid in tids:
        try:
            with open(f'/proc/{pid}/task/{tid}/stat', encoding='utf-8',
                      errors='replace') as fh:
                raw = fh.read()
            # comm 可能带空格 / 括号：以最后一个 ')' 为界，字段 3 起是 state。
            comm = raw[raw.find('(') + 1:raw.rfind(')')]
            fields = raw[raw.rfind(')') + 2:].split()
            utime, stime = int(fields[11]), int(fields[12])
            result[tid] = (comm, utime + stime)
        except (FileNotFoundError, ProcessLookupError, IndexError):
            continue
    return result


start = read_threads(pid)
if not start:
    print(f'进程 {pid} 没有可读线程（可能已退出）', file=sys.stderr)
    sys.exit(1)
t0 = time.time()
time.sleep(duration)
elapsed = time.time() - t0
end = read_threads(pid)

rows = []
for tid, (comm, ticks) in end.items():
    old = start.get(tid, (comm, 0))[1]
    delta = max(0, ticks - old)
    pct = delta / clk / elapsed * 100
    rows.append((pct, comm, tid))
rows.sort(reverse=True)

total = sum(r[0] for r in rows)
lines = [f'进程 {pid} · {duration}s · {elapsed:.2f}s 实际窗口 · '
         f'总占用 {total:.1f}%（100% = 1 核）', '']
lines.append(f"{'线程':<20}{'CPU%':>8}{'TID':>10}")
for pct, comm, tid in rows:
    if pct < 0.05:
        continue
    lines.append(f'{comm[:19]:<20}{pct:>8.2f}{tid:>10}')
lines.append('')
lines.append('按角色汇总（WSLg / Xvfb 的 platform 线程包含窗口呈现拷贝，'
             'Dart 侧看 ui/worker/io）:')
# Linux embedder：进程主线程（TID == PID）是 GTK / 平台线程；Dart UI 在另一个
# 同名线程上。两者都叫 molia，必须用 TID 区分，否则会把 WSLg 的呈现拷贝算成
# 应用逻辑 CPU。
roles = [
    ('平台/GTK', lambda c, tid: str(tid) == str(pid)),
    ('Dart UI', lambda c, tid: str(tid) != str(pid) and (c.startswith('molia') or c.endswith('.ui'))),
    ('raster', lambda c, tid: 'raster' in c),
    ('IO', lambda c, tid: c.startswith('io.flutter') or c == 'io'),
    ('DartWorker', lambda c, tid: 'DartWorker' in c),
    ('mpv/audio', lambda c, tid: 'mpv' in c or 'Audio' in c or 'audio' in c),
]
used = set()
for label, match in roles:
    value = sum(p for p, c, tid in rows if match(c, tid))
    if value > 0.05:
        lines.append(f'  {label:<18}{value:>8.2f}')
for pct, comm, tid in rows:
    if pct > 0.05 and not any(match(comm, tid) for _, match in roles):
        used.add(comm)
if used:
    lines.append(f'  {"其它":<18}{sum(p for p, c, _ in rows if c in used):>8.2f}'
                 f'  ({", ".join(sorted(used))})')
dart_total = sum(p for p, c, tid in rows
                 if str(tid) != str(pid) and (c.startswith('molia') or c.endswith('.ui')
                                    or c.startswith('io.flutter') or c == 'io'
                                    or 'DartWorker' in c))
lines.append('')
lines.append(f'Dart 侧合计（UI + IO + worker）: {dart_total:.2f}%')

text = '\n'.join(lines)
print(text)
with open(out_path, 'w', encoding='utf-8') as fh:
    fh.write(text + '\n')
PY
}

# ---- Android ---------------------------------------------------------------
sample_android() {
  if [[ -z "$serial" ]]; then
    serial="$(running_emulator)"
  fi
  [[ -n "$serial" ]] || die "没有运行中的模拟器（先 tool/agent/emu.sh start）"
  local dev=("$ADB" -s "$serial")
  if [[ -z "$pid" ]]; then
    pid="$("${dev[@]}" shell pidof "$APP_ID" | tr -d '\r' || true)"
    pid="${pid%% *}"
  fi
  [[ -n "$pid" ]] || die "设备上没有运行 $APP_ID（--pid 可指定）"

  local raw="$out.raw"
  local uid; uid="$("${dev[@]}" shell id -u 2>/dev/null | tr -d '\r')"
  if [[ "$uid" == "0" ]]; then
    # root 模拟器：直接读 /proc 的 utime+stime 差分。比 `top -H` 可靠——
    # 本机 Android 16 的 top 在线程模式下 %CPU 恒为 0（进程级才有值）。
    log "采样 $serial pid=$pid ${duration}s（/proc 线程差分）"
    local t0 t1
    t0="$(date +%s%N)"
    "${dev[@]}" shell \
      "cat /proc/$pid/task/*/stat; echo ---; sleep $duration; cat /proc/$pid/task/*/stat" \
      >"$raw" 2>&1 || true
    t1="$(date +%s%N)"
    local elapsed_ms=$(( (t1 - t0) / 1000000 ))
    local clk; clk="$("${dev[@]}" shell getconf CLK_TCK | tr -d '\r')"
    python3 - "$raw" "$out" "$pid" "${clk:-100}" "$elapsed_ms" <<'PY'
import sys

raw_path, out_path, pid, clk, elapsed_ms = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
    int(sys.argv[5]))
elapsed = max(0.001, elapsed_ms / 1000)

parts = open(raw_path, encoding='utf-8', errors='replace').read().split('---')
if len(parts) < 2:
    print(f'没有解析到两次 /proc 采样（见 {raw_path}）', file=sys.stderr)
    sys.exit(1)


def parse(block):
    result = {}
    for line in block.splitlines():
        line = line.strip()
        if not line or not line[0].isdigit() or '(' not in line:
            continue
        l = line.rfind(')')
        try:
            tid = int(line[:line.find('(')])
            comm = line[line.find('(') + 1:l]
            fields = line[l + 2:].split()
            result[tid] = (comm, int(fields[11]) + int(fields[12]))
        except (ValueError, IndexError):
            continue
    return result


start, end = parse(parts[0]), parse(parts[-1])
rows = []
for tid, (comm, ticks) in end.items():
    old = start.get(tid, (comm, 0))[1]
    rows.append(((ticks - old) / clk / elapsed * 100, comm, tid))
rows.sort(reverse=True)
total = sum(r[0] for r in rows)
lines = [f'Android pid {pid} · {elapsed:.2f}s 窗口 · /proc 线程差分'
         f'（100% = 1 核）', '', f"{'线程':<22}{'CPU%':>8}{'TID':>8}"]
for cpu, name, tid in rows[:25]:
    if cpu < 0.05:
        continue
    lines.append(f'{name[:21]:<22}{cpu:>8.2f}{tid:>8}')


def role(name, tid):
    low = name.lower()
    if tid == pid:
        return '平台/Java main'
    if low.startswith('1.ui') or low == 'ui':
        return 'Dart UI'
    if 'raster' in low:
        return 'RenderThread'
    if 'dartworker' in low or low.startswith('dart:io') or 'io.worker' in low:
        return 'Dart worker/io'
    if 'exoplayer' in low or 'audiotrack' in low or 'audio' in low:
        return '音频解码'
    return '其它'


roles = {}
for cpu, name, tid in rows:
    key = role(name, tid)
    roles[key] = roles.get(key, 0.0) + cpu
lines.append('')
lines.append('按角色汇总（模拟器绝对数只做相对比较）:')
for label, value in sorted(roles.items(), key=lambda kv: -kv[1]):
    if value > 0.05:
        lines.append(f'  {label:<16}{value:>8.2f}')
dart_total = sum(v for k, v in roles.items() if k in ('Dart UI', 'Dart worker/io'))
lines.append('')
lines.append(f'Dart 侧合计（UI + worker/io）: {dart_total:.2f}%')
text = '\n'.join(lines)
print(text)
open(out_path, 'w', encoding='utf-8').write(text + '\n')
PY
    return
  fi

  log "采样 $serial pid=$pid ${duration}s（top -H；非 root 设备）"
  # top -H：线程模式；-n 2 让第一帧是基准、第二帧是差分值。不同 Android
  # 版本的列顺序略有差异，交给后面按列名解析。
  "${dev[@]}" shell "top -H -b -n 2 -d $interval -p $pid" >"$raw" 2>&1 || true
  python3 - "$raw" "$out" "$pid" <<'PY'
import re, sys

raw_path, out_path, pid = sys.argv[1], sys.argv[2], int(sys.argv[3])
blocks = []
current = []
started = False
for line in open(raw_path, encoding='utf-8', errors='replace'):
    if 'TID' in line and '%CPU' in line:
        if started and current:
            blocks.append(current)
        current = []
        started = True
        continue
    if started:
        current.append(line)
if current:
    blocks.append(current)

if not blocks:
    print(f'没有解析到 top 输出（见 {raw_path}）', file=sys.stderr)
    sys.exit(1)

# 不同 Android 版本的 top 列名不同（S[%CPU] 与 %CPU 两种）；用一条正则
# 兼容：TID … S/SHR 之后是状态字母，再后面是 CPU%、%MEM。
row_re = re.compile(
    r'^\s*(\d+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+[A-Z]\s+'
    r'([\d.]+)\s+[\d.]+\s+\S+\s+(.+?)\s+\S+\s*$'
)
# 最后一个 block 是该间隔内的平均占用。
block = blocks[-1]
rows = []
for line in block:
    m = row_re.match(line)
    if not m:
        continue
    tid, cpu, name = m.group(1), float(m.group(2)), m.group(3).strip()
    rows.append((cpu, name, int(tid)))
rows.sort(reverse=True)
total = sum(r[0] for r in rows)
lines = [f'Android pid {pid} · top -H 采样（100% = 1 核）', '',
         f"{'线程':<22}{'CPU%':>8}{'TID':>8}"]
for cpu, name, tid in rows[:25]:
    lines.append(f'{name[:21]:<22}{cpu:>8.2f}{tid:>8}')

def role(name, tid):
    low = name.lower()
    if tid == pid:
        return '平台/Java main'
    if '.ui' in low or low.endswith('ui'):
        return 'Dart UI'
    if 'raster' in low:
        return 'RenderThread'
    if 'dartworker' in low or 'dart:io' in low:
        return 'Dart worker/io'
    if 'exoplayer' in low or 'audiotrack' in low or 'audio' in low:
        return '音频解码'
    return '其它'

roles = {}
for cpu, name, tid in rows:
    roles.setdefault(role(name, tid), 0.0)
    roles[role(name, tid)] += cpu
lines.append('')
lines.append('按角色汇总（模拟器渲染线程的绝对值只做相对比较）:')
for label, value in sorted(roles.items(), key=lambda kv: -kv[1]):
    if value > 0.05:
        lines.append(f'  {label:<16}{value:>8.2f}')
dart_total = sum(v for k, v in roles.items() if k in ('Dart UI', 'Dart worker/io'))
lines.append('')
lines.append(f'Dart 侧合计（UI + worker/io）: {dart_total:.2f}%')
text = '\n'.join(lines)
print(text)
with open(out_path, 'w', encoding='utf-8') as fh:
    fh.write(text + '\n')
PY
}

if [[ "$platform" == android ]]; then
  sample_android
else
  sample_linux
fi

log "原始结果：$out"
