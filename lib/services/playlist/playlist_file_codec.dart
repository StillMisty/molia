/// 播放列表文件编解码（M3U / M3U8 / PLS）：纯 Dart，无 IO、无 Flutter。
///
/// 解析只产出「条目 + 问题」：坏行、坏条目不会抛异常，也不会被静默丢掉；
/// 是否存在 / 是否可导入由导入流水线判断。相对路径按 [parsePlaylistFile]
/// 的 `baseDirectory` 解析成绝对路径，Windows 盘符不会被误认成 URL scheme。
library;

import 'dart:convert';

import 'package:path/path.dart' as p;

/// 支持的播放列表文件格式。
enum PlaylistFileFormat { m3u, m3u8, pls }

/// 从扩展名推断格式；未知返回 null。
PlaylistFileFormat? playlistFormatForFileName(String fileName) {
  final extension = p.extension(fileName).toLowerCase();
  return switch (extension) {
    '.m3u' => PlaylistFileFormat.m3u,
    '.m3u8' => PlaylistFileFormat.m3u8,
    '.pls' => PlaylistFileFormat.pls,
    _ => null,
  };
}

/// 位置种类（解析后）。
enum PlaylistLocationKind {
  /// 本机绝对路径（含 `file://` 与相对路径解析结果）。
  localPath,

  /// 在线地址（http / https 或其它未知 scheme；导入时不抓取）。
  onlineUrl,

  /// `molia://track/<base64url>` 回退地址。
  moliaUri,
}

/// 一个可解析的播放列表条目。
class PlaylistFileEntry {
  const PlaylistFileEntry({
    required this.location,
    required this.kind,
    this.moliaKey,
    this.title = '',
    this.artist = '',
    this.durationMs,
    this.line = 0,
  });

  /// 解析后的位置：绝对路径 / URL / `molia://` 地址。
  final String location;

  final PlaylistLocationKind kind;

  /// `#MOLIA` 曲目键（`sourceKey:songId`；songId 是首个冒号之后全部内容）。
  final String? moliaKey;

  final String title;
  final String artist;
  final int? durationMs;

  /// 源文件行号（1 起；PLS 为 0）。
  final int line;

  /// 展示名：标题优先，其次文件名 / 位置。
  String get displayName {
    if (title.trim().isNotEmpty) return title.trim();
    if (kind == PlaylistLocationKind.localPath) {
      final base = p.basename(location);
      return base.isEmpty ? location : base;
    }
    return moliaKey ?? location;
  }
}

/// 解析问题种类（UI 映射本地化文案，不直接展示原始异常）。
enum PlaylistFileProblemKind {
  malformedEntry,
  malformedLine,
  unsupportedFormat,
}

/// 一条无法解析的条目 / 行。
class PlaylistFileProblem {
  const PlaylistFileProblem({
    required this.kind,
    required this.line,
    required this.text,
    this.reason = '',
  });

  final PlaylistFileProblemKind kind;
  final int line;
  final String text;

  /// 内部原因（只进日志 / 测试，不直接展示）。
  final String reason;
}

/// 解析结果。
class PlaylistFileParseResult {
  const PlaylistFileParseResult({
    required this.format,
    required this.entries,
    required this.problems,
    this.name,
  });

  final PlaylistFileFormat format;

  /// `#PLAYLIST` / PLS 文件里没有显式名称时为 null（由调用方回退到文件名）。
  final String? name;

  final List<PlaylistFileEntry> entries;
  final List<PlaylistFileProblem> problems;

  bool get hasEntries => entries.isNotEmpty;
}

/// 解析 M3U / M3U8 / PLS 文本。
///
/// [format] 为空时按 [fileName] 推断；[baseDirectory] 用于解析相对路径
/// （通常是播放列表文件所在目录）。
PlaylistFileParseResult parsePlaylistFile(
  String text, {
  required String fileName,
  String? baseDirectory,
  PlaylistFileFormat? format,
}) {
  final resolvedFormat =
      format ?? playlistFormatForFileName(fileName) ?? PlaylistFileFormat.m3u8;
  final normalized = _stripBom(text)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  return resolvedFormat == PlaylistFileFormat.pls
      ? _parsePls(normalized, baseDirectory: baseDirectory)
      : _parseM3u(normalized, resolvedFormat, baseDirectory: baseDirectory);
}

// ---------------------------------------------------------------------------
// 序列化

/// 一个导出条目（位置与曲目键由导出构建器决定）。
class PlaylistExportEntry {
  const PlaylistExportEntry({
    required this.title,
    required this.artist,
    required this.location,
    this.durationMs,
    this.moliaKey,
  });

  final String title;
  final String artist;
  final String location;
  final int? durationMs;

  /// `sourceKey:songId`；null = 不写 `#MOLIA`。
  final String? moliaKey;
}

/// 生成 M3U8 文本：UTF-8、`\n` 行尾、`#EXTM3U` 开头。
String encodeM3u8Playlist({
  required String name,
  required List<PlaylistExportEntry> entries,
}) {
  final buffer = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#PLAYLIST:${sanitizePlaylistText(name)}');
  for (final entry in entries) {
    final seconds = entry.durationMs == null
        ? -1
        : (entry.durationMs! / 1000).round();
    final artist = sanitizePlaylistText(entry.artist).trim();
    final title = sanitizePlaylistText(entry.title).trim();
    final label = artist.isEmpty
        ? title
        : (title.isEmpty ? artist : '$artist - $title');
    buffer.writeln('#EXTINF:$seconds,$label');
    final key = entry.moliaKey;
    if (key != null && key.trim().isNotEmpty) {
      buffer.writeln('#MOLIA:${sanitizePlaylistText(key).trim()}');
    }
    buffer.writeln(sanitizePlaylistText(entry.location).trim());
  }
  return buffer.toString();
}

/// 去掉换行 / 控制字符：单个条目不能把文件结构撑坏。
String sanitizePlaylistText(String value) => value
    .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'), '')
    .replaceAll('\r', ' ')
    .replaceAll('\n', ' ');

/// 构造 `molia://track/<base64url>` 回退地址。
String moliaTrackUri(String moliaKey) =>
    'molia://track/${base64Url.encode(utf8.encode(moliaKey))}';

/// 解析 `molia://track/<base64url>`；非法返回 null。
String? parseMoliaTrackUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'molia' || uri.host != 'track') return null;
  final encoded = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  if (encoded.isEmpty) return null;
  try {
    return utf8.decode(base64Url.decode(encoded));
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// M3U / M3U8

PlaylistFileParseResult _parseM3u(
  String text,
  PlaylistFileFormat format, {
  String? baseDirectory,
}) {
  String? name;
  String? pendingKey;
  String? pendingTitle;
  String? pendingArtist;
  int? pendingDuration;
  var pendingLine = 0;
  var pendingStarted = false;
  final entries = <PlaylistFileEntry>[];
  final problems = <PlaylistFileProblem>[];

  void resetPending() {
    pendingKey = null;
    pendingTitle = null;
    pendingArtist = null;
    pendingDuration = null;
    pendingLine = 0;
    pendingStarted = false;
  }

  void flushPending(int line) {
    // 只有 #EXTINF / #MOLIA 而后面没有位置行：这是一条不完整条目。
    if (!pendingStarted) return;
    problems.add(
      PlaylistFileProblem(
        kind: PlaylistFileProblemKind.malformedEntry,
        line: pendingLine == 0 ? line : pendingLine,
        text: pendingTitle ?? pendingKey ?? '',
        reason: '缺少位置行',
      ),
    );
    resetPending();
  }

  final lines = text.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final raw = lines[index].trim();
    if (raw.isEmpty) continue;
    if (raw.startsWith('#')) {
      final upper = raw.toUpperCase();
      if (upper.startsWith('#EXTM3U')) {
        continue;
      }
      if (upper.startsWith('#PLAYLIST:')) {
        name = raw.substring(raw.indexOf(':') + 1).trim();
        continue;
      }
      if (upper.startsWith('#EXTINF:')) {
        // 新 EXTINF 出现时，上一条没有位置行 → 报告后丢弃，不吞掉。
        flushPending(lineNumber);
        pendingStarted = true;
        pendingLine = lineNumber;
        final payload = raw.substring(raw.indexOf(':') + 1);
        final comma = payload.indexOf(',');
        final secondsText = (comma < 0 ? payload : payload.substring(0, comma))
            .trim();
        final seconds = int.tryParse(secondsText);
        pendingDuration = seconds == null || seconds <= 0
            ? null
            : seconds * 1000;
        final label = comma < 0 ? '' : payload.substring(comma + 1).trim();
        if (label.isNotEmpty) {
          final separator = label.indexOf(' - ');
          if (separator > 0) {
            pendingArtist = label.substring(0, separator).trim();
            pendingTitle = label.substring(separator + 3).trim();
          } else {
            pendingTitle = label;
          }
        }
        continue;
      }
      if (upper.startsWith('#MOLIA:')) {
        pendingStarted = true;
        if (pendingLine == 0) pendingLine = lineNumber;
        final key = raw.substring(raw.indexOf(':') + 1).trim();
        if (key.isEmpty || !key.contains(':')) {
          problems.add(
            PlaylistFileProblem(
              kind: PlaylistFileProblemKind.malformedLine,
              line: lineNumber,
              text: raw,
              reason: 'Molia 曲目键格式不正确',
            ),
          );
        } else {
          pendingKey = key;
        }
        continue;
      }
      // 其它注释 / 扩展指令忽略。
      continue;
    }

    final kind = _classifyLocation(raw, baseDirectory: baseDirectory);
    entries.add(
      PlaylistFileEntry(
        location: kind.location,
        kind: kind.kind,
        moliaKey: pendingKey,
        title: pendingTitle ?? '',
        artist: pendingArtist ?? '',
        durationMs: pendingDuration,
        line: lineNumber,
      ),
    );
    resetPending();
  }
  flushPending(lines.length);

  return PlaylistFileParseResult(
    format: format,
    name: name,
    entries: entries,
    problems: problems,
  );
}

// ---------------------------------------------------------------------------
// PLS

PlaylistFileParseResult _parsePls(String text, {String? baseDirectory}) {
  String? name;
  final byIndex = <int, _PlsDraft>{};
  final problems = <PlaylistFileProblem>[];
  final lines = text.split('\n');

  for (var index = 0; index < lines.length; index++) {
    final lineNumber = index + 1;
    final raw = lines[index].trim();
    if (raw.isEmpty || raw.startsWith(';')) continue;
    final equals = raw.indexOf('=');
    if (equals <= 0) {
      problems.add(
        PlaylistFileProblem(
          kind: PlaylistFileProblemKind.malformedLine,
          line: lineNumber,
          text: raw,
          reason: '缺少键值分隔符',
        ),
      );
      continue;
    }
    final key = raw.substring(0, equals).trim();
    final value = raw.substring(equals + 1).trim();
    final upper = key.toUpperCase();
    if (upper == 'PLAYLISTNAME' || upper == 'TITLE') {
      name ??= value;
      continue;
    }
    final match = RegExp(r'^(FILE|TITLE|LENGTH|MOLIA)(\d+)$').firstMatch(upper);
    if (match == null) continue;
    final number = int.tryParse(match.group(2)!);
    if (number == null || number < 0) continue;
    final draft = byIndex.putIfAbsent(number, _PlsDraft.new);
    switch (match.group(1)!) {
      case 'FILE':
        draft.location = value;
        draft.line = lineNumber;
      case 'TITLE':
        draft.title = value;
      case 'LENGTH':
        final seconds = int.tryParse(value);
        draft.durationMs = seconds == null || seconds <= 0
            ? null
            : seconds * 1000;
      case 'MOLIA':
        draft.moliaKey = value.isEmpty ? null : value;
    }
  }

  final numbers = byIndex.keys.toList()..sort();
  final entries = <PlaylistFileEntry>[];
  for (final number in numbers) {
    final draft = byIndex[number]!;
    final location = draft.location;
    if (location == null || location.isEmpty) {
      problems.add(
        PlaylistFileProblem(
          kind: PlaylistFileProblemKind.malformedEntry,
          line: draft.line,
          text: draft.title ?? 'File$number',
          reason: '缺少文件地址',
        ),
      );
      continue;
    }
    final kind = _classifyLocation(location, baseDirectory: baseDirectory);
    final title = draft.title ?? '';
    entries.add(
      PlaylistFileEntry(
        location: kind.location,
        kind: kind.kind,
        moliaKey: draft.moliaKey,
        title: title,
        // PLS 没有独立的歌手字段：标题按 `Artist - Title` 约定再拆一次。
        artist: _artistFromPlsTitle(title),
        durationMs: draft.durationMs,
      ),
    );
  }
  return PlaylistFileParseResult(
    format: PlaylistFileFormat.pls,
    name: name,
    entries: entries,
    problems: problems,
  );
}

class _PlsDraft {
  String? location;
  String? title;
  int? durationMs;
  String? moliaKey;
  int line = 0;
}

String _artistFromPlsTitle(String title) {
  final separator = title.indexOf(' - ');
  return separator > 0 ? title.substring(0, separator).trim() : '';
}

// ---------------------------------------------------------------------------
// 位置分类

({String location, PlaylistLocationKind kind}) _classifyLocation(
  String raw, {
  String? baseDirectory,
}) {
  final molia = parseMoliaTrackUri(raw);
  if (molia != null) {
    return (location: molia, kind: PlaylistLocationKind.moliaUri);
  }
  final uri = Uri.tryParse(raw);
  if (uri != null && uri.scheme == 'file') {
    return (
      location: p.normalize(uri.toFilePath()),
      kind: PlaylistLocationKind.localPath,
    );
  }
  if (_isWindowsDrivePath(raw)) {
    return (location: p.normalize(raw), kind: PlaylistLocationKind.localPath);
  }
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return (location: raw, kind: PlaylistLocationKind.onlineUrl);
  }
  if (uri != null && uri.scheme.isNotEmpty && uri.scheme.length > 1) {
    // 未知 scheme（插件地址等）：不抓取，交给导入流水线报告。
    return (location: raw, kind: PlaylistLocationKind.onlineUrl);
  }
  if (p.isAbsolute(raw)) {
    return (location: p.normalize(raw), kind: PlaylistLocationKind.localPath);
  }
  final directory = baseDirectory;
  final resolved = directory == null || directory.isEmpty
      ? p.normalize(raw)
      : p.normalize(p.join(directory, raw));
  return (location: resolved, kind: PlaylistLocationKind.localPath);
}

bool _isWindowsDrivePath(String value) =>
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);

String _stripBom(String text) =>
    text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF ? text.substring(1) : text;
