#!/usr/bin/env bash
# 启动耗时采样：release（AOT）冷启动跑 N 次，抓 `molia.startup` 各阶段取中位数
#
# 用法:
#   tool/agent/startup.sh                # 构建 release 后跑 5 次（无显示时 xvfb-run）
#   tool/agent/startup.sh --runs 9       # 采样次数
#   tool/agent/startup.sh --no-build     # 复用已有产物，只重测
#   tool/agent/startup.sh --window       # 在真实 DISPLAY/WAYLAND_DISPLAY 上跑
#   tool/agent/startup.sh --timeout 90   # 单次运行的墙钟上限（默认 60s）
#
# 设计说明:
# - 只认 release 产物：debug 的首帧含 JIT/断言开销，不能代表用户可感时长
#   （历史 debug 数据 1.5–2.4s，release 会显著更低）；
# - 判定看进程自己打的 `molia.startup` 阶段行（main.dart 的埋点，release 也输出）
#   「首帧」那行即用户可感总时长；
# - 每次运行独立进程 + 单实例关闭（_common.sh 的 MOLIA_SINGLE_INSTANCE_DISABLED），
#   跑完 TERM 掉再下一轮；采样不做热缓存区分，中位数对「改前/改后」是可比的；
# - 原始日志与 summary.txt 落在 $RUN_DIR/startup-<时间戳>/，供 docs/performance.md 引用。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

usage() {
  cat >&2 <<'EOF'
用法:
  startup.sh [--runs N] [--no-build] [--window] [--timeout 秒]

选项:
  --runs N       采样次数（默认 5）
  --no-build     跳过 flutter build linux --release
  --window       在真实显示上跑（默认无显示时套 xvfb-run）
  --timeout 秒   单次运行墙钟上限（默认 60）
EOF
  exit 2
}

runs=5
do_build=1
headless=1
timeout_s=60

while (($#)); do
  case "$1" in
    --runs) runs="$2"; shift ;;
    --no-build) do_build=0 ;;
    --window) headless=0 ;;
    --timeout) timeout_s="$2"; shift ;;
    -*) usage ;;
    *) usage ;;
  esac
  shift
done

cd "$PROJECT_DIR"

exe="build/linux/x64/release/bundle/$APP_BINARY"

if (( do_build )); then
  # 只删 bundle：它是 install 阶段的产物目录，历史上有 debug 的 kernel_blob.bin
  # 残留在 bundle/data/flutter_assets 里（release 不该有，会污染体积与启动观感）。
  # 中间产物保留（增量构建；也避免 media_kit_libs_linux 的 mimalloc 重新下载）。
  rm -rf build/linux/x64/release/bundle
  log "构建 release：flutter build linux --release"
  flutter build linux --release || die "release 构建失败"
fi

[[ -x "$exe" ]] || die "找不到 release 产物：$exe（先执行 startup.sh，或去掉 --no-build）"

prefix=()
if (( headless )); then
  if has_display; then
    log "检测到真实显示；默认仍走 xvfb（--window 可切真实显示）"
  fi
  command -v xvfb-run >/dev/null 2>&1 || die "缺少 xvfb-run（--window 可跳过）"
  # 只改 DISPLAY 不够：GDK 见到 WAYLAND_DISPLAY 会优先连真实合成器（同 test.sh）
  prefix=(env -u WAYLAND_DISPLAY GDK_BACKEND=x11 xvfb-run -a)
elif ! has_display; then
  log "警告：--window 但未检测到 DISPLAY/WAYLAND_DISPLAY，仍直接跑（启动报错看日志）"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
out_dir="$RUN_DIR/startup-$stamp"
mkdir -p "$out_dir"

log "采样 $runs 次（产物：$exe）；日志目录：$out_dir"

for ((i = 1; i <= runs; i++)); do
  run_log="$out_dir/run-$i.log"
  # 残留实例会让下一次变成「第二实例秒退」，先清干净
  pkill -f "$PROJECT_DIR/$exe" >/dev/null 2>&1 || true

  cmd=("${prefix[@]}" timeout --signal=TERM --kill-after=5 "$timeout_s" "./$exe")
  "${cmd[@]}" >"$run_log" 2>&1 &
  runner_pid=$!

  # 等到首帧行出现即认为用户可感启动完成（再多留 1s 让阶段日志落齐）
  deadline=$(( $(date +%s) + timeout_s ))
  ok=0
  while :; do
    if grep -q 'molia.startup: 首帧：' "$run_log" 2>/dev/null; then
      ok=1
      break
    fi
    if ! kill -0 "$runner_pid" 2>/dev/null; then
      break
    fi
    if (( $(date +%s) > deadline )); then
      break
    fi
    sleep 0.2
  done
  sleep 1

  kill "$runner_pid" >/dev/null 2>&1 || true
  wait "$runner_pid" >/dev/null 2>&1 || true
  pkill -f "$PROJECT_DIR/$exe" >/dev/null 2>&1 || true

  if (( ok )); then
    line="$(grep -m1 'molia.startup: 首帧：' "$run_log")"
    log "第 $i 轮：${line##*molia.startup: }"
  else
    log "第 $i 轮：未捕获首帧（日志尾部）"
    tail -5 "$run_log" >&2 || true
  fi
done

# 汇总：按阶段出现顺序取中位数（同一产物多轮采样，比较用中位数抗抖动）
python3 - "$out_dir" <<'PY'
import glob, re, statistics, sys, os

out_dir = sys.argv[1]
pat = re.compile(r'molia\.startup: (.+?)：(\d+)ms')
stages, values, runs = [], {}, 0
for path in sorted(glob.glob(os.path.join(out_dir, 'run-*.log')),
                   key=lambda p: int(re.search(r'run-(\d+)', p).group(1))):
    seen = {}
    for line in open(path, encoding='utf-8', errors='replace'):
        m = pat.search(line)
        if m:
            seen[m.group(1)] = int(m.group(2))
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

lines = [f'样本数: {runs}（release / 冷启动，未区分文件系统热缓存）', '']
lines.append(f"{'阶段':<24}{'中位':>8}{'最小':>8}{'最大':>8}   样本")
for stage in stages:
    xs = values[stage]
    lines.append(f'{stage:<24}{statistics.median(xs):>8.0f}{min(xs):>8}{max(xs):>8}   '
                 f'{" ".join(str(x) for x in values[stage])}')
summary = '\n'.join(lines)
print(summary)
with open(os.path.join(out_dir, 'summary.txt'), 'w', encoding='utf-8') as fh:
    fh.write(summary + '\n')
PY

log "汇总写入 $out_dir/summary.txt"
