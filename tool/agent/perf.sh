#!/usr/bin/env bash
# 全链路性能体检：帧 / 启动 / 内存 / 体积的统一入口。
#
# 用法:
#   tool/agent/perf.sh frames linux|android|windows
#   tool/agent/perf.sh frames windows --real   # release 真实窗口 + 滚轮，raster 可信
#   tool/agent/perf.sh startup linux|android
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
  local prefix=()
  if ! has_display; then
    command -v xvfb-run >/dev/null 2>&1 || die "缺少 xvfb-run（或用 --window 在真实显示上跑）"
    prefix=(env -u WAYLAND_DISPLAY GDK_BACKEND=x11 xvfb-run -a)
  fi
  local out_file="$out_dir/frames.jsonl"
  log "帧场景（Linux / profile）：结果 $out_dir"
  "${prefix[@]}" timeout --signal=TERM --kill-after=10 "$FRAME_TIMEOUT" \
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
    'raster_p50', 'raster_p95', 'raster_p99', 'total_p50', 'total_p95',
    'total_p99', 'jank16', 'jank33', 'worst_ms', 'image_cache_mb',
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
