#!/usr/bin/env bash
# 全链路性能体检：帧 / 启动 / 内存 / 体积的统一入口。
#
# 用法:
#   tool/agent/perf.sh frames linux|android|windows
#   tool/agent/perf.sh frames windows --real   # release 真实窗口 + 滚轮，raster 可信
#   tool/agent/perf.sh startup linux|android
#   tool/agent/perf.sh data linux|android      # 搜索/起播/取词端到端时延（mock 音源）
#   MOLIA_PERF_SCENARIO_NEXT=1 tool/agent/perf.sh data linux  # 追加下一首起播采样
#   tool/agent/perf.sh cpu linux|android       # 空闲/播放 CPU（按线程）
#   tool/agent/perf.sh memory linux|windows
#   tool/agent/perf.sh size android|linux
#   tool/agent/perf.sh all linux|android
#
# 全局选项:
#   --window    Linux 在真实显示上跑（默认 Xvfb 无头，不会弹到 WSLg）
#   --no-build  复用已有产物（data/cpu 的 release APK / Linux bundle；见各命令）
#
# 说明:
# - Linux 默认无条件 Xvfb；`--window` 才用当前 DISPLAY。只改 DISPLAY 不够，
#   脚本会同时 unset WAYLAND_DISPLAY + GDK_BACKEND=x11（同 test.sh）；
# - data/cpu linux 自动套私有 `dbus-run-session`：WSL / 容器没有 keyring 或
#   NetworkManager 时，系统会话总线会让同步初始化（安全存储 / 探针）卡 40s+，
#   看起来像搜索超时；
# - Android data/cpu 用 release 包注入 mock 源：需要 `adb root`（release 包
#   不可 run-as）；首次安装会先启动一次应用创建私有目录再 seed；
# - frames 走 `flutter drive --profile` + integration_test/perf_flows_test.dart，
#   只读 `molia.frame` 汇总行（FrameStats opt-in，正常包无开销）；
# - Windows 目标必须用 Windows 侧 Flutter（WSL 的 Flutter 不能构建 Windows），
#   默认 SDK `C:\Tools\flutter`、构建目录 `C:\Users\Still\molia-perf`，可用
#   MOLIA_WIN_FLUTTER / MOLIA_WIN_PROJECT 覆盖；
# - 启动 / 内存沿用已有专用脚本，避免两套口径（startup.sh / memory.sh / memory.ps1）；
# - 结果落在 $RUN_DIR/perf-<平台>-<时间戳>/，原始日志与 frames.jsonl 都可复查。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

FRAME_TEST_TARGET="integration_test/perf_flows_test.dart"
FRAME_TEST_DRIVER="test_driver/integration_test.dart"
WIN_FLUTTER="${MOLIA_WIN_FLUTTER:-C:\\Tools\\flutter\\bin\\flutter.bat}"
WIN_PROJECT="${MOLIA_WIN_PROJECT:-C:\\Users\\Still\\molia-perf}"
WIN_PROJECT_WSL="${MOLIA_WIN_PROJECT_WSL:-/mnt/c/Users/Still/molia-perf}"
WIN_PERF_OUT_WIN="${MOLIA_WIN_PERF_OUT:-C:\\Users\\Still\\AppData\\Local\\Temp\\molia-perf\\frames.jsonl}"
WIN_PERF_OUT_WSL="/mnt/c/Users/Still/AppData/Local/Temp/molia-perf/frames.jsonl"
WIN_TEMP_WSL="/mnt/c/Users/Still/AppData/Local/Temp/molia-perf"
FRAME_TIMEOUT="${MOLIA_PERF_TIMEOUT:-1800}"

PERF_WINDOW=0
PERF_NO_BUILD=0
_global_args=()
for _arg in "$@"; do
  case "$_arg" in
    --window) PERF_WINDOW=1 ;;
    --no-build) PERF_NO_BUILD=1 ;;
    *) _global_args+=("$_arg") ;;
  esac
done
set -- "${_global_args[@]}"
unset _arg _global_args

usage() {
  sed -n '/^# 用法:/,/^# 说明:/p' "$0" | sed -e 's/^# \{0,1\}//' -e '$d' >&2
  exit 2
}

new_out_dir() {
  local platform="$1"
  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local dir="$RUN_DIR/perf-${platform}-$stamp"
  mkdir -p "$dir"
  echo "$dir"
}

require_flutter() {
  command -v flutter >/dev/null 2>&1 || die "找不到 flutter"
}

windows_sync() {
  mkdir -p "$WIN_PROJECT_WSL"
  log "同步源码到 Windows 构建目录：$WIN_PROJECT"
  # 不用 rsync（WSL 最小环境里不一定装）：tar 管道保留权限位，排除构建产物。
  tar -C "$PROJECT_DIR" \
    --exclude='./.git' \
    --exclude='./.dart_tool' \
    --exclude='./build' \
    --exclude='./windows/flutter/ephemeral' \
    -cf - . | tar -C "$WIN_PROJECT_WSL" -xf -
}

windows_powershell() { # 传入 PowerShell 命令字符串
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$1"
}

run_frames_linux() {
  require_flutter
  local out_dir="$1"
  linux_run_prefix
  local out_file="$out_dir/frames.jsonl"
  log "帧场景（Linux / profile）：结果 $out_dir"
  "${LINUX_RUN_PREFIX[@]}" timeout --signal=TERM --kill-after=10 "$FRAME_TIMEOUT" \
    flutter drive \
    --profile \
    --driver="$FRAME_TEST_DRIVER" \
    --target="$FRAME_TEST_TARGET" \
    -d linux \
    --dart-define=MOLIA_PERF_TRACE=true \
    --dart-define="MOLIA_PERF_OUT=$out_file" \
    2>&1 | tee "$out_dir/drive.log"
}

run_frames_android() {
  require_flutter
  ensure_adb
  local serial="${1:-$DEVICE_ID}"
  local out_dir="$2"
  "$ADB" -s "$serial" get-state >/dev/null 2>&1 ||
    die "设备 $serial 未连接（先 tool/agent/emu.sh start）"
  log "帧场景（Android $serial / profile）：结果 $out_dir"
  "$ADB" -s "$serial" logcat -c || true
  timeout --signal=TERM --kill-after=10 "$FRAME_TIMEOUT" \
    flutter drive \
    --profile \
    --driver="$FRAME_TEST_DRIVER" \
    --target="$FRAME_TEST_TARGET" \
    -d "$serial" \
    --dart-define=MOLIA_PERF_TRACE=true \
    2>&1 | tee "$out_dir/drive.log"
  "$ADB" -s "$serial" logcat -d -v time 2>/dev/null |
    grep -a 'molia.frame' >"$out_dir/frames.log" || true
  grep -a 'molia.frame' "$out_dir/drive.log" >>"$out_dir/frames.log" || true
}

run_frames_windows() {
  windows_sync
  local out_dir="$1"
  rm -f "$WIN_PERF_OUT_WSL"
  log "帧场景（Windows / profile integration）：结果 $out_dir"
  windows_powershell "\
    \$ErrorActionPreference = 'Stop'; \
    Set-Location '$WIN_PROJECT'; \
    \$env:PUB_HOSTED_URL = 'https://pub.dev'; \
    & '$WIN_FLUTTER' drive \
      --profile \
      --driver='$FRAME_TEST_DRIVER' \
      --target='$FRAME_TEST_TARGET' \
      -d windows \
      --dart-define=MOLIA_PERF_TRACE=true \
      --dart-define='MOLIA_PERF_OUT=$WIN_PERF_OUT_WIN' \
      2>&1 | Tee-Object -FilePath '$WIN_PROJECT\\perf-drive.log'" \
    >"$out_dir/drive.log" 2>&1 || true
  [[ -f "$WIN_PERF_OUT_WSL" ]] && cp "$WIN_PERF_OUT_WSL" "$out_dir/frames.jsonl"
  [[ -f "$WIN_PROJECT_WSL/perf-drive.log" ]] &&
    cp "$WIN_PROJECT_WSL/perf-drive.log" "$out_dir/drive.log"
}

run_frames_windows_real() {
  windows_sync
  local out_dir="$1"
  log "帧场景（Windows / release 真实窗口 + 滚轮）：结果 $out_dir"
  powershell.exe -NoProfile -ExecutionPolicy Bypass \
    -File "$(wslpath -w "$PROJECT_DIR/tool/agent/frames_windows.ps1")" \
    -Exe "$WIN_PROJECT\\build\\windows\\x64\\runner\\Release\\molia.exe" \
    -OutDir 'C:\Users\Still\AppData\Local\Temp\molia-perf' \
    2>&1 | tee "$out_dir/frames-console.log"
  cp "$WIN_TEMP_WSL"/frames.log "$out_dir/" 2>/dev/null || true
  cp "$WIN_TEMP_WSL"/frames-pre-scroll.png "$out_dir/" 2>/dev/null || true
  cp "$WIN_TEMP_WSL"/frames-post-scroll.png "$out_dir/" 2>/dev/null || true
  cp "$WIN_TEMP_WSL"/frames-release.log "$out_dir/" 2>/dev/null || true
}

# ---- 数据链路 / CPU（mock 音源 + 隔离 HOME）--------------------------------

# 隔离的数据目录：调用 seed.sh 与 release 进程时都改 HOME，避免污染本机
# 正在使用的应用数据（共享偏好 / DB / 音源脚本）。
PERF_HOME="${MOLIA_PERF_HOME:-$RUN_DIR/perf-home}"
PERF_DART_DEFINES=(
  --dart-define=MOLIA_PERF_TRACE=true
  --dart-define=MOLIA_PERF_SCENARIO_DATA=true
  --dart-define="MOLIA_PERF_SOURCE=${MOLIA_PERF_SOURCE:-mock}"
  --dart-define="MOLIA_PERF_KEYWORD=${MOLIA_PERF_KEYWORD:-周杰伦}"
)
# 下一首采样默认关闭（保持既有 data 口径）；仅在显式 MOLIA_PERF_SCENARIO_NEXT=1
# 时打开，等待时长可用 MOLIA_PERF_NEXT_WAIT_MS 覆盖（验证在途预取时设小）。
if [[ "${MOLIA_PERF_SCENARIO_NEXT:-0}" == "1" ]]; then
  PERF_DART_DEFINES+=(--dart-define=MOLIA_PERF_SCENARIO_NEXT=true)
fi
if [[ -n "${MOLIA_PERF_NEXT_WAIT_MS:-}" ]]; then
  PERF_DART_DEFINES+=(
    --dart-define="MOLIA_PERF_NEXT_WAIT_MS=$MOLIA_PERF_NEXT_WAIT_MS"
  )
fi

prepare_perf_home() {
  mkdir -p "$PERF_HOME/.local/share/$APP_ID" "$RUN_DIR"
  # headless Xvfb 会按持久化的窗口 bounds 建窗：隔离 HOME 复用上一次的大窗口
  # （曾出现 3492×3012）时，软件光栅 / 平台线程会被无谓拉满，帧与 CPU 数据
  # 全部失真。每次 perf 前固定到 1440×900，保证跨轮可比。
  local prefs="$PERF_HOME/.local/share/$APP_ID/shared_preferences.json"
  python3 - "$prefs" <<'PY' || true
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if not path.exists():
    raise SystemExit
try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit
if not isinstance(data, dict):
    raise SystemExit
data['flutter.window_bounds_x'] = 0.0
data['flutter.window_bounds_y'] = 0.0
data['flutter.window_bounds_width'] = 1440.0
data['flutter.window_bounds_height'] = 900.0
path.write_text(json.dumps(data, ensure_ascii=False))
PY
}

seed_mock_source() { # platform out_dir [serial]
  local platform="$1" out="$2" serial="${3:-}"
  log "注入 mock 音源（$platform，隔离 HOME=$PERF_HOME）"
  if [[ "$platform" == android ]]; then
    DEVICE_ID="${serial:-$DEVICE_ID}" \
      "$PROJECT_DIR/tool/agent/seed.sh" android mock-source \
      >"$out/seed.log" 2>&1 || die "注入 mock 音源失败（见 $out/seed.log）"
  else
    env -u XDG_DATA_HOME HOME="$PERF_HOME" \
      "$PROJECT_DIR/tool/agent/seed.sh" linux mock-source \
      >"$out/seed.log" 2>&1 || die "注入 mock 音源失败（见 $out/seed.log）"
  fi
}

build_perf_linux() { # out_dir hold_seconds start_delay_seconds
  local out="$1" hold="$2" delay="$3"
  log "构建 perf release（Linux，hold=${hold}s delay=${delay}s）"
  ( cd "$PROJECT_DIR" && flutter build linux --release \
      "${PERF_DART_DEFINES[@]}" \
      --dart-define=MOLIA_PERF_HOLD_SECONDS="$hold" \
      --dart-define=MOLIA_PERF_START_DELAY_SECONDS="$delay" \
      --dart-define="MOLIA_PERF_OUT=$out/molia-frame.jsonl" ) \
    2>&1 | tee "$out/build.log"
}

LINUX_RUN_PREFIX=()
linux_run_prefix() {
  linux_display_prefix "$PERF_WINDOW"
  LINUX_RUN_PREFIX=("${LINUX_DISPLAY_PREFIX[@]}")
  if ((PERF_WINDOW)); then
    if has_display; then
      log "window: 使用当前显示（可能弹到 WSLg）"
    else
      log "警告：--window 但未检测到 DISPLAY/WAYLAND_DISPLAY，仍直接跑"
    fi
  else
    log "headless: xvfb-run -a（--window 可切回真实显示）"
  fi
}

# data/cpu 的 release 进程需要隔离的会话总线：WSL / 容器没有 keyring 或
# NetworkManager 时，系统会话总线会让同步初始化（安全存储 / 电量网络探针）
# 卡 40s+，表现为 scenario.source 迟迟不出现、搜索超时。
PERF_DBUS_PREFIX=()
perf_dbus_prefix() {
  PERF_DBUS_PREFIX=()
  if command -v dbus-run-session >/dev/null 2>&1; then
    PERF_DBUS_PREFIX=(dbus-run-session --)
  else
    log "警告：缺少 dbus-run-session；WSL 下可能因系统总线缺服务而卡住"
  fi
}

require_scenario_done() { # log_file label
  local log="$1" label="$2"
  grep -q 'molia.perf:.*scenario.done' "$log" 2>/dev/null && return 0
  log "数据场景未完成（$label），日志尾部："
  tail -40 "$log" >&2 || true
  die "未采到 scenario.done；本轮数据不可用（检查 dbus / adb root / mock 音源）"
}

run_data_linux() {
  require_flutter
  local out="$1"
  prepare_perf_home
  seed_mock_source linux "$out"
  if ((PERF_NO_BUILD)); then
    log "复用已有 perf release（--no-build）"
  else
    build_perf_linux "$out" 1 0
  fi
  local exe="build/linux/x64/release/bundle/$APP_BINARY"
  [[ -x "$PROJECT_DIR/$exe" ]] || die "找不到 release 产物：$exe"
  linux_run_prefix
  perf_dbus_prefix
  log "运行数据链路场景（Linux release / Xvfb）"
  ( cd "$PROJECT_DIR" && env -u XDG_DATA_HOME HOME="$PERF_HOME" "${LINUX_RUN_PREFIX[@]}" \
      "${PERF_DBUS_PREFIX[@]}" timeout --signal=TERM --kill-after=5 300 "./$exe" ) \
    >"$out/run.log" 2>&1 || true
  require_scenario_done "$out/run.log" linux
  report_data "$out"
  log "结果目录：$out"
}

ensure_android_root() { # serial
  local serial="$1" uid
  uid="$("$ADB" -s "$serial" shell id -u 2>/dev/null | tr -d '\r')"
  [[ "$uid" == "0" ]] ||
    die "perf data/cpu 需要 root（release 包不可 run-as）：先执行 '$ADB -s $serial root'"
}

# 首次安装后应用私有目录还不存在：seed 会在 stat / cp 阶段失败。先启动一次
# 应用让系统建好 files / shared_prefs，再 force-stop，随后 seed。
ensure_android_app_data() { # serial
  local serial="$1" dir="/data/data/$APP_ID"
  if "$ADB" -s "$serial" shell "test -d '$dir/files'" >/dev/null 2>&1; then
    return 0
  fi
  log "首次安装：先启动一次应用创建私有数据目录"
  "$ADB" -s "$serial" shell am start -W -S -n "$APP_ID/.MainActivity" \
    >/dev/null 2>&1 || true
  local deadline=$(( $(date +%s) + 20 ))
  while ! "$ADB" -s "$serial" shell "test -d '$dir/files'" >/dev/null 2>&1; do
    (( $(date +%s) > deadline )) && die "应用数据目录未创建：$dir/files"
    sleep 0.5
  done
  "$ADB" -s "$serial" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
}

run_data_android() { # out_dir [serial]
  require_flutter
  ensure_adb
  local out="$1" serial="${2:-}"
  [[ -n "$serial" ]] || serial="$(running_emulator)"
  [[ -n "$serial" ]] || die "没有运行中的模拟器（先 tool/agent/emu.sh start）"
  DEVICE_ID="$serial"
  adb_dev() { "$ADB" -s "$serial" "$@"; }
  ensure_android_root "$serial"

  local abi target abi_name
  abi="$(adb_dev shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    x86_64) target=android-x64; abi_name=x86_64 ;;
    arm64-v8a) target=android-arm64; abi_name=arm64-v8a ;;
    armeabi-v7a) target=android-arm; abi_name=armeabi-v7a ;;
    *) die "未知 ABI：$abi" ;;
  esac
  local apk="build/app/outputs/flutter-apk/app-$abi_name-release.apk"

  if ((PERF_NO_BUILD)); then
    log "复用已有 perf release APK（--no-build）"
  else
    log "构建 perf release APK（$abi）"
    ( cd "$PROJECT_DIR" && flutter build apk --release \
        --target-platform "$target" --split-per-abi \
        "${PERF_DART_DEFINES[@]}" \
        --dart-define=MOLIA_PERF_HOLD_SECONDS=1 \
        --dart-define=MOLIA_PERF_START_DELAY_SECONDS=0 ) \
      2>&1 | tee "$out/build.log"
  fi
  [[ -f "$PROJECT_DIR/$apk" ]] || die "找不到 APK：$apk"
  log "安装到 $serial"
  if ! adb_dev install -r "$apk" >/dev/null 2>&1; then
    adb_dev uninstall "$APP_ID" >/dev/null 2>&1 || true
    adb_dev install "$apk" >/dev/null 2>&1 || die "安装失败：$apk"
  fi
  # 安装之后再注入：签名不一致触发的重装会清空应用数据。
  ensure_android_app_data "$serial"
  seed_mock_source android "$out" "$serial"
  adb_dev logcat -c >/dev/null 2>&1 || true
  log "运行数据链路场景（Android / $serial）"
  adb_dev shell am start -W -S -n "$APP_ID/.MainActivity" >/dev/null 2>&1 || true
  local deadline=$(( $(date +%s) + 300 ))
  while :; do
    if adb_dev logcat -d 2>/dev/null | grep -q 'molia.perf:.*scenario.done'; then
      break
    fi
    (( $(date +%s) > deadline )) && break
    sleep 1
  done
  adb_dev logcat -d 2>/dev/null | grep -a 'molia.perf' >"$out/data.log" || true
  adb_dev shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  require_scenario_done "$out/data.log" android
  report_data "$out"
  log "结果目录：$out"
}

report_data() { # 解析 molia.perf JSONL / 日志为 Markdown
  local dir="$1"
  python3 - "$dir" <<'PY'
import json, pathlib, statistics, sys
from collections import OrderedDict

root = pathlib.Path(sys.argv[1])
rows = []
for path in [root / 'run.log', root / 'data.log']:
    if not path.exists():
        continue
    for line in path.read_text(errors='replace').splitlines():
        if 'molia.perf: ' not in line:
            continue
        text = line.split('molia.perf: ', 1)[1].strip()
        try:
            rows.append(json.loads(text))
        except json.JSONDecodeError:
            pass

if not rows:
    print(f'没有采到 molia.perf 样本（{root}）', file=sys.stderr)
    (root / 'summary.md').write_text('# 数据链路体检\n\n没有采到 `molia.perf` 样本。\n')
    sys.exit(0)

ops = OrderedDict()
events = OrderedDict()
for row in rows:
    op = str(row.get('op', ''))
    if op.startswith('scenario.'):
        events[op] = row
        continue
    ops.setdefault(op, []).append(float(row.get('ms', 0)))

def qs(values):
    values = sorted(values)
    def q(p):
        rank = max(0, min(len(values) - 1, (p / 100 * len(values) + 0.999999) // 1 - 1))
        return values[int(rank)]
    return len(values), q(50), q(95), max(values)

lines = ['# 数据链路体检（mock 音源）', '']
lines.append('## 端到端（scenario 墙钟）')
lines.append('')
lines.append('| 阶段 | ms | 字段 |')
lines.append('| --- | ---: | --- |')
for op, row in events.items():
    fields = {k: v for k, v in row.items() if k not in ('op', 'ms', 'ts')}
    lines.append(f"| {op} | {row.get('ms', 0)} | {json.dumps(fields, ensure_ascii=False)} |")

lines += ['', '## 分项耗时（ms）', '',
          '| op | n | p50 | p95 | max |', '| --- | ---: | ---: | ---: | ---: |']
for op, values in ops.items():
    n, p50, p95, worst = qs(values)
    lines.append(f'| {op} | {n} | {p50:.2f} | {p95:.2f} | {worst:.2f} |')

summary = '\n'.join(lines) + '\n'
(root / 'summary.md').write_text(summary)
print(summary)
PY
}

cpu_sample_linux() { # out_dir label pid
  local out="$1" label="$2" pid="$3"
  "$PROJECT_DIR/tool/agent/cpu.sh" linux --pid "$pid" --duration 8 \
    >"$out/cpu-$label.txt" 2>&1 || true
  cat "$out/cpu-$label.txt"
}

run_cpu_linux() {
  require_flutter
  local out="$1"
  prepare_perf_home
  seed_mock_source linux "$out"
  # 12s 空闲窗口 + 播放后保持 30s：同一次进程里采两段 CPU。
  if ((PERF_NO_BUILD)); then
    log "复用已有 perf release（--no-build）"
  else
    build_perf_linux "$out" 30 12
  fi
  local exe="build/linux/x64/release/bundle/$APP_BINARY"
  [[ -x "$PROJECT_DIR/$exe" ]] || die "找不到 release 产物：$exe"
  linux_run_prefix
  perf_dbus_prefix
  local log="$out/run.log"
  ( cd "$PROJECT_DIR" && env -u XDG_DATA_HOME HOME="$PERF_HOME" "${LINUX_RUN_PREFIX[@]}" \
      "${PERF_DBUS_PREFIX[@]}" timeout --signal=TERM --kill-after=5 180 "./$exe" ) >"$log" 2>&1 &
  local runner=$!
  local deadline=$(( $(date +%s) + 90 ))
  while :; do
    grep -q 'molia.startup: 首帧：' "$log" 2>/dev/null && break
    kill -0 "$runner" 2>/dev/null || break
    (( $(date +%s) > deadline )) && break
    sleep 0.5
  done
  sleep 2
  local pid; pid="$(pgrep -x "$APP_BINARY" | head -1 || true)"
  [[ -n "$pid" ]] || die "找不到应用进程（$APP_BINARY）"
  log "空闲采样（pid=$pid）"
  cpu_sample_linux "$out" idle "$pid"
  deadline=$(( $(date +%s) + 90 ))
  while :; do
    grep -q 'molia.perf:.*scenario.play.done' "$log" 2>/dev/null && break
    kill -0 "$runner" 2>/dev/null || break
    (( $(date +%s) > deadline )) && break
    sleep 0.5
  done
  if ! grep -q 'molia.perf:.*scenario.play.done' "$log" 2>/dev/null; then
    log "播放场景未完成，日志尾部："
    tail -40 "$log" >&2 || true
    kill "$runner" >/dev/null 2>&1 || true
    wait "$runner" >/dev/null 2>&1 || true
    die "未采到 scenario.play.done；本轮 CPU 数据不可用"
  fi
  log "播放采样（pid=$pid）"
  cpu_sample_linux "$out" playing "$pid"
  wait "$runner" >/dev/null 2>&1 || true
  {
    echo '# CPU 体检（Linux release / Xvfb）'
    echo
    echo '## 空闲（首帧后、场景开始前）'
    echo '```'
    cat "$out/cpu-idle.txt" 2>/dev/null || true
    echo '```'
    echo
    echo '## 播放中'
    echo '```'
    cat "$out/cpu-playing.txt" 2>/dev/null || true
    echo '```'
  } >"$out/summary.md"
  cat "$out/summary.md"
  log "结果目录：$out"
}

run_cpu_android() { # out_dir [serial]
  require_flutter
  ensure_adb
  local out="$1" serial="${2:-}"
  [[ -n "$serial" ]] || serial="$(running_emulator)"
  [[ -n "$serial" ]] || die "没有运行中的模拟器（先 tool/agent/emu.sh start）"
  DEVICE_ID="$serial"
  adb_dev() { "$ADB" -s "$serial" "$@"; }
  ensure_android_root "$serial"

  local abi target abi_name
  abi="$(adb_dev shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    x86_64) target=android-x64; abi_name=x86_64 ;;
    arm64-v8a) target=android-arm64; abi_name=arm64-v8a ;;
    armeabi-v7a) target=android-arm; abi_name=armeabi-v7a ;;
    *) die "未知 ABI：$abi" ;;
  esac
  local apk="build/app/outputs/flutter-apk/app-$abi_name-release.apk"
  if ((PERF_NO_BUILD)); then
    log "复用已有 perf release APK（--no-build）"
  else
    log "构建 perf release APK（$abi）"
    ( cd "$PROJECT_DIR" && flutter build apk --release \
        --target-platform "$target" --split-per-abi \
        "${PERF_DART_DEFINES[@]}" \
        --dart-define=MOLIA_PERF_HOLD_SECONDS=30 \
        --dart-define=MOLIA_PERF_START_DELAY_SECONDS=12 ) \
      2>&1 | tee "$out/build.log"
  fi
  [[ -f "$PROJECT_DIR/$apk" ]] || die "找不到 APK：$apk"
  adb_dev install -r "$apk" >/dev/null 2>&1 ||
    { adb_dev uninstall "$APP_ID" >/dev/null 2>&1 || true; adb_dev install "$apk" >/dev/null 2>&1; } ||
    die "安装失败：$apk"
  ensure_android_app_data "$serial"
  seed_mock_source android "$out" "$serial"
  adb_dev logcat -c >/dev/null 2>&1 || true
  adb_dev shell am start -W -S -n "$APP_ID/.MainActivity" >/dev/null 2>&1 || true
  # 场景有 12s 启动延迟：3s 后采 6s，落在搜索开始前的干净空闲窗口。
  sleep 3
  log "空闲采样（Android）"
  "$PROJECT_DIR/tool/agent/cpu.sh" android "$serial" --duration 6 \
    >"$out/cpu-idle.txt" 2>&1 || true
  cat "$out/cpu-idle.txt"
  local deadline=$(( $(date +%s) + 120 ))
  while :; do
    adb_dev logcat -d 2>/dev/null | grep -q 'molia.perf:.*scenario.play.done' && break
    (( $(date +%s) > deadline )) && break
    sleep 1
  done
  if ! adb_dev logcat -d 2>/dev/null | grep -q 'molia.perf:.*scenario.play.done'; then
    adb_dev shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
    die "未采到 scenario.play.done；本轮 Android CPU 数据不可用"
  fi
  log "播放采样（Android）"
  "$PROJECT_DIR/tool/agent/cpu.sh" android "$serial" --duration 8 \
    >"$out/cpu-playing.txt" 2>&1 || true
  cat "$out/cpu-playing.txt"
  adb_dev shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  {
    echo '# CPU 体检（Android 模拟器）'
    echo
    echo '> 模拟器软件渲染，绝对数只做相对比较。'
    echo
    echo '## 空闲'
    echo '```'
    cat "$out/cpu-idle.txt" 2>/dev/null || true
    echo '```'
    echo
    echo '## 播放中'
    echo '```'
    cat "$out/cpu-playing.txt" 2>/dev/null || true
    echo '```'
  } >"$out/summary.md"
  log "结果目录：$out"
}

report() { # 解析 frames.jsonl / frames.log 输出 Markdown
  local dir="$1"
  local out="$dir/summary.md"
  python3 - "$dir" "$out" <<'PY'
import json, pathlib, statistics, sys

root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
rows = []
for path in sorted(root.glob('frames*.jsonl')):
    for line in path.read_text(errors='replace').splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
for path in sorted(root.glob('frames*.log')):
    for line in path.read_text(errors='replace').splitlines():
        payload = line.split('molia.frame:', 1)
        if len(payload) != 2:
            continue
        text = payload[1].strip()
        if text.startswith('molia.frame:'):
            text = text.split(':', 1)[1].strip()
        try:
            rows.append(json.loads(text))
        except json.JSONDecodeError:
            pass

if not rows:
    out.write_text('# 性能体检\n\n没有采到 `molia.frame` 样本。\n')
    print(f'没有帧样本 -> {out}')
    sys.exit(0)

keys = [
    'scenario', 'label', 'frames', 'build_p50', 'build_p95', 'build_p99',
    'raster_p50', 'raster_p95', 'raster_p99', 'work_p50', 'work_p95',
    'work_p99', 'vsync_p95', 'total_p50', 'total_p95', 'total_p99',
    'jank16', 'jank33', 'latency16', 'worst_ms', 'image_cache_mb',
]
summary = {}
for row in rows:
    scenario = row.get('scenario', 'app')
    current = summary.get(scenario)
    # 每个场景优先取显式 end；没有 end 时退回最后一条（启动期没机会打 end）。
    if current is None or row.get('label') == 'end':
        summary[scenario] = row

lines = ['# 性能体检：帧样本', '', '## 场景汇总（每个场景取 end / 最后一条）', '',
         '| ' + ' | '.join(keys) + ' |',
         '| ' + ' | '.join('---' for _ in keys) + ' |']
for row in summary.values():
    lines.append('| ' + ' | '.join(str(row.get(k, '')) for k in keys) + ' |')
lines += ['', '## 原始窗口', '',
          '| ' + ' | '.join(keys) + ' |',
          '| ' + ' | '.join('---' for _ in keys) + ' |']
for row in rows:
    lines.append('| ' + ' | '.join(str(row.get(k, '')) for k in keys) + ' |')
out.write_text('\n'.join(lines) + '\n')
print(f'{len(rows)} 条帧样本 -> {out}')
PY
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift || true

case "$cmd" in
  frames)
    ((PERF_NO_BUILD)) && die "frames 暂不支持 --no-build：flutter drive 会重建 profile 产物"
    [[ $# -ge 1 ]] || usage
    platform="$1"; shift
    case "$platform" in
      linux)
        out_dir="$(new_out_dir linux)"
        run_frames_linux "$out_dir" | tee "$out_dir/drive-console.log"
        report "$out_dir"
        ;;
      android)
        out_dir="$(new_out_dir android)"
        run_frames_android "${1:-}" "$out_dir" | tee "$out_dir/drive-console.log"
        report "$out_dir"
        ;;
      windows)
        out_dir="$(new_out_dir windows)"
        if [[ "${1:-}" == "--real" ]]; then
          run_frames_windows_real "$out_dir" | tee "$out_dir/frames-console.log"
        else
          run_frames_windows "$out_dir" | tee "$out_dir/drive-console.log"
        fi
        report "$out_dir"
        ;;
      *) usage ;;
    esac
    log "结果目录：$out_dir"
    ;;
  data)
    platform="${1:-linux}"
    out_dir="$(new_out_dir "$platform-data")"
    case "$platform" in
      linux) run_data_linux "$out_dir" ;;
      android) run_data_android "$out_dir" "${2:-}" ;;
      *) usage ;;
    esac
    ;;
  cpu)
    platform="${1:-linux}"
    out_dir="$(new_out_dir "$platform-cpu")"
    case "$platform" in
      linux) run_cpu_linux "$out_dir" ;;
      android) run_cpu_android "$out_dir" "${2:-}" ;;
      *) usage ;;
    esac
    ;;
  startup)
    platform="${1:-linux}"
    case "$platform" in
      linux|android)
        startup_args=("$platform" "${@:2}")
        ((PERF_WINDOW)) && startup_args+=(--window)
        ((PERF_NO_BUILD)) && startup_args+=(--no-build)
        exec "$PROJECT_DIR/tool/agent/startup.sh" "${startup_args[@]}"
        ;;
      windows)
        windows_sync
        out_dir="$(new_out_dir windows-startup)"
        log "Windows 冷启动：结果 $out_dir"
        powershell.exe -NoProfile -ExecutionPolicy Bypass \
          -File "$(wslpath -w "$PROJECT_DIR/tool/agent/startup_windows.ps1")" \
          -Project "$WIN_PROJECT" \
          -Flutter "$WIN_FLUTTER" \
          -Runs "${2:-5}" \
          -OutDir 'C:\Users\Still\AppData\Local\Temp\molia-perf' \
          2>&1 | tee "$out_dir/startup.log"
        cp "$WIN_TEMP_WSL"/startup.jsonl "$out_dir/" 2>/dev/null || true
        cp "$WIN_TEMP_WSL"/startup-run-*.log "$out_dir/" 2>/dev/null || true
        log "结果目录：$out_dir"
        ;;
      *) usage ;;
    esac
    ;;
  memory)
    platform="${1:-linux}"
    case "$platform" in
      linux) exec "$PROJECT_DIR/tool/agent/memory.sh" "${@:2}" ;;
      windows)
        command -v powershell.exe >/dev/null 2>&1 || die "没有 powershell.exe"
        out_dir="$(new_out_dir windows-memory)"
        log "Windows 内存场景：结果 $out_dir"
        powershell.exe -NoProfile -ExecutionPolicy Bypass \
          -File "$(wslpath -w "$PROJECT_DIR/tool/agent/memory_windows.ps1")" \
          -Exe "$WIN_PROJECT\\build\\windows\\x64\\runner\\Release\\molia.exe" \
          -OutDir 'C:\Users\Still\AppData\Local\Temp\molia-perf' \
          2>&1 | tee "$out_dir/memory.log"
        cp "$WIN_TEMP_WSL"/memory.jsonl "$out_dir/" 2>/dev/null || true
        cp "$WIN_TEMP_WSL"/memory-release.log "$out_dir/" 2>/dev/null || true
        log "结果目录：$out_dir"
        ;;
      *) usage ;;
    esac
    ;;
  size)
    ((PERF_NO_BUILD)) && die "size 不支持 --no-build：该命令就是要重新构建产物"
    platform="${1:-android}"
    case "$platform" in
      android)
        require_flutter
        out_dir="$(new_out_dir android-size)"
        log "构建 release APK（split-per-abi）"
        flutter build apk --release --split-per-abi \
          --split-debug-info=build/symbols --obfuscate \
          --extra-gen-snapshot-options=--strip 2>&1 |
          tee "$out_dir/build.log"
        {
          echo "# Android 体积"
          echo
          find build/app/outputs/flutter-apk -maxdepth 1 -name '*.apk' \
            -printf '%f %s\n' | sort
        } >"$out_dir/summary.md"
        du -h build/app/outputs/flutter-apk/*.apk >>"$out_dir/summary.md" || true
        log "结果目录：$out_dir"
        ;;
      linux)
        require_flutter
        out_dir="$(new_out_dir linux-size)"
        bundle="$LINUX_RELEASE_BUNDLE"
        symbols_dir="$PROJECT_DIR/build/symbols/linux"
        symbols="$symbols_dir/app.linux-x64.symbols"
        summary="$out_dir/summary.md"

        # 体积只认干净 release：debug 的 kernel_blob / 非 release 引擎都会
        # 被 install 原样带进 bundle，先清掉再构建。
        log "清理 release 构建输入（flutter_assets / ephemeral / bundle；保留 mimalloc 缓存）"
        linux_clean_release_inputs

        log "构建 release Linux bundle（--split-debug-info=build/symbols/linux）"
        ( cd "$PROJECT_DIR" && flutter build linux --release \
            --split-debug-info=build/symbols/linux ) 2>&1 |
          tee "$out_dir/build.log"

        linux_assert_release_bundle "$bundle"
        [[ -f "$symbols" ]] || die "找不到符号文件：$symbols"

        bundle_before="$(du -sb "$bundle" | cut -f1)"
        log "strip 第三方插件库（libapp.so / libflutter_linux_gtk.so 保留）"
        "$PROJECT_DIR/tool/strip_linux_bundle.sh" "$bundle" 2>&1 |
          tee "$out_dir/strip.log"
        bundle_after="$(du -sb "$bundle" | cut -f1)"

        tar_path="$out_dir/molia-linux-bundle.tar.gz"
        tar -czf "$tar_path" -C "$(dirname "$bundle")" "$(basename "$bundle")"
        tar_bytes="$(stat -c%s "$tar_path")"

        {
          echo "# Linux 体积"
          echo
          echo '| 项 | 字节 |'
          echo '| --- | ---: |'
          echo "| bundle（strip 前） | $bundle_before |"
          echo "| bundle（strip 后） | $bundle_after |"
          echo "| bundle tar.gz | $tar_bytes |"
          echo "| libapp.so | $(stat -c%s "$bundle/lib/libapp.so") |"
          echo "| libflutter_linux_gtk.so | $(stat -c%s "$bundle/lib/libflutter_linux_gtk.so") |"
          echo "| symbols | $(stat -c%s "$symbols") |"
          echo
          echo "symbols: $symbols"
          echo "tar: $tar_path"
        } >"$summary"
        cat "$summary"

        {
          echo
          echo "## bundle 最大文件（10）"
          echo '```'
          find "$bundle" -type f -printf '%s\t%P\n' | sort -nr | head -10 |
            while IFS=$'\t' read -r size rel; do
              printf '%10d  %s\n' "$size" "$rel"
            done
          echo '```'
        } | tee -a "$summary"
        log "结果目录：$out_dir"
        ;;
      *) usage ;;
    esac
    ;;
  all)
    platform="${1:-linux}"
    all_flags=()
    ((PERF_WINDOW)) && all_flags+=(--window)
    "$0" startup "$platform" "${all_flags[@]}"
    "$0" size "$platform"
    if [[ "$platform" == android ]]; then
      "$0" frames android
    else
      "$0" frames linux "${all_flags[@]}"
    fi
    ;;
  *) usage ;;
esac
