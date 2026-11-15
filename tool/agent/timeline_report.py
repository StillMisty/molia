#!/usr/bin/env python3
"""把 VM timeline trace 汇总成帧归因表（DevTools Performance 的机器可读版本）。

输入是 `tool/agent/perf.sh frames <平台> --timeline` 收到的 timeline.json：
`integration_test` 的 `traceAction` 把 VM service trace 交给 driver，driver 落在
`build/integration_response_data.json`。格式与 Chrome tracing 一致：

    {"type": "Timeline", "traceEvents": [{"name": ..., "ph": ..., "ts": ..., ...}]}

为什么不用 DevTools 手点：体检要能反复跑、能对比。这里只做 DevTools 做不了
的自动化部分——把 UI 帧拆成框架阶段（BUILD / LAYOUT / PAINT / SEMANTICS…）
给出百分位与最差帧归因；原始 trace 原样保留，要看火焰图时直接导入 DevTools
Performance 或 Perfetto。

用法:
    python3 tool/agent/timeline_report.py <timeline.json> [输出.md]
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

# 引擎 / 框架的固定事件名（与 flutter_driver 的 TimelineSummary 同源）。
BUILD_EVENT = "Frame"
RASTER_EVENT = "GPURasterizer::Draw"
# 框架在 UI 帧内 startSync 的阶段名。同一阶段还有 "X (root)" 变体：那是
# 包住整棵树的父事件，取非 root 的叶子事件避免重复计时。
PHASES = ("BUILD", "LAYOUT", "PAINT", "COMPOSITING", "SEMANTICS", "FINALIZE TREE")
GC_EVENTS = ("Scavenge", "CollectNewGeneration", "CollectOldGeneration")

# 60Hz / 30Hz 的帧预算：16.7ms 掉 1 帧，33.3ms 掉 2 帧。绝对数只做相对比较
# （模拟器 / 软件渲染会整体放大），口径与 docs/performance.md 一致。
BUDGET_60HZ_US = 16_700
BUDGET_30HZ_US = 33_300
WORST_FRAMES = 8


def load_events(path: Path) -> tuple[list[dict], str]:
    data = json.loads(path.read_text())
    # 兼容三种形态：driver 的 {"timeline": {...}}、trace 对象、裸事件数组。
    source = "timeline"
    if isinstance(data, dict) and "traceEvents" not in data:
        for key in ("timeline", "performance"):
            if isinstance(data.get(key), dict):
                data, source = data[key], key
                break
    events = data.get("traceEvents") if isinstance(data, dict) else data
    return events or [], source


def to_intervals(events: list[dict]) -> list[dict]:
    """把 begin/end 配对与 X 完整事件统一成 {name, cat, tid, ts, dur}。

    引擎与 Dart VM 的相位字母不一致：Embedder 用大写 B/E，Dart timeline 用
    小写 b/e（带 id，可交错）。两者都接受，并按 (pid, tid, name, id) 配对，
    避免同名事件嵌套时错配。
    """
    out: list[dict] = []
    open_stacks: dict[tuple, list[dict]] = {}
    for event in events:
        phase = event.get("ph")
        key = (event.get("pid"), event.get("tid"), event.get("name"), event.get("id"))
        if phase == "X" and "dur" in event:
            out.append(event)
        elif phase in ("B", "b"):
            open_stacks.setdefault(key, []).append(event)
        elif phase in ("E", "e"):
            stack = open_stacks.get(key)
            if not stack:
                continue
            begin = stack.pop()
            out.append({
                **begin,
                "dur": event.get("ts", 0) - begin.get("ts", 0),
            })
    return out


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    index = max(0, math.ceil(p / 100 * len(ordered)) - 1)
    return ordered[min(index, len(ordered) - 1)]


def ms(microseconds: float) -> str:
    return f"{microseconds / 1000:.2f}"


def pick(intervals: list[dict], name: str) -> list[dict]:
    return [
        event
        for event in intervals
        if event.get("name") == name and event.get("dur") is not None
    ]


def children_of(frame: dict, intervals: list[dict]) -> list[dict]:
    """同一线程、完整落在帧窗口内的子事件，用于最差帧归因。"""
    start = frame.get("ts", 0)
    end = start + frame.get("dur", 0)
    children = []
    for event in intervals:
        if event is frame or event.get("tid") != frame.get("tid"):
            continue
        ts, dur = event.get("ts"), event.get("dur")
        if ts is None or dur is None or dur <= 0:
            continue
        if ts >= start and ts + dur <= end and event.get("name") != BUILD_EVENT:
            children.append(event)
    return children


def phase_values(frames: list[dict], intervals: list[dict]) -> dict[str, list[float]]:
    """每帧内每个阶段的耗时（同一帧里同阶段取最长，避免嵌套重复计时）。"""
    by_name = {name: [] for name in PHASES}
    for frame in frames:
        seen: dict[str, int] = {}
        for child in children_of(frame, intervals):
            name = (child.get("name") or "").removesuffix(" (root)")
            if name in seen:
                seen[name] = max(seen[name], child.get("dur", 0))
            else:
                seen[name] = child.get("dur", 0)
        for name, dur in seen.items():
            if name in by_name:
                by_name[name].append(dur)
    return by_name


def top_children(children: list[dict], limit: int = 3) -> str:
    if not children:
        return ""
    labels = sorted(children, key=lambda e: e.get("dur", 0), reverse=True)[:limit]
    return ", ".join(
        f"{e.get('name')}({ms(e.get('dur', 0))}ms)" for e in labels
    )


def summary_table(rows: list[tuple[str, list[float]]]) -> list[str]:
    lines = [
        "| 阶段 | p50 | p90 | p95 | p99 | max | 超 16.7ms | 超 33.3ms |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for label, values in rows:
        if not values:
            lines.append(f"| {label} | - | - | - | - | - | - | - |")
            continue
        lines.append(
            "| {} | {} | {} | {} | {} | {} | {} | {} |".format(
                label,
                ms(percentile(values, 50)),
                ms(percentile(values, 90)),
                ms(percentile(values, 95)),
                ms(percentile(values, 99)),
                ms(max(values)),
                sum(1 for value in values if value > BUDGET_60HZ_US),
                sum(1 for value in values if value > BUDGET_30HZ_US),
            )
        )
    return lines


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    out_path = Path(sys.argv[2]) if len(sys.argv) > 2 else None

    events, source = load_events(path)
    intervals = to_intervals(events)
    frames = pick(intervals, BUILD_EVENT)
    rasters = pick(intervals, RASTER_EVENT)

    if not frames:
        text = (
            "# Timeline 归因\n\n"
            f"没有 `{BUILD_EVENT}` 事件：trace 太短，或场景没有真的出帧。\n"
            "先确认 `flutter drive` 的 target 是 `integration_test/perf_timeline_test.dart`，"
            "并检查结果目录里的 drive.log。\n"
        )
        if out_path:
            out_path.write_text(text)
            print(f"timeline 归因（无帧）-> {out_path}")
        else:
            print(text)
        return 1

    frame_us = [frame["dur"] for frame in frames]
    raster_us = [raster["dur"] for raster in rasters]
    phases = phase_values(frames, intervals)

    load_p50 = percentile(frame_us, 50)
    lines = [
        "# Timeline 归因（VM service trace）",
        "",
        f"- trace: `{path.name}`（{len(events)} 个事件，来源键 `{source}`）",
        f"- UI 帧: {len(frames)}，光栅 Draw: {len(rasters)}",
        "- GC: "
        + "，".join(
            f"{name} {sum(1 for e in intervals if e.get('name') == name)}"
            for name in GC_EVENTS
        ),
        "",
        "## 帧耗时",
        "",
        *summary_table([("UI 帧（Frame）", frame_us), ("光栅（Draw）", raster_us)]),
        "",
        "光栅列只含 `GPURasterizer::Draw` 的 CPU 侧提交：Impeller / 桌面下 GPU 时间",
        "不进这条事件，接近 0 属正常；跨平台对比看 UI 帧与下面的阶段拆分。",
        "",
        "## UI 帧内阶段",
        "",
        "| 阶段 | p50 | p95 | max | 占 UI 帧 p50 |",
        "| --- | --- | --- | --- | --- |",
    ]
    for name in PHASES:
        values = phases[name]
        if not values:
            continue
        share = percentile(values, 50) / load_p50 * 100 if load_p50 else 0
        lines.append(
            "| {} | {} | {} | {} | {}% |".format(
                name,
                ms(percentile(values, 50)),
                ms(percentile(values, 95)),
                ms(max(values)),
                f"{share:.0f}",
            )
        )

    lines += [
        "",
        f"## 最差帧（UI 帧 Top {WORST_FRAMES}）",
        "",
        "| # | 起点(ms) | UI 帧(ms) | 主要子事件 |",
        "| --- | --- | --- | --- |",
    ]
    origin = min(frame.get("ts", 0) for frame in frames)
    for rank, frame in enumerate(
        sorted(frames, key=lambda e: e.get("dur", 0), reverse=True)[:WORST_FRAMES], 1
    ):
        lines.append(
            "| {} | {} | {} | {} |".format(
                rank,
                f"{(frame.get('ts', 0) - origin) / 1000:.1f}",
                ms(frame.get("dur", 0)),
                top_children(children_of(frame, intervals)),
            )
        )

    lines += [
        "",
        "## 怎么继续看",
        "",
        "- 火焰图 / 逐帧时间线：把 `timeline.json` 导入 DevTools Performance 或 "
        "ui.perfetto.dev（同一份 trace，脚本只做汇总）；",
        "- 阶段占比高的是 LAYOUT / SEMANTICS 时，先看该场景是否在无谓地重建语义树"
        "（TalkBack / 无障碍服务未开启时也应尽量少变）；",
        "- BUILD 高：看 provider 通知范围与列表项 rebuild；PAINT 高：看图层与图片解码；",
        "- 两档预算只做相对比较：模拟器与软件渲染会整体放大。",
        "",
    ]

    text = "\n".join(lines)
    if out_path:
        out_path.write_text(text)
        print(f"timeline 归因 -> {out_path}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
