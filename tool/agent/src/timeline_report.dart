/// VM timeline trace 的帧归因汇总（DevTools 同源 trace 的机器可读汇总）。
///
/// 输入是 `perf.sh frames <平台> --timeline` 收到的 timeline.json：
/// `traceAction` 把 VM service trace 交给 driver，落在
/// `build/integration_response_data.json`。只做 DevTools 做不了的自动化部分：
/// UI 帧拆成框架阶段给百分位与最差帧归因；原始 trace 原样保留，要看火焰图
/// 直接导入 DevTools Performance / Perfetto。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const String buildEvent = 'Frame';
const String rasterEvent = 'GPURasterizer::Draw';

/// 框架在 UI 帧内 startSync 的阶段名。同一阶段还有 "X (root)" 变体：那是
/// 包住整棵树的父事件，取非 root 的叶子事件避免重复计时。
const List<String> phases = [
  'BUILD',
  'LAYOUT',
  'PAINT',
  'COMPOSITING',
  'SEMANTICS',
  'FINALIZE TREE',
];

const List<String> gcEvents = [
  'Scavenge',
  'CollectNewGeneration',
  'CollectOldGeneration',
];

const int budget60hzUs = 16700;
const int budget30hzUs = 33300;
const int worstFrames = 8;

class _Interval {
  _Interval({
    required this.name,
    required this.tid,
    required this.ts,
    required this.dur,
  });

  final String name;
  final int tid;
  final int ts;
  final int dur;
}

/// 解析 timeline.json；返回事件条数供日志使用。
({List<Map<String, Object?>> events, String source}) loadTimeline(File file) {
  final data = jsonDecode(file.readAsStringSync());
  var source = 'timeline';
  Object? payload = data;
  if (data is Map && !data.containsKey('traceEvents')) {
    for (final key in ['timeline', 'performance']) {
      if (data[key] is Map) {
        payload = data[key];
        source = key;
        break;
      }
    }
  }
  if (payload is Map) {
    final events = payload['traceEvents'];
    return (
      events: events is List
          ? events.whereType<Map<String, Object?>>().toList()
          : const [],
      source: source,
    );
  }
  if (payload is List) {
    return (
      events: payload.whereType<Map<String, Object?>>().toList(),
      source: source,
    );
  }
  return (events: const [], source: source);
}

/// 把 begin/end 配对与 X 完整事件统一成 (name, tid, ts, dur)。
///
/// 引擎与 Dart VM 的相位字母不一致：Embedder 用大写 B/E，Dart timeline 用
/// 小写 b/e（带 id，可交错）。两者都接受，并按 (pid, tid, name, id) 配对。
List<_Interval> _toIntervals(List<Map<String, Object?>> events) {
  final out = <_Interval>[];
  final open = <String, List<Map<String, Object?>>>{};
  for (final event in events) {
    final phase = event['ph'];
    final key =
        '${event['pid']}|${event['tid']}|${event['name']}|${event['id']}';
    if (phase == 'X' && event['dur'] is int) {
      out.add(_toInterval(event, event['dur'] as int));
    } else if (phase == 'B' || phase == 'b') {
      open.putIfAbsent(key, () => []).add(event);
    } else if (phase == 'E' || phase == 'e') {
      final stack = open[key];
      if (stack == null || stack.isEmpty) continue;
      final begin = stack.removeLast();
      final ts = begin['ts'] as int? ?? 0;
      final end = event['ts'] as int? ?? ts;
      out.add(_toInterval(begin, end - ts));
    }
  }
  return out;
}

_Interval _toInterval(Map<String, Object?> event, int dur) => _Interval(
  name: event['name'] as String? ?? '',
  tid: event['tid'] as int? ?? 0,
  ts: event['ts'] as int? ?? 0,
  dur: dur,
);

double percentile(List<int> values, double p) {
  if (values.isEmpty) return double.nan;
  final ordered = [...values]..sort();
  final index = math.max(0, (p / 100 * ordered.length).ceil() - 1);
  return ordered[math.min(index, ordered.length - 1)].toDouble();
}

String _ms(num microseconds) => (microseconds / 1000).toStringAsFixed(2);

List<_Interval> _pick(List<_Interval> intervals, String name) =>
    intervals.where((interval) => interval.name == name).toList();

List<_Interval> _childrenOf(_Interval frame, List<_Interval> intervals) {
  final end = frame.ts + frame.dur;
  return intervals.where((event) {
    return event != frame &&
        event.tid == frame.tid &&
        event.dur > 0 &&
        event.ts >= frame.ts &&
        event.ts + event.dur <= end &&
        event.name != buildEvent;
  }).toList();
}

String _topChildren(List<_Interval> children, {int limit = 3}) {
  if (children.isEmpty) return '';
  final labels = [...children]..sort((a, b) => b.dur.compareTo(a.dur));
  return labels
      .take(limit)
      .map((event) => '${event.name}(${_ms(event.dur)}ms)')
      .join(', ');
}

/// 生成 summary.md 内容。没有帧事件时返回错误说明（调用方据此退出 1）。
({String markdown, bool ok}) renderTimelineReport(File file) {
  final loaded = loadTimeline(file);
  final intervals = _toIntervals(loaded.events);
  final frames = _pick(intervals, buildEvent);
  final rasters = _pick(intervals, rasterEvent);

  if (frames.isEmpty) {
    return (
      ok: false,
      markdown:
          '# Timeline 归因\n\n'
          '没有 `$buildEvent` 事件：trace 太短，或场景没有真的出帧。\n'
          '先确认 `flutter drive` 的 target 是 `integration_test/perf_timeline_test.dart`，'
          '并检查结果目录里的 drive.log。\n',
    );
  }

  final frameUs = frames.map((frame) => frame.dur).toList();
  final rasterUs = rasters.map((raster) => raster.dur).toList();
  final loadP50 = percentile(frameUs, 50);

  final buffer = StringBuffer()
    ..writeln('# Timeline 归因（VM service trace）')
    ..writeln()
    ..writeln(
      '- trace: `${file.uri.pathSegments.last}`（${loaded.events.length} 个事件，'
      '来源键 `${loaded.source}`）',
    )
    ..writeln('- UI 帧: ${frames.length}，光栅 Draw: ${rasters.length}')
    ..writeln(
      '- GC: ${gcEvents.map((name) => '$name ${intervals.where((e) => e.name == name).length}').join('，')}',
    )
    ..writeln()
    ..writeln('## 帧耗时')
    ..writeln()
    ..write(_summaryTable([('UI 帧（Frame）', frameUs), ('光栅（Draw）', rasterUs)]))
    ..writeln()
    ..writeln('光栅列只含 `GPURasterizer::Draw` 的 CPU 侧提交：Impeller / 桌面下 GPU 时间')
    ..writeln('不进这条事件，接近 0 属正常；跨平台对比看 UI 帧与下面的阶段拆分。')
    ..writeln()
    ..writeln('## UI 帧内阶段')
    ..writeln()
    ..writeln('| 阶段 | p50 | p95 | max | 占 UI 帧 p50 |')
    ..writeln('| --- | --- | --- | --- | --- |');

  for (final name in phases) {
    final values = <int>[];
    for (final frame in frames) {
      int? longest;
      for (final child in _childrenOf(frame, intervals)) {
        final normalized = child.name.replaceFirst(RegExp(r' \(root\)$'), '');
        if (normalized != name) continue;
        longest = longest == null ? child.dur : math.max(longest, child.dur);
      }
      if (longest != null) values.add(longest);
    }
    if (values.isEmpty) continue;
    final share = loadP50 == 0 ? 0 : percentile(values, 50) / loadP50 * 100;
    buffer.writeln(
      '| $name | ${_ms(percentile(values, 50))} | '
      '${_ms(percentile(values, 95))} | ${_ms(values.reduce(math.max))} | '
      '${share.toStringAsFixed(0)}% |',
    );
  }

  final sortedFrames = [...frames]..sort((a, b) => b.dur.compareTo(a.dur));
  final origin = frames.map((frame) => frame.ts).reduce(math.min);
  buffer
    ..writeln()
    ..writeln('## 最差帧（UI 帧 Top $worstFrames）')
    ..writeln()
    ..writeln('| # | 起点(ms) | UI 帧(ms) | 主要子事件 |')
    ..writeln('| --- | --- | --- | --- |');
  for (
    var index = 0;
    index < math.min(worstFrames, sortedFrames.length);
    index++
  ) {
    final frame = sortedFrames[index];
    buffer.writeln(
      '| ${index + 1} | ${((frame.ts - origin) / 1000).toStringAsFixed(1)} | '
      '${_ms(frame.dur)} | ${_topChildren(_childrenOf(frame, intervals))} |',
    );
  }

  buffer
    ..writeln()
    ..writeln('## 怎么继续看')
    ..writeln()
    ..writeln(
      '- 火焰图 / 逐帧时间线：把 `timeline.json` 导入 DevTools Performance 或 '
      'ui.perfetto.dev（同一份 trace，脚本只做汇总）；',
    )
    ..writeln(
      '- 阶段占比高的是 LAYOUT / SEMANTICS 时，先看该场景是否在无谓地重建语义树'
      '（TalkBack / 无障碍服务未开启时也应尽量少变）；',
    )
    ..writeln('- BUILD 高：看 provider 通知范围与列表项 rebuild；PAINT 高：看图层与图片解码；')
    ..writeln('- 两档预算只做相对比较：模拟器与软件渲染会整体放大。');
  return (ok: true, markdown: buffer.toString());
}

String _summaryTable(List<(String, List<int>)> rows) {
  final buffer = StringBuffer()
    ..writeln('| 阶段 | p50 | p90 | p95 | p99 | max | 超 16.7ms | 超 33.3ms |')
    ..writeln('| --- | --- | --- | --- | --- | --- | --- | --- |');
  for (final (label, values) in rows) {
    if (values.isEmpty) {
      buffer.writeln('| $label | - | - | - | - | - | - | - |');
      continue;
    }
    buffer.writeln(
      '| $label | ${_ms(percentile(values, 50))} | '
      '${_ms(percentile(values, 90))} | ${_ms(percentile(values, 95))} | '
      '${_ms(percentile(values, 99))} | ${_ms(values.reduce(math.max))} | '
      '${values.where((value) => value > budget60hzUs).length} | '
      '${values.where((value) => value > budget30hzUs).length} |',
    );
  }
  return buffer.toString();
}
