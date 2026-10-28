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
# 说明:
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
    \$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'; \
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
  LINUX_RUN_PREFIX=()
  if has_display; then
    return 0
  fi
  command -v xvfb-run >/dev/null 2>&1 ||
    die "缺少 xvfb-run（--window 可在真实显示上跑）"
  # 只改 DISPLAY 不够：GDK 见到 WAYLAND_DISPLAY 会优先连真实合成器。
  LINUX_RUN_PREFIX=(env -u WAYLAND_DISPLAY GDK_BACKEND=x11 xvfb-run -a)
}

run_data_linux() {
  require_flutter
  local out="$1"
  prepare_perf_home
  seed_mock_source linux "$out"
  build_perf_linux "$out" 1 0
  local exe="build/linux/x64/release/bundle/$APP_BINARY"
  [[ -x "$PROJECT_DIR/$exe" ]] || die "找不到 release 产物：$exe"
  linux_run_prefix
  log "运行数据链路场景（Linux release / Xvfb）"
  ( cd "$PROJECT_DIR" && env -u XDG_DATA_HOME HOME="$PERF_HOME" "${LINUX_RUN_PREFIX[@]}" \
      timeout --signal=TERM --kill-after=5 300 "./$exe" ) \
    >"$out/run.log" 2>&1 || true
  report_data "$out"
  log "结果目录：$out"
}

run_data_android() { # out_dir [serial]
  require_flutter
  ensure_adb
  local out="$1" serial="${2:-}"
  [[ -n "$serial" ]] || serial="$(running_emulator)"
  [[ -n "$serial" ]] || die "没有运行中的模拟器（先 tool/agent/emu.sh start）"
  DEVICE_ID="$serial"
  adb_dev() { "$ADB" -s "$serial" "$@"; }

  local abi target abi_name
  abi="$(adb_dev shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    x86_64) target=android-x64; abi_name=x86_64 ;;
    arm64-v8a) target=android-arm64; abi_name=arm64-v8a ;;
    armeabi-v7a) target=android-arm; abi_name=armeabi-v7a ;;
    *) die "未知 ABI：$abi" ;;
  esac
  local apk="build/app/outputs/flutter-apk/app-$abi_name-release.apk"

  log "构建 perf release APK（$abi）"
  ( cd "$PROJECT_DIR" && flutter build apk --release \
      --target-platform "$target" --split-per-abi \
      "${PERF_DART_DEFINES[@]}" \
      --dart-define=MOLIA_PERF_HOLD_SECONDS=1 \
      --dart-define=MOLIA_PERF_START_DELAY_SECONDS=0 ) \
    2>&1 | tee "$out/build.log"
  [[ -f "$PROJECT_DIR/$apk" ]] || die "找不到 APK：$apk"
  log "安装到 $serial"
  if ! adb_dev install -r "$apk" >/dev/null 2>&1; then
    adb_dev uninstall "$APP_ID" >/dev/null 2>&1 || true
    adb_dev install "$apk" >/dev/null 2>&1 || die "安装失败：$apk"
  fi
  # 安装之后再注入：签名不一致触发的重装会清空应用数据。
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
  build_perf_linux "$out" 30 12
  local exe="build/linux/x64/release/bundle/$APP_BINARY"
  [[ -x "$PROJECT_DIR/$exe" ]] || die "找不到 release 产物：$exe"
  linux_run_prefix
  local log="$out/run.log"
  ( cd "$PROJECT_DIR" && env -u XDG_DATA_HOME HOME="$PERF_HOME" "${LINUX_RUN_PREFIX[@]}" \
      timeout --signal=TERM --kill-after=5 180 "./$exe" ) >"$log" 2>&1 &
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

  local abi target abi_name
  abi="$(adb_dev shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    x86_64) target=android-x64; abi_name=x86_64 ;;
    arm64-v8a) target=android-arm64; abi_name=arm64-v8a ;;
    armeabi-v7a) target=android-arm; abi_name=armeabi-v7a ;;
    *) die "未知 ABI：$abi" ;;
  esac
  local apk="build/app/outputs/flutter-apk/app-$abi_name-release.apk"
  log "构建 perf release APK（$abi）"
  ( cd "$PROJECT_DIR" && flutter build apk --release \
      --target-platform "$target" --split-per-abi \
      "${PERF_DART_DEFINES[@]}" \
      --dart-define=MOLIA_PERF_HOLD_SECONDS=30 \
      --dart-define=MOLIA_PERF_START_DELAY_SECONDS=12 ) \
    2>&1 | tee "$out/build.log"
  adb_dev install -r "$apk" >/dev/null 2>&1 ||
    { adb_dev uninstall "$APP_ID" >/dev/null 2>&1 || true; adb_dev install "$apk" >/dev/null 2>&1; } ||
    die "安装失败：$apk"
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
        exec "$PROJECT_DIR/tool/agent/startup.sh" "$platform" "${@:2}"
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
        log "构建 release Linux bundle"
        flutter build linux --release 2>&1 | tee "$out_dir/build.log"
        du -sh build/linux/x64/release/bundle >"$out_dir/summary.md"
        log "结果目录：$out_dir"
        ;;
      *) usage ;;
    esac
    ;;
  all)
    platform="${1:-linux}"
    "$0" startup "$platform"
    "$0" size "$platform"
    if [[ "$platform" == android ]]; then
      "$0" frames android
    else
      "$0" frames linux
    fi
    ;;
  *) usage ;;
esac
