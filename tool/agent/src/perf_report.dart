/// `frames` 结果汇总：把 `frames*.jsonl` / `frames*.log` 里的 `molia.frame`
/// 行整理成 Markdown。
///
/// 口径：5s 周期汇总可能把长场景切成多个窗口；每个场景取**样本数最多**的
/// 窗口，同样本数优先 `label=end`。只取 `end` 会在场景超过 5s 时把很短的
/// 尾窗当成代表，严重低估（10k 收藏切换曾出现 108 帧 + 14 帧被汇总成后者）。
library;

import 'dart:convert';
import 'dart:io';

const List<String> frameColumns = [
  'scenario',
  'label',
  'frames',
  'build_p50',
  'build_p95',
  'build_p99',
  'raster_p50',
  'raster_p95',
  'raster_p99',
  'work_p50',
  'work_p95',
  'work_p99',
  'vsync_p95',
  'total_p50',
  'total_p95',
  'total_p99',
  'jank8',
  'jank16',
  'jank33',
  'latency16',
  'worst_ms',
  'image_cache_mb',
];

/// 读结果目录里的帧样本。坏行跳过（日志可能被截断），不因为一行失败全盘报错。
List<Map<String, Object?>> loadFrameRows(Directory directory) {
  final rows = <Map<String, Object?>>[];
  final files =
      directory
          .listSync()
          .whereType<File>()
          .where(
            (file) =>
                RegExp(r'^frames.*\.(jsonl|log)$')
                    .hasMatch(_basename(file.path)),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  for (final file in files) {
    if (file.path.endsWith('.jsonl')) {
      for (final line in file.readAsLinesSync()) {
        final row = _tryDecode(line.trim());
        if (row != null) rows.add(row);
      }
      continue;
    }
    for (final line in file.readAsLinesSync()) {
      final marker = line.indexOf('molia.frame');
      if (marker < 0) continue;
      var payload = line.substring(marker + 'molia.frame'.length);
      if (payload.startsWith(':')) payload = payload.substring(1);
      payload = payload.trim();
      if (payload.startsWith('molia.frame:')) {
        payload = payload.substring('molia.frame:'.length).trim();
      }
      final row = _tryDecode(payload);
      if (row != null) rows.add(row);
    }
  }
  return rows;
}

Map<String, Object?>? _tryDecode(String text) {
  if (text.isEmpty || !text.startsWith('{')) return null;
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

String _basename(String path) => path.split(Platform.pathSeparator).last;

/// 场景窗口的帧数（缺失按 0）。
int _frameCount(Map<String, Object?> row) =>
    (row['frames'] as num?)?.toInt() ?? 0;

/// 长场景被 5s 周期汇总切成多段时，取样本最多的一段；同数优先显式 `end`。
bool _preferWindow(
  Map<String, Object?> candidate,
  Map<String, Object?> current,
) {
  final candidateFrames = _frameCount(candidate);
  final currentFrames = _frameCount(current);
  if (candidateFrames != currentFrames) {
    return candidateFrames > currentFrames;
  }
  return candidate['label'] == 'end' && current['label'] != 'end';
}

/// 生成 summary.md 内容。空样本也给出明确结论，避免误以为是脚本失败。
String renderFrameSummary(List<Map<String, Object?>> rows) {
  if (rows.isEmpty) {
    return '# 性能体检\n\n没有采到 `molia.frame` 样本。\n';
  }

  final byScenario = <String, Map<String, Object?>>{};
  for (final row in rows) {
    final scenario = (row['scenario'] ?? 'app').toString();
    final existing = byScenario[scenario];
    if (existing == null || _preferWindow(row, existing)) {
      byScenario[scenario] = row;
    }
  }

  final buffer = StringBuffer()
    ..writeln('# 性能体检：帧样本')
    ..writeln()
    ..writeln('## 场景汇总（每个场景取样本最多的窗口；同数优先 end）')
    ..writeln()
    ..writeln(_tableHeader());
  for (final row in byScenario.values) {
    buffer.writeln(_tableRow(row));
  }
  buffer
    ..writeln()
    ..writeln('## 原始窗口')
    ..writeln()
    ..writeln(_tableHeader());
  for (final row in rows) {
    buffer.writeln(_tableRow(row));
  }
  return buffer.toString();
}

String _tableHeader() =>
    '| ${frameColumns.join(' | ')} |\n| ${frameColumns.map((_) => '---').join(' | ')} |';

String _tableRow(Map<String, Object?> row) =>
    '| ${frameColumns.map((column) => row[column] ?? '').join(' | ')} |';
