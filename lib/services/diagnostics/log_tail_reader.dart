/// 只读最近日志的尾部读取器（活动文件 + 轮转归档）。
///
/// 只读磁盘、不挂日志流：页面与诊断包按需读取最近 [maxBytes] 字节，避免把
/// 整份日志载入内存。解析按 [RotatingFileLogSink] 的落盘格式：
/// `YYYY-MM-DD HH:MM:SS.mmm LEVEL   logger: message`，随后不以时间戳开头的
/// 行（error / stack）并入上一条记录的 detail。读取后再次脱敏，防止历史
/// 日志里残留旧版本未处理的密钥。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/models/diagnostics.dart';
import 'redaction.dart';

/// 日志目录由组合根注入（测试可直接给临时目录）；null 表示不可用。
typedef DiagnosticLogDirectoryProvider = Future<Directory?> Function();

class LogTailReader {
  LogTailReader({
    required this.directory,
    this.maxBytes = 512 * 1024,
    this.maxEntries = 500,
  }) : assert(maxBytes > 0),
       assert(maxEntries > 0);

  final DiagnosticLogDirectoryProvider directory;
  final int maxBytes;
  final int maxEntries;

  /// 读取并解析最近日志（旧 → 新，最多 [maxEntries] 条）。
  ///
  /// 目录 / 单文件读取失败只返回已读到的部分；不向调用方抛异常。
  Future<List<DiagnosticLogEntry>> read() async {
    Directory? dir;
    try {
      dir = await directory();
    } catch (_) {
      return const [];
    }
    if (dir == null) return const [];
    final List<File> files;
    try {
      if (!await dir.exists()) return const [];
      files = await _newestFirst(dir);
    } catch (_) {
      return const [];
    }

    final chunks = <String>[];
    var budget = maxBytes;
    for (final file in files) {
      if (budget <= 0) break;
      final text = await _readTail(file, budget);
      if (text == null || text.isEmpty) continue;
      chunks.add(text);
      budget -= utf8.encode(text).length;
    }
    if (chunks.isEmpty) return const [];
    // 读取顺序是新 → 旧；拼接成旧 → 新再解析。
    var text = chunks.reversed.join();
    if (!text.endsWith('\n')) {
      // 活动文件可能正写到一半：丢掉没有换行结尾的末行，避免产出截断记录。
      final cut = text.lastIndexOf('\n');
      text = cut < 0 ? '' : text.substring(0, cut + 1);
    }
    final entries = _parse(text);
    if (entries.length <= maxEntries) {
      return List<DiagnosticLogEntry>.unmodifiable(entries);
    }
    return List<DiagnosticLogEntry>.unmodifiable(
      entries.sublist(entries.length - maxEntries),
    );
  }

  /// 读取并按级别 / 关键词过滤后渲染纯文本（UI 复制 / 预览用）。
  Future<String> readText({String? level, String? keyword}) async =>
      renderLogEntries(
        filterLogEntries(await read(), level: level, keyword: keyword),
      );

  /// 活动文件优先，随后 `molia.1.log`、`molia.2.log` …（越大越旧）。
  Future<List<File>> _newestFirst(Directory directory) async {
    final found = <({int order, File file})>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == 'molia.log') {
        found.add((order: 0, file: entity));
        continue;
      }
      final match = RegExp(r'^molia\.(\d+)\.log$').firstMatch(name);
      if (match == null) continue;
      found.add((order: int.parse(match.group(1)!), file: entity));
    }
    found.sort((a, b) => a.order.compareTo(b.order));
    return [for (final entry in found) entry.file];
  }

  Future<String?> _readTail(File file, int budget) async {
    try {
      final length = await file.length();
      if (length == 0) return '';
      final start = length > budget ? length - budget : 0;
      final handle = await file.open();
      try {
        await handle.setPosition(start);
        final bytes = await handle.read(length - start);
        var text = utf8.decode(bytes, allowMalformed: true);
        if (start > 0) {
          // 从字节中间开始：丢掉半行，只保留完整记录。
          final newline = text.indexOf('\n');
          text = newline < 0 ? '' : text.substring(newline + 1);
        }
        return text;
      } finally {
        await handle.close();
      }
    } catch (_) {
      return null;
    }
  }

  static final RegExp _header = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3}) '
    r'([A-Z]+)\s+(\S+): ?(.*)$',
  );

  List<DiagnosticLogEntry> _parse(String text) {
    final entries = <DiagnosticLogEntry>[];
    final detail = <String>[];

    void flushDetail() {
      if (entries.isEmpty || detail.isEmpty) {
        detail.clear();
        return;
      }
      final last = entries.removeLast();
      entries.add(
        DiagnosticLogEntry(
          time: last.time,
          level: last.level,
          logger: last.logger,
          message: last.message,
          detail: redactSecrets(detail.join('\n')),
        ),
      );
      detail.clear();
    }

    for (final rawLine in text.split('\n')) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;
      final match = _header.firstMatch(line);
      if (match == null) {
        if (entries.isNotEmpty && line.isNotEmpty) detail.add(line);
        continue;
      }
      flushDetail();
      final time = DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!),
        int.parse(match.group(6)!),
        int.parse(match.group(7)!),
      );
      entries.add(
        DiagnosticLogEntry(
          time: time,
          level: match.group(8)!,
          logger: match.group(9)!,
          message: redactSecrets(match.group(10)!),
        ),
      );
    }
    flushDetail();
    return entries;
  }
}

/// 按级别（精确，大小写不敏感）与关键词过滤；keyword 同时匹配 logger。
List<DiagnosticLogEntry> filterLogEntries(
  Iterable<DiagnosticLogEntry> entries, {
  String? level,
  String? keyword,
}) {
  final normalizedLevel = level?.trim().toUpperCase();
  final needle = keyword?.trim() ?? '';
  return [
    for (final entry in entries)
      if ((normalizedLevel == null ||
              normalizedLevel.isEmpty ||
              entry.level.toUpperCase() == normalizedLevel) &&
          entry.matchesKeyword(needle))
        entry,
  ];
}

/// 纯文本渲染（页面「复制 / 预览」与测试共用）；输出再次脱敏。
String renderLogEntries(Iterable<DiagnosticLogEntry> entries) {
  final buffer = StringBuffer();
  for (final entry in entries) {
    buffer
      ..write(_formatTime(entry.time))
      ..write(' ')
      ..write(entry.level.padRight(7))
      ..write(' ')
      ..write(entry.logger)
      ..write(': ')
      ..writeln(entry.message);
    final detail = entry.detail;
    if (detail != null && detail.isNotEmpty) {
      for (final line in detail.split('\n')) {
        buffer
          ..write('    ')
          ..writeln(line);
      }
    }
  }
  return redactSecrets(buffer.toString());
}

String _formatTime(DateTime time) {
  String two(int value) => value < 10 ? '0$value' : '$value';
  String three(int value) =>
      value < 10 ? '00$value' : (value < 100 ? '0$value' : '$value');
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-'
      '${two(time.day)} ${two(time.hour)}:${two(time.minute)}:'
      '${two(time.second)}.${three(time.millisecond)}';
}
