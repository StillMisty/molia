/// 只改标题的音频标签编辑器（MP3 ID3v2.3 / v2.4、FLAC Vorbis Comment）。
///
/// 与下载标签写入（`audio_tag_writer.dart`）分开：那个入口会在下载完成后
/// **重建**整份标签，适合新下载文件的快照；用户改标题必须保留封面 / 歌词 /
/// 其它帧的原始字节与顺序，只能替换 `TIT2` / Vorbis `TITLE`。
///
/// 写入方式：临时文件（新标签前缀 + 原音频流式拷贝）→ 同目录原子改名；
/// 失败清理临时文件，原文件一字节不变。只把标签头 / 帧头读进内存，音频帧
/// 始终走流。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'download_storage.dart';

final _logger = Logger('molia.audio_title_editor');

/// 一次标题写入的结果（UI 只按这些分支提示，不展示技术原因）。
enum TagWriteOutcome {
  /// 已写入文件。
  written,

  /// 格式 / 标签结构无法安全重建，原文件未动。
  unsupported,

  /// 文件不存在（UI 直接提供「只在 Molia 中修改」）。
  fileMissing,

  /// 读 / 写失败，原文件未动。
  failed,
}

/// 标题校验：去首尾空白；空 / 含换行 / 超 200 个码点返回 null。
String? normalizeTitleText(String raw) {
  final title = raw.trim();
  if (title.isEmpty) return null;
  if (title.contains('\n') || title.contains('\r')) return null;
  if (title.runes.length > 200) return null;
  return title;
}

/// 只替换标题标签；其余字节（帧 / 元数据块 / 音频）保持原样。
Future<TagWriteOutcome> rewriteAudioTitle({
  required DownloadStorage storage,
  required String filePath,
  required String title,
}) async {
  final normalized = normalizeTitleText(title);
  if (normalized == null) return TagWriteOutcome.unsupported;
  final extension = p.extension(filePath).toLowerCase();
  if (extension != '.mp3' && extension != '.flac') {
    return TagWriteOutcome.unsupported;
  }
  final exists = await storage.fileExists(filePath);
  if (!exists) return TagWriteOutcome.fileMissing;

  final tempPath = '$filePath.molia-title.tmp';
  try {
    final prepared = switch (extension) {
      '.mp3' => await _prepareMp3(storage, filePath, normalized),
      '.flac' => await _prepareFlac(storage, filePath, normalized),
      _ => null,
    };
    if (prepared == null) return TagWriteOutcome.unsupported;
    if (prepared.audioStart < 0) return TagWriteOutcome.unsupported;
    final audio = await storage.readStream(
      filePath,
      start: prepared.audioStart,
    );
    await storage.writeStream(tempPath, _prepend(prepared.prefix, audio));
    await _preservePermissions(filePath, tempPath);
    await storage.rename(tempPath, filePath);
    return TagWriteOutcome.written;
  } catch (e) {
    _logger.warning('标题标签写入失败（原文件保持不变）：$e');
    await storage.deleteQuietly(tempPath);
    return TagWriteOutcome.failed;
  }
}

Future<void> _preservePermissions(String source, String target) async {
  // 尽力而为：桌面保留原权限位；失败按当前用户默认权限创建，不阻断编辑。
  try {
    final mode = File(source).statSync().mode;
    await Process.run('chmod', [mode.toRadixString(8), target]);
  } catch (_) {}
}

Stream<List<int>> _prepend(Uint8List prefix, Stream<List<int>> rest) async* {
  if (prefix.isNotEmpty) yield prefix;
  yield* rest;
}

typedef _Prepared = ({Uint8List prefix, int audioStart});

// ---------------------------------------------------------------------------
// MP3 / ID3v2
// ---------------------------------------------------------------------------

Future<_Prepared?> _prepareMp3(
  DownloadStorage storage,
  String filePath,
  String title,
) async {
  final head = await storage.readHead(filePath, 10);
  if (head == null || head.isEmpty) return null;
  final hasTag =
      head.length >= 10 &&
      head[0] == 0x49 &&
      head[1] == 0x44 &&
      head[2] == 0x33;
  if (!hasTag) {
    // 没有标签：新写一个只含 TIT2 的 v2.3 标签，音频字节不动。
    return (
      prefix: _buildId3Tag(version: 3, frames: const [], title: title),
      audioStart: 0,
    );
  }
  final version = head[3];
  if (version != 3 && version != 4) return null; // v2.2 / 未知版本
  final flags = head[5];
  // unsynchronisation / extended header / experimental / footer：结构无法
  // 安全重排（或需要重算 CRC），交给 app-only。
  if (flags & 0xF0 != 0) return null;
  final tagSize = _synchsafe(head, 6);
  // 标签声明长度可能超过 512KB（大封面）：按声明长度单独读取帧区。
  final frameBytes = await storage.readRange(filePath, 10, tagSize);
  if (frameBytes == null) return null;

  final frames = <Uint8List>[];
  var offset = 0;
  while (offset + 10 <= frameBytes.length) {
    final idBytes = frameBytes.sublist(offset, offset + 4);
    if (idBytes.every((byte) => byte == 0)) break; // 进入 padding
    final id = String.fromCharCodes(idBytes);
    if (!_isFrameId(id)) return null;
    final size = version == 4
        ? _synchsafe(frameBytes, offset + 4)
        : (frameBytes[offset + 4] << 24) |
              (frameBytes[offset + 5] << 16) |
              (frameBytes[offset + 6] << 8) |
              frameBytes[offset + 7];
    if (size < 0 || offset + 10 + size > frameBytes.length) return null;
    // 格式标志（压缩 / 加密 / 分组 / 数据长度）意味着帧体有额外结构，
    // 原样保留也无法保证标题帧位置正确 —— 不支持。
    final formatFlags = version == 4
        ? frameBytes[offset + 9] & 0x0F
        : frameBytes[offset + 9] & 0xE0;
    if (formatFlags != 0) return null;
    final frame = Uint8List.sublistView(frameBytes, offset, offset + 10 + size);
    if (id != 'TIT2') frames.add(frame);
    offset += 10 + size;
  }
  return (
    prefix: _buildId3Tag(version: version, frames: frames, title: title),
    audioStart: 10 + tagSize,
  );
}

bool _isFrameId(String id) => id.codeUnits.every(
  (unit) =>
      unit == 0x20 ||
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5A),
);

Uint8List _buildId3Tag({
  required int version,
  required List<Uint8List> frames,
  required String title,
}) {
  final titleFrame = _buildTitleFrame(version, title);
  final body = BytesBuilder(copy: false);
  for (final frame in frames) {
    body.add(frame);
  }
  body.add(titleFrame);
  final payload = body.takeBytes();
  final header = Uint8List(10);
  header[0] = 0x49;
  header[1] = 0x44;
  header[2] = 0x33;
  header[3] = version;
  header[4] = 0; // revision
  header[5] = 0; // flags
  final size = payload.length;
  header[6] = (size >> 21) & 0x7F;
  header[7] = (size >> 14) & 0x7F;
  header[8] = (size >> 7) & 0x7F;
  header[9] = size & 0x7F;
  final result = Uint8List(10 + payload.length);
  result.setRange(0, 10, header);
  result.setRange(10, result.length, payload);
  return result;
}

Uint8List _buildTitleFrame(int version, String title) {
  final Uint8List text;
  if (version == 4) {
    // v2.4：UTF-8 + 编码字节 0x03。
    text = Uint8List.fromList([0x03, ...utf8.encode(title)]);
  } else {
    // v2.3：UTF-16（BOM + LE code units），编码字节 0x01。
    final units = title.codeUnits;
    final bytes = <int>[0x01, 0xFF, 0xFE];
    for (final unit in units) {
      bytes
        ..add(unit & 0xFF)
        ..add((unit >> 8) & 0xFF);
    }
    text = Uint8List.fromList(bytes);
  }
  final header = Uint8List(10);
  header.setRange(0, 4, 'TIT2'.codeUnits);
  final size = text.length;
  if (version == 4) {
    header[4] = (size >> 21) & 0x7F;
    header[5] = (size >> 14) & 0x7F;
    header[6] = (size >> 7) & 0x7F;
    header[7] = size & 0x7F;
  } else {
    header[4] = (size >> 24) & 0xFF;
    header[5] = (size >> 16) & 0xFF;
    header[6] = (size >> 8) & 0xFF;
    header[7] = size & 0xFF;
  }
  final result = Uint8List(10 + text.length);
  result.setRange(0, 10, header);
  result.setRange(10, result.length, text);
  return result;
}

int _synchsafe(List<int> bytes, int offset) =>
    ((bytes[offset] & 0x7F) << 21) |
    ((bytes[offset + 1] & 0x7F) << 14) |
    ((bytes[offset + 2] & 0x7F) << 7) |
    (bytes[offset + 3] & 0x7F);

// ---------------------------------------------------------------------------
// FLAC
// ---------------------------------------------------------------------------

typedef _FlacBlock = ({int type, Uint8List data});

Future<_Prepared?> _prepareFlac(
  DownloadStorage storage,
  String filePath,
  String title,
) async {
  final magic = await storage.readHead(filePath, 4);
  if (magic == null || magic.length < 4) return null;
  if (magic[0] != 0x66 ||
      magic[1] != 0x4C ||
      magic[2] != 0x61 ||
      magic[3] != 0x43) {
    return null;
  }
  final blocks = <_FlacBlock>[];
  var offset = 4;
  var last = false;
  while (!last) {
    final header = await storage.readRange(filePath, offset, 4);
    if (header == null || header.length < 4) return null;
    last = header[0] & 0x80 != 0;
    final type = header[0] & 0x7F;
    if (type == 127) return null;
    final length = (header[1] << 16) | (header[2] << 8) | header[3];
    offset += 4;
    if (length < 0) return null;
    final data = length == 0
        ? Uint8List(0)
        : await storage.readRange(filePath, offset, length);
    if (data == null || data.length != length) return null;
    blocks.add((type: type, data: data));
    offset += length;
    if (blocks.length > 1024) return null; // 防御损坏文件
  }
  final audioStart = offset;

  final commentIndex = blocks.indexWhere((block) => block.type == 4);
  if (commentIndex < 0) {
    // 没有 Vorbis Comment：在 STREAMINFO 之后插入只含 TITLE 的块。
    blocks.insert(1, (type: 4, data: _buildVorbisComment(null, title)));
  } else {
    final rewritten = _rewriteVorbisComment(blocks[commentIndex].data, title);
    if (rewritten == null) return null;
    blocks[commentIndex] = (type: 4, data: rewritten);
  }

  final builder = BytesBuilder(copy: false);
  builder.add(const [0x66, 0x4C, 0x61, 0x43]);
  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    final length = block.data.length;
    if (length > 0xFFFFFF) return null;
    builder.add([
      (i == blocks.length - 1 ? 0x80 : 0x00) | block.type,
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
    ]);
    builder.add(block.data);
  }
  return (prefix: builder.takeBytes(), audioStart: audioStart);
}

/// 只改 TITLE 键：保留 vendor、其它键、重复 ARTIST 与顺序。
///
/// 解析失败 / 结构异常返回 null（app-only）。
Uint8List? _rewriteVorbisComment(Uint8List data, String title) {
  try {
    var offset = 0;
    int readUint32() {
      final value =
          data[offset] |
          (data[offset + 1] << 8) |
          (data[offset + 2] << 16) |
          (data[offset + 3] << 24);
      offset += 4;
      return value;
    }

    if (data.length < 8) return null;
    final vendorLength = readUint32();
    if (vendorLength < 0 || offset + vendorLength + 4 > data.length) {
      return null;
    }
    final vendor = data.sublist(offset, offset + vendorLength);
    offset += vendorLength;
    final count = readUint32();
    if (count < 0 || count > 100000) return null;
    final entries = <String>[];
    var titleSeen = false;
    for (var i = 0; i < count; i++) {
      final length = readUint32();
      if (length < 0 || offset + length > data.length) return null;
      final raw = utf8.decode(
        data.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      final equals = raw.indexOf('=');
      final key = equals < 0 ? raw : raw.substring(0, equals);
      if (key.toUpperCase() == 'TITLE') {
        if (titleSeen) continue; // 多个 TITLE：收敛成一个
        titleSeen = true;
        entries.add('TITLE=$title');
      } else {
        entries.add(raw);
      }
    }
    if (!titleSeen) entries.add('TITLE=$title');
    return _buildVorbisComment((vendor: vendor, entries: entries), null);
  } catch (_) {
    return null;
  }
}

Uint8List _buildVorbisComment(
  ({Uint8List vendor, List<String> entries})? existing,
  String? title,
) {
  final vendor = existing?.vendor ?? utf8.encode('Molia');
  final entries = <List<int>>[
    for (final entry in existing?.entries ?? const <String>[])
      utf8.encode(entry),
    if (title != null) utf8.encode('TITLE=$title'),
  ];
  final builder = BytesBuilder(copy: false);
  void uint32(int value) {
    builder.add([
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ]);
  }

  uint32(vendor.length);
  builder.add(vendor);
  uint32(entries.length);
  for (final entry in entries) {
    uint32(entry.length);
    builder.add(entry);
  }
  return builder.takeBytes();
}

/// 仅用于调试 / 测试断言：读取当前标题（不解析整文件）。
@visibleForTesting
String? debugReadTitle(Uint8List bytes, {required String extension}) {
  try {
    if (extension == '.mp3') {
      if (bytes.length < 10 || bytes[0] != 0x49) return null;
      final version = bytes[3];
      final tagSize = _synchsafe(bytes, 6);
      final end = math.min(10 + tagSize, bytes.length);
      var offset = 10;
      while (offset + 10 <= end) {
        final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
        if (id.codeUnits.every((unit) => unit == 0)) break;
        final size = version == 4
            ? _synchsafe(bytes, offset + 4)
            : (bytes[offset + 4] << 24) |
                  (bytes[offset + 5] << 16) |
                  (bytes[offset + 6] << 8) |
                  bytes[offset + 7];
        if (id == 'TIT2' && offset + 10 + size <= end) {
          final encoding = bytes[offset + 10];
          final body = bytes.sublist(offset + 11, offset + 10 + size);
          if (encoding == 3) return utf8.decode(body, allowMalformed: true);
          if (encoding == 1) {
            final text = body.length >= 2 && body[0] == 0xFF && body[1] == 0xFE
                ? body.sublist(2)
                : body;
            final units = <int>[];
            for (var i = 0; i + 1 < text.length; i += 2) {
              units.add(text[i] | (text[i + 1] << 8));
            }
            return String.fromCharCodes(units);
          }
          return latin1.decode(body, allowInvalid: true);
        }
        offset += 10 + size;
      }
      return null;
    }
    if (extension == '.flac') {
      if (bytes.length < 8) return null;
      var offset = 4;
      var last = false;
      while (!last && offset + 4 <= bytes.length) {
        last = bytes[offset] & 0x80 != 0;
        final type = bytes[offset] & 0x7F;
        final length =
            (bytes[offset + 1] << 16) |
            (bytes[offset + 2] << 8) |
            bytes[offset + 3];
        offset += 4;
        if (offset + length > bytes.length) return null;
        if (type == 4) {
          final comment = bytes.sublist(offset, offset + length);
          var cursor = 0;
          int readUint32() {
            final value =
                comment[cursor] |
                (comment[cursor + 1] << 8) |
                (comment[cursor + 2] << 16) |
                (comment[cursor + 3] << 24);
            cursor += 4;
            return value;
          }

          if (comment.length < 8) return null;
          final vendorLength = readUint32();
          cursor += vendorLength;
          final count = readUint32();
          for (var i = 0; i < count; i++) {
            final entryLength = readUint32();
            final entry = utf8.decode(
              comment.sublist(cursor, cursor + entryLength),
              allowMalformed: true,
            );
            cursor += entryLength;
            if (entry.toUpperCase().startsWith('TITLE=')) {
              return entry.substring(6);
            }
          }
          return null;
        }
        offset += length;
      }
      return null;
    }
    return null;
  } catch (_) {
    return null;
  }
}
