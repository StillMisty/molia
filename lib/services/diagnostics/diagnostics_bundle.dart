/// 诊断包的纯文本组装（纯 Dart，无 I/O / Flutter / 网络）。
///
/// 输入全部来自注入的快照：应用信息、允许导出的设置、渠道能力、最近失败、
/// 健康检查、数据库计数与已读取的日志行。组装只做格式化与最后一道脱敏，
/// 不查设置、不读数据库、不发请求——这些由导出器在调用前完成。
library;

import 'dart:convert';

import '../../domain/models/diagnostics.dart';
import 'redaction.dart';

/// 诊断包默认硬上限（20 MB）；日志段超限时保留最新内容并声明省略字节。
const int defaultDiagnosticsBundleMaxBytes = 20 * 1024 * 1024;

/// 应用 / 运行环境（不含设备名、账号或唯一标识）。
class DiagnosticsAppInfo {
  const DiagnosticsAppInfo({
    this.version = 'unknown',
    this.buildNumber = 'unknown',
    this.packageName = 'unknown',
    this.platform = 'unknown',
    this.osVersion = 'unknown',
    this.abi = 'unknown',
    this.locale = 'unknown',
    this.buildMode = 'unknown',
    this.updateChannel = 'unknown',
    this.updateAutoCheck = false,
    this.screenWidth,
    this.screenHeight,
    this.devicePixelRatio,
  });

  final String version;
  final String buildNumber;
  final String packageName;
  final String platform;
  final String osVersion;
  final String abi;
  final String locale;
  final String buildMode;
  final String updateChannel;
  final bool updateAutoCheck;
  final double? screenWidth;
  final double? screenHeight;
  final double? devicePixelRatio;

  DiagnosticsAppInfo copyWith({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) => DiagnosticsAppInfo(
    version: version,
    buildNumber: buildNumber,
    packageName: packageName,
    platform: platform,
    osVersion: osVersion,
    abi: abi,
    locale: locale,
    buildMode: buildMode,
    updateChannel: updateChannel,
    updateAutoCheck: updateAutoCheck,
    screenWidth: screenWidth ?? this.screenWidth,
    screenHeight: screenHeight ?? this.screenHeight,
    devicePixelRatio: devicePixelRatio ?? this.devicePixelRatio,
  );
}

/// 允许导出的设置快照；凭证只以“已配置 / 未配置”出现。
class DiagnosticsSettingsSnapshot {
  const DiagnosticsSettingsSnapshot({
    this.values = const {},
    this.credentials = const {},
    this.notes = const [],
  });

  /// 明确允许导出的非敏感值（键 → 标量 / 列表）。新增设置默认不在此表内。
  final Map<String, Object?> values;

  /// 凭证键 → 是否配置（值从不进入本对象）。
  final Map<String, bool> credentials;

  /// 读取失败 / 部分不可用等说明。
  final List<String> notes;
}

/// 一个渠道的公开能力快照（不含脚本原文）。
class DiagnosticsSourceEntry {
  const DiagnosticsSourceEntry({
    required this.key,
    required this.displayName,
    required this.kind,
    required this.enabled,
    required this.discoverable,
    required this.capabilities,
  });

  final String key;
  final String displayName;
  final String kind;
  final bool enabled;
  final bool discoverable;
  final List<String> capabilities;
}

/// 渠道 / 脚本 / any-listen 的只读快照。
class DiagnosticsSourcesSnapshot {
  const DiagnosticsSourcesSnapshot({
    this.entries = const [],
    this.activeScriptName,
    this.activeScriptVersion,
    this.activeScriptAuthor,
    this.activeScriptHomepageHost,
    this.anyListenConfigured = false,
    this.anyListenEnabled = false,
    this.anyListenHost,
    this.notes = const [],
  });

  final List<DiagnosticsSourceEntry> entries;
  final String? activeScriptName;
  final String? activeScriptVersion;
  final String? activeScriptAuthor;
  final String? activeScriptHomepageHost;
  final bool anyListenConfigured;
  final bool anyListenEnabled;
  final String? anyListenHost;
  final List<String> notes;
}

/// 数据库计数（只读；某一项失败为 null，整体仍可导出）。
class DiagnosticsDatabaseCounts {
  const DiagnosticsDatabaseCounts({
    required this.schemaVersion,
    this.counts = const {},
    this.hasSavedSession,
    this.error,
  });

  final int schemaVersion;
  final Map<String, int?> counts;
  final bool? hasSavedSession;
  final String? error;
}

/// 一个已读取的日志文件（按时间顺序由导出器排好）。
class DiagnosticsLogFile {
  const DiagnosticsLogFile({required this.name, required this.content});

  final String name;
  final String content;
}

/// 组装诊断文本所需的全部输入。
class DiagnosticsBundleData {
  const DiagnosticsBundleData({
    required this.generatedAt,
    required this.timezoneOffset,
    required this.app,
    required this.settings,
    required this.sources,
    required this.failures,
    required this.healthRuns,
    this.database,
    this.databaseNote,
    this.logs = const [],
    this.logsNote,
    this.homeDirectories = const [],
  });

  final DateTime generatedAt;
  final Duration timezoneOffset;
  final DiagnosticsAppInfo app;
  final DiagnosticsSettingsSnapshot settings;
  final DiagnosticsSourcesSnapshot sources;
  final List<DiagnosticFailureRecord> failures;
  final List<HealthRun> healthRuns;
  final DiagnosticsDatabaseCounts? database;
  final String? databaseNote;
  final List<DiagnosticsLogFile> logs;
  final String? logsNote;
  final List<String> homeDirectories;
}

/// 渲染诊断包；确定性输入除时间戳与日志内容外输出稳定。
String renderDiagnosticsBundle(
  DiagnosticsBundleData data, {
  int maxBytes = defaultDiagnosticsBundleMaxBytes,
}) {
  final app = data.app;
  final head = StringBuffer()
    ..writeln('Molia diagnostics')
    ..writeln()
    ..writeln('Generated: ${_dateTime(data.generatedAt)}')
    ..writeln('Timezone offset: ${_offset(data.timezoneOffset)}')
    ..writeln(
      'Privacy: this file was generated on this device and was not uploaded '
      'automatically. Review it before sharing.',
    )
    ..writeln();

  final sections = StringBuffer();
  _section(sections, 'App and device', [
    'app: Molia',
    'version: ${app.version}',
    'build: ${app.buildNumber}',
    'package: ${app.packageName}',
    'platform: ${app.platform}',
    'os: ${app.osVersion}',
    'abi: ${app.abi}',
    'locale: ${app.locale}',
    'build mode: ${app.buildMode}',
    'update channel: ${app.updateChannel}',
    'update auto-check: ${_yesNo(app.updateAutoCheck)}',
    if (app.screenWidth != null && app.screenHeight != null)
      'screen: ${app.screenWidth!.round()} x ${app.screenHeight!.round()}'
          '${app.devicePixelRatio == null ? '' : ' @ ${app.devicePixelRatio!.toStringAsFixed(2)}x'}',
  ]);
  sections.writeln();

  _settingsSection(sections, data.settings);
  sections.writeln();
  _sourcesSection(sections, data.sources);
  sections.writeln();
  _failuresSection(sections, data.failures);
  sections.writeln();
  _healthSection(sections, data.healthRuns);
  sections.writeln();
  _databaseSection(sections, data.database, data.databaseNote);
  sections.writeln();

  final withoutLogs = redactSecrets('$head$sections');
  final logsText = _logsSection(data.logs, data.logsNote);
  var output = '$withoutLogs$logsText';
  if (utf8.encode(output).length > maxBytes) {
    const note =
        '\n[Log section truncated: only the newest complete lines within the '
        'size cap are kept.]\n';
    final budget =
        maxBytes - utf8.encode(withoutLogs).length - utf8.encode(note).length;
    if (budget <= 0) {
      output =
          '$withoutLogs\n[Log section omitted: the size cap was already '
          'reached by earlier sections.]\n';
    } else {
      output = '$withoutLogs${_trimLogsToBudget(logsText, budget, note)}';
    }
  }
  return normalizePersonalPaths(
    redactSecrets(output),
    homeDirectories: data.homeDirectories,
  );
}

void _section(StringBuffer buffer, String title, List<String> lines) {
  buffer
    ..writeln('## $title')
    ..writeln();
  if (lines.isEmpty) {
    buffer.writeln('(unavailable)');
  } else {
    for (final line in lines) {
      buffer.writeln(line);
    }
  }
  buffer.writeln();
}

void _settingsSection(StringBuffer buffer, DiagnosticsSettingsSnapshot s) {
  buffer
    ..writeln('## Settings')
    ..writeln();
  if (s.values.isEmpty && s.credentials.isEmpty && s.notes.isEmpty) {
    buffer.writeln('(unavailable)');
  } else {
    for (final entry in s.values.entries) {
      buffer.writeln('${entry.key}: ${_valueText(entry.value)}');
    }
    for (final entry in s.credentials.entries) {
      buffer.writeln(
        '${entry.key}: ${entry.value ? 'configured' : 'not configured'}',
      );
    }
    for (final note in s.notes) {
      buffer.writeln('note: $note');
    }
  }
  buffer.writeln();
}

void _sourcesSection(StringBuffer buffer, DiagnosticsSourcesSnapshot s) {
  buffer
    ..writeln('## Sources')
    ..writeln();
  if (s.entries.isEmpty && s.notes.isEmpty && s.activeScriptName == null) {
    buffer.writeln('(unavailable)');
  } else {
    for (final entry in s.entries) {
      buffer.writeln(
        '- ${entry.enabled ? 'enabled' : 'disabled'} ${entry.key} '
        '(${entry.displayName}, ${entry.kind}) '
        'search=${_yesNo(entry.capabilities.contains('search'))} '
        'discover=${_yesNo(entry.discoverable)} '
        'resolve=${_yesNo(entry.capabilities.contains('resolve'))} '
        'lyrics=${_yesNo(entry.capabilities.contains('lyrics'))} '
        'artwork=${_yesNo(entry.capabilities.contains('artwork'))} '
        'comments=${_yesNo(entry.capabilities.contains('comments'))} '
        'collection=${_yesNo(entry.capabilities.contains('collection'))} '
        'artist=${_yesNo(entry.capabilities.contains('artist'))} '
        'lyric-search=${_yesNo(entry.capabilities.contains('lyricSearch'))}',
      );
    }
    if (s.activeScriptName != null) {
      buffer
        ..writeln('- active script: ${s.activeScriptName}')
        ..writeln('  version: ${s.activeScriptVersion ?? 'unknown'}')
        ..writeln('  author: ${s.activeScriptAuthor ?? 'unknown'}')
        ..writeln(
          '  homepage: ${s.activeScriptHomepageHost ?? 'not provided'}',
        );
    }
    buffer.writeln(
      '- any-listen: configured=${_yesNo(s.anyListenConfigured)} '
      'enabled=${_yesNo(s.anyListenEnabled)} '
      'host=${s.anyListenHost ?? 'not configured'}',
    );
    for (final note in s.notes) {
      buffer.writeln('note: $note');
    }
  }
  buffer.writeln();
}

void _failuresSection(
  StringBuffer buffer,
  List<DiagnosticFailureRecord> failures,
) {
  buffer
    ..writeln('## Recent issues')
    ..writeln();
  if (failures.isEmpty) {
    buffer.writeln('No recent issues recorded.');
  } else {
    for (final record in failures.reversed) {
      buffer.writeln(
        '- ${_dateTime(record.at)} | ${record.channelDisplayName} '
        '(${record.channelKey}) | ${record.kind.name}'
        '${record.l10nKey == null ? '' : ' | ${record.l10nKey}'}'
        '${record.retryable ? ' | retryable' : ''}',
      );
    }
  }
  buffer.writeln();
}

void _healthSection(StringBuffer buffer, List<HealthRun> runs) {
  buffer
    ..writeln('## Source health')
    ..writeln();
  if (runs.isEmpty) {
    buffer.writeln('No channel check has been run yet.');
  } else {
    for (final run in runs) {
      buffer.writeln(
        '- run ${_dateTime(run.startedAt)}'
        '${run.finishedAt == null ? '' : ' -> ${_dateTime(run.finishedAt!)}'}'
        '${run.cancelled ? ' | stopped by user' : ' | completed'}',
      );
      for (final result in run.results) {
        buffer.writeln(
          '  - ${result.channelDisplayName} (${result.channelKey}): '
          '${_stepText('search', result.search)}'
          '${result.resolve == null ? '' : '; ${_stepText('resolve', result.resolve!)}'}'
          ' | ${result.latencyMs} ms',
        );
      }
    }
  }
  buffer.writeln();
}

void _databaseSection(
  StringBuffer buffer,
  DiagnosticsDatabaseCounts? database,
  String? note,
) {
  buffer
    ..writeln('## Database')
    ..writeln();
  if (database == null) {
    buffer.writeln(note ?? '(unavailable)');
  } else {
    buffer.writeln('schema version: ${database.schemaVersion}');
    for (final entry in database.counts.entries) {
      buffer.writeln('${entry.key}: ${entry.value ?? 'unavailable'}');
    }
    buffer.writeln(
      'saved playback session: '
      '${database.hasSavedSession == null ? 'unavailable' : _yesNo(database.hasSavedSession!)}',
    );
    if (database.error != null) buffer.writeln('note: ${database.error}');
    if (note != null) buffer.writeln('note: $note');
  }
  buffer.writeln();
}

String _logsSection(List<DiagnosticsLogFile> logs, String? note) {
  final buffer = StringBuffer()
    ..writeln('## Logs')
    ..writeln();
  if (logs.isEmpty) {
    buffer.writeln(note ?? '(no retained log files)');
  } else {
    for (final file in logs) {
      buffer
        ..writeln('----- ${file.name} -----')
        ..writeln(_capLogLines(file.content));
    }
    if (note != null) buffer.writeln('note: $note');
  }
  return buffer.toString();
}

/// 旧版本日志可能留下超长行；先按行脱敏，再截断超长行，避免把密钥切成
/// 无法识别的残片。
String _capLogLines(String content, {int maxLineBytes = 64 * 1024}) {
  final buffer = StringBuffer();
  for (final line in content.split('\n')) {
    final redacted = redactSecrets(line);
    final bytes = utf8.encode(redacted);
    if (bytes.length <= maxLineBytes) {
      buffer.writeln(redacted);
    } else {
      buffer
        ..write(
          utf8.decode(bytes.sublist(0, maxLineBytes), allowMalformed: true),
        )
        ..writeln(' … [line truncated]');
    }
  }
  return buffer.toString();
}

/// 按整行保留最新的日志内容；绝不切开一行，避免截断后留下密钥残片。
String _trimLogsToBudget(String logsText, int budget, String note) {
  const heading = '## Logs\n\n';
  final content = logsText.startsWith(heading)
      ? logsText.substring(heading.length)
      : logsText;
  final available = budget - utf8.encode(heading).length;
  if (available <= 0) return '$heading$note';
  final kept = <String>[];
  var used = 0;
  final lines = content.split('\n');
  for (var index = lines.length - 1; index >= 0; index--) {
    final line = lines[index];
    final bytes = utf8.encode(line).length + 1;
    if (used + bytes > available) break;
    kept.add(line);
    used += bytes;
  }
  if (kept.isEmpty) return '$heading$note';
  return '$heading${kept.reversed.join('\n')}\n$note';
}

String _stepText(String label, HealthStepResult step) {
  final failure = step.failure;
  final detail = failure == null
      ? ''
      : ' (${failure.kind.name}'
            '${failure.l10nKey == null ? '' : ', key=${failure.l10nKey}'}'
            '${failure.retryable ? ', retryable' : ''})';
  return '$label=${step.status.name}$detail ${step.latencyMs}ms';
}

String _valueText(Object? value) {
  if (value == null) return 'not set';
  if (value is Iterable) return value.join(', ');
  return value.toString();
}

String _dateTime(DateTime value) {
  String two(int v) => v < 10 ? '0$v' : '$v';
  String three(int v) => v < 10 ? '00$v' : (v < 100 ? '0$v' : '$v');
  return '${value.year.toString().padLeft(4, '0')}-${two(value.month)}-'
      '${two(value.day)} ${two(value.hour)}:${two(value.minute)}:'
      '${two(value.second)}.${three(value.millisecond)}';
}

String _offset(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final total = offset.inMinutes.abs();
  final hours = (total ~/ 60).toString().padLeft(2, '0');
  final minutes = (total % 60).toString().padLeft(2, '0');
  return '$sign$hours:$minutes';
}

String _yesNo(bool value) => value ? 'yes' : 'no';
