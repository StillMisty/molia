#!/usr/bin/env bash
# 启动耗时采样：release（AOT）冷启动跑 N 次，抓 `molia.startup` 各阶段取中位数
#
# 用法:
#   tool/agent/startup.sh                # Linux 桌面：构建 release 后跑 5 次（无显示时 xvfb-run）
#   tool/agent/startup.sh android        # Android：默认取运行中的模拟器（先 tool/agent/emu.sh start）
#   tool/agent/startup.sh android <serial>
#   tool/agent/startup.sh --runs 9       # 采样次数
#   tool/agent/startup.sh --no-build     # 复用已有产物，只重测
#   tool/agent/startup.sh --window       # Linux：在真实 DISPLAY/WAYLAND_DISPLAY 上跑
#   tool/agent/startup.sh --timeout 90   # 单次运行的墙钟上限（默认 60s / Android 120s）
#
# 设计说明:
# - 只认 release 产物：debug 的首帧含 JIT/断言开销，不能代表用户可感时长
#   （历史 debug 数据 1.5–2.4s，release 会显著更低）；
# - 判定看进程自己打的 `molia.startup` 阶段行（main.dart 的埋点，release 也输出），
#   「首帧」那行即用户可感总时长；Android 另外记 `am start -W` 的 TotalTime
#   （系统口径：进程起到首帧绘制），两者都会进汇总表；
# - 每轮独立冷启动：Linux 每次都新进程 + 单实例关闭（_common.sh 的
#   MOLIA_SINGLE_INSTANCE_DISABLED）；Android 用 `am start -W -S`（先 force-stop）；
# - 采样不做文件系统热缓存区分，中位数对「改前/改后」是可比的；
# - 原始日志与 summary.txt 落在 $RUN_DIR/startup-<时间戳>/，供 docs/performance.md 引用。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat >&2 <<'EOF'
用法:
  startup.sh [linux|android] [serial] [--runs N] [--no-build] [--window] [--timeout 秒]

选项:
  --runs N       采样次数（默认 5）
  --no-build     跳过构建，用已有产物
  --window       Linux：在真实显示上跑（默认无显示时套 xvfb-run）
  --timeout 秒   单次运行墙钟上限（默认 Linux 60 / Android 120）
EOF
  exit 2
}

platform="linux"
serial=""
runs=5
do_build=1
headless=1
timeout_s=""

while (($#)); do
  case "$1" in
    linux|android) platform="$1" ;;
    --runs) runs="$2"; shift ;;
    --no-build) do_build=0 ;;
    --window) headless=0 ;;
    --timeout) timeout_s="$2"; shift ;;
    -*) usage ;;
    *)
      [[ "$platform" == "android" ]] || usage
      serial="$1"
      ;;
  esac
  shift
done

cd "$PROJECT_DIR"

stamp="$(date +%Y%m%d-%H%M%S)"
out_dir="$RUN_DIR/startup-${platform}-$stamp"
mkdir -p "$out_dir"

# 每轮的原始日志：Linux 是进程 stdout，Android 是从 logcat 抓的 `molia.startup` 行。
# 具体实现由 setup_linux / setup_android 里覆盖的 sampling_run / run_first_frame 提供。

# ---- Linux -----------------------------------------------------------------
setup_linux() {
  [[ -n "$timeout_s" ]] || timeout_s=60
  exe="build/linux/x64/release/bundle/$APP_BINARY"
  if (( do_build )); then
    # 只删 bundle：install 产物目录，历史上有 debug 的 kernel_blob.bin 残留在此
    # （release 不该有，会污染体积与启动观感）。中间产物保留做增量构建，也避免
    # media_kit_libs_linux 的 mimalloc 重新下载（受限网络下会失败）。
    rm -rf build/linux/x64/release/bundle
    log "构建 release：flutter build linux --release"
    flutter build linux --release || die "release 构建失败"
  fi
  [[ -x "$exe" ]] || die "找不到 release 产物：$exe"

  prefix=()
  if (( headless )); then
    command -v xvfb-run >/dev/null 2>&1 || die "缺少 xvfb-run（--window 可跳过）"
    # 只改 DISPLAY 不够：GDK 见到 WAYLAND_DISPLAY 会优先连真实合成器（同 test.sh）
    prefix=(env -u WAYLAND_DISPLAY GDK_BACKEND=x11 xvfb-run -a)
  elif ! has_display; then
    log "警告：--window 但未检测到 DISPLAY/WAYLAND_DISPLAY，仍直接跑（启动报错看日志）"
  fi

  sampling_run() { # $1=轮次 $2=日志路径
    pkill -f "$PROJECT_DIR/$exe" >/dev/null 2>&1 || true
    local cmd=("${prefix[@]}" timeout --signal=TERM --kill-after=5 "$timeout_s" "./$exe")
    "${cmd[@]}" >"$2" 2>&1 &
    local runner_pid=$!
    local deadline=$(( $(date +%s) + timeout_s ))
    while :; do
      grep -q 'molia.startup: 首帧：' "$2" 2>/dev/null && break
      kill -0 "$runner_pid" 2>/dev/null || break
      (( $(date +%s) > deadline )) && break
      sleep 0.2
    done
    sleep 1
    kill "$runner_pid" >/dev/null 2>&1 || true
    wait "$runner_pid" >/dev/null 2>&1 || true
    pkill -f "$PROJECT_DIR/$exe" >/dev/null 2>&1 || true
  }

  # 从各轮日志里取「首帧」那行，供平台无关的收尾检查用
  run_first_frame() { grep -o 'molia.startup: 首帧：[0-9]*ms' "$1" | tail -1; }
}

# ---- Android ---------------------------------------------------------------
setup_android() {
  [[ -n "$timeout_s" ]] || timeout_s=120
  ensure_adb
  if [[ -z "$serial" ]]; then
    serial="$(running_emulator)"
  fi
  [[ -n "$serial" ]] || die "没有运行中的模拟器（先执行 tool/agent/emu.sh start，或传 serial）"
  DEVICE_ID="$serial"
  adb_dev() { "$ADB" -s "$serial" "$@"; }

  # ABI → Flutter target-platform / 产物名（--split-per-abi 的命名）
  local abi; abi="$(adb_dev shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    x86_64)  flutter_target=android-x64; abi_name=x86_64 ;;
    arm64-v8a) flutter_target=android-arm64; abi_name=arm64-v8a ;;
    armeabi-v7a) flutter_target=android-arm; abi_name=armeabi-v7a ;;
    *) die "未知 ABI：$abi" ;;
  esac
  apk="build/app/outputs/flutter-apk/app-$abi_name-release.apk"

  if (( do_build )); then
    log "构建 release APK（$abi）"
    flutter build apk --release --target-platform "$flutter_target" --split-per-abi ||
      die "release APK 构建失败"
  fi
  [[ -f "$apk" ]] || die "找不到 APK：$apk"

  log "安装到 $serial（签名不一致时先卸载，会清空应用数据）"
  if ! adb_dev install -r "$apk" >/dev/null 2>&1; then
    adb_dev uninstall "$APP_ID" >/dev/null 2>&1 || true
    adb_dev install "$apk" >/dev/null 2>&1 || die "安装失败：$apk"
    log "已重装（应用数据被清空；首轮含「首次启动建库」，看中位数时留意）"
  fi

  sampling_run() { # $1=轮次 $2=日志路径
    adb_dev logcat -c >/dev/null 2>&1 || true
    local out total
    out="$(adb_dev shell am start -W -S -n "$APP_ID/.MainActivity" 2>/dev/null)"
    total="$(printf '%s\n' "$out" | awk -F': ' '/TotalTime/{print $2}' | tr -d '\r')"
    # am -W 的系统口径（进程起到首帧绘制）单独记一行，与应用自己的埋点区分开
    printf 'sampler: Activity TotalTime：%sms\n' "${total:-0}" >"$2"
    local deadline=$(( $(date +%s) + timeout_s ))
    while :; do
      sleep 1
      if adb_dev logcat -d 2>/dev/null | grep -q 'molia.startup: 首帧：'; then
        break
      fi
      (( $(date +%s) > deadline )) && break
    done
    adb_dev logcat -d 2>/dev/null | grep -o 'molia.startup: .*' >>"$2"
    sleep 1
  }

  run_first_frame() { grep -o 'molia.startup: 首帧：[0-9]*ms' "$1" | tail -1; }
}

if [[ "$platform" == "android" ]]; then
  setup_android
else
  setup_linux
fi

log "采样 $runs 次；日志目录：$out_dir"

for ((i = 1; i <= runs; i++)); do
  run_log="$out_dir/run-$i.log"
  sampling_run "$i" "$run_log"
  line="$(run_first_frame "$run_log")"
  if [[ -n "$line" ]]; then
    log "第 $i 轮：${line##*molia.startup: }"
  else
    log "第 $i 轮：未捕获首帧（日志尾部）"
    tail -5 "$run_log" >&2 || true
  fi
done

# 汇总：按阶段出现顺序取中位数（同一产物多轮采样，中位数抗抖动）
python3 - "$out_dir" <<'PY'
import glob, re, statistics, sys, os

out_dir = sys.argv[1]
pat = re.compile(r'molia\.startup: (.+?)：(\d+)ms')
total_pat = re.compile(r'sampler: Activity TotalTime：(\d+)ms')
stages, values, runs, totals = [], {}, 0, []
for path in sorted(glob.glob(os.path.join(out_dir, 'run-*.log')),
                   key=lambda p: int(re.search(r'run-(\d+)', p).group(1))):
    seen = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        m = pat.search(line)
        if m:
            seen[m.group(1)] = int(m.group(2))
        t = total_pat.search(line)
        if t:
            totals.append(int(t.group(1)))
    if '首帧' not in seen:
        continue
    runs += 1
    for stage, ms in seen.items():
        if stage not in values:
            values[stage] = []
            stages.append(stage)
        values[stage].append(ms)

if not runs:
    print('没有可用样本', file=sys.stderr)
    sys.exit(1)

def row(name, xs):
    return (f'{name:<24}{statistics.median(xs):>8.0f}{min(xs):>8}{max(xs):>8}   '
            f'{" ".join(str(x) for x in xs)}')

lines = [f'样本数: {runs}（release / 冷启动，未区分文件系统热缓存）', '']
lines.append(f"{'阶段':<24}{'中位':>8}{'最小':>8}{'最大':>8}   样本")
if totals:
    lines.append(row('Activity TotalTime', totals))
for stage in stages:
    lines.append(row(stage, values[stage]))
summary = '\n'.join(lines)
print(summary)
with open(os.path.join(out_dir, 'summary.txt'), 'w', encoding='utf-8') as fh:
    fh.write(summary + '\n')
PY

log "汇总写入 $out_dir/summary.txt"
