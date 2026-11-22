/// `perf data` 的汇总与 perf HOME 预处理（原 perf.sh 里的两段内联 Python）。
///
/// 数据链路体检的判定看应用自己打的 `molia.perf` 事件；这里只做两件事：
/// 1. 把隔离 HOME 里的窗口 bounds 固定成 1440×900（headless Xvfb 会复用上次
///    持久化的窗口尺寸，曾出现 3492×3012 把软件光栅拉满、帧与 CPU 数据失真）；
/// 2. 把 `run.log` / `data.log` 里的 `molia.perf` JSON 行聚合成分项耗时表。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// 固定窗口 bounds；文件不存在或格式不对时静默跳过（首次 perf 还没有 prefs）。
void resetPerfWindowBounds(String prefsPath) {
  final file = File(prefsPath);
  if (!file.existsSync()) return;
  Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException {
    return;
  }
  if (decoded is! Map<String, Object?>) return;
  decoded
    ..['flutter.window_bounds_x'] = 0.0
    ..['flutter.window_bounds_y'] = 0.0
    ..['flutter.window_bounds_width'] = 1440.0
    ..['flutter.window_bounds_height'] = 900.0;
  file.writeAsStringSync(jsonEncode(decoded));
}

/// 分位口径：rank 向下取整，最小 p0 / 最大 p100。
///
/// 返回值保留小数（样本就是毫秒浮点），不要在调用方 round。
double quantile(List<double> values, double p) {
  final ordered = [...values]..sort();
  final raw = (p / 100 * ordered.length + 0.999999).floor() - 1;
  final index = math.max(0, math.min(ordered.length - 1, raw));
  return ordered[index];
}

class DataReport {
  DataReport({required this.markdown, required this.sampleCount});

  final String markdown;
  final int sampleCount;

  bool get hasSamples => sampleCount > 0;
}

/// 读 `run.log` / `data.log` 里的 `molia.perf: {...}` 行并生成 summary.md。
DataReport renderDataReport(Directory directory) {
  final rows = <Map<String, Object?>>[];
  for (final name in ['run.log', 'data.log']) {
    final file = File('${directory.path}${Platform.pathSeparator}$name');
    if (!file.existsSync()) continue;
    for (final line in file.readAsLinesSync()) {
      final marker = line.indexOf('molia.perf: ');
      if (marker < 0) continue;
      final payload = line.substring(marker + 'molia.perf: '.length).trim();
      if (!payload.startsWith('{')) continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, Object?>) rows.add(decoded);
      } on FormatException {
        // 坏行（日志截断）跳过，不因为一行失败全盘报错。
      }
    }
  }

  if (rows.isEmpty) {
    return DataReport(
      markdown: '# 数据链路体检\n\n没有采到 `molia.perf` 样本。\n',
      sampleCount: 0,
    );
  }

  final ops = <String, List<double>>{};
  final events = <String, Map<String, Object?>>{};
  for (final row in rows) {
    final op = '${row['op'] ?? ''}';
    if (op.startsWith('scenario.')) {
      events[op] = row;
      continue;
    }
    ops.putIfAbsent(op, () => []).add((row['ms'] as num? ?? 0).toDouble());
  }

  final buffer = StringBuffer()
    ..writeln('# 数据链路体检（mock 音源）')
    ..writeln()
    ..writeln('## 端到端（scenario 墙钟）')
    ..writeln()
    ..writeln('| 阶段 | ms | 字段 |')
    ..writeln('| --- | ---: | --- |');
  for (final entry in events.entries) {
    final fields = <String, Object?>{
      for (final field in entry.value.entries)
        if (!const {'op', 'ms', 'ts'}.contains(field.key))
          field.key: field.value,
    };
    buffer.writeln(
      '| ${entry.key} | ${entry.value['ms'] ?? 0} | '
      '${jsonEncode(fields)} |',
    );
  }

  buffer
    ..writeln()
    ..writeln('## 分项耗时（ms）')
    ..writeln()
    ..writeln('| op | n | p50 | p95 | max |')
    ..writeln('| --- | ---: | ---: | ---: | ---: |');
  for (final entry in ops.entries) {
    final values = entry.value;
    buffer.writeln(
      '| ${entry.key} | ${values.length} | '
      '${quantile(values, 50).toStringAsFixed(2)} | '
      '${quantile(values, 95).toStringAsFixed(2)} | '
      '${values.reduce(math.max).toStringAsFixed(2)} |',
    );
  }
  buffer.writeln();
  return DataReport(markdown: buffer.toString(), sampleCount: rows.length);
}
