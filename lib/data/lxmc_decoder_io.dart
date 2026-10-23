/// `.lxmc` 解码的 IO 实现（gzip + UTF-8 JSON）。
///
/// `.lxmc` 结构（LX Music 收藏夹导出）：
/// ```
/// { "type": "playListPart_v2",
///   "data": { "id": "...", "name": "list__name_love",
///             "list": [ { "id": "wy_1888818113", "name": "...", "singer": "...",
///                         "source": "wy", "interval": "04:25", "meta": {...} } ] } }
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../sources/raw_track.dart';
import 'lxmc_decoder_models.dart';

/// 导出名称前缀（`list__name_love` → `love`）。
const String _namePrefix = 'list__name_';

/// 走 worker isolate 的压缩字节阈值（64KB）。
///
/// 低于阈值的文件 gzip/JSON 解码是毫秒级，isolate 启停开销反而更贵；
/// 达到阈值（数千首的导出）才把解码与逐条映射挪出 UI isolate。
@visibleForTesting
const int lxmcDecodeIsolateThreshold = 64 * 1024;

/// 本次输入是否走 isolate（与 [decodeLxmcBytesOffThread] 共用同一判定；
/// 测试据此锁定小文件仍走同步快路径）。
@visibleForTesting
bool shouldDecodeLxmcBytesOffThread(Uint8List bytes) =>
    bytes.lengthInBytes >= lxmcDecodeIsolateThreshold;

/// 异步解码入口：大文件在 worker isolate 完成 gzip + UTF-8 + JSON + 映射，
/// 小文件仍走 [decodeLxmcBytes] 同步快路径。
///
/// 调用方是顶层函数，[Isolate.run] 的闭包只捕获 [bytes] / [fileName]，
/// 不捕获 `this` 或平台对象。异常对象不跨边界：worker 内把
/// [LxmcDecodeException] 转成可发送的结果，调用侧再重建同样的异常类型；
/// 非预期异常回传文本与远端栈，调用侧以 [StateError] 重建（保留原因）。
Future<LxmcDecodedPlaylist> decodeLxmcBytesOffThread(
  Uint8List bytes, {
  String? fileName,
}) async {
  if (!shouldDecodeLxmcBytesOffThread(bytes)) {
    return decodeLxmcBytes(bytes, fileName: fileName);
  }

  final outcome = await Isolate.run(
    () => _decodeLxmcInIsolate(bytes, fileName),
    debugName: 'molia-lxmc-decode',
  );
  return switch (outcome) {
    _LxmcDecodeSuccess(:final playlist) => playlist,
    _LxmcDecodeFailure(:final reason) => throw LxmcDecodeException(reason),
    _LxmcDecodeCrash(:final error, :final stack) => Error.throwWithStackTrace(
        StateError('lxmc 解码失败：$error'),
        StackTrace.fromString(stack),
      ),
  };
}

/// worker 主函数：只做纯 CPU 解码，返回可发送的结果（不含异常对象）。
_LxmcDecodeOutcome _decodeLxmcInIsolate(Uint8List bytes, String? fileName) {
  try {
    return _LxmcDecodeSuccess(decodeLxmcBytes(bytes, fileName: fileName));
  } on LxmcDecodeException catch (e) {
    return _LxmcDecodeFailure(e.reason);
  } catch (e, stack) {
    return _LxmcDecodeCrash('$e', '$stack');
  }
}

/// isolate 回传结果：全部字段可发送。
sealed class _LxmcDecodeOutcome {
  const _LxmcDecodeOutcome();
}

final class _LxmcDecodeSuccess extends _LxmcDecodeOutcome {
  const _LxmcDecodeSuccess(this.playlist);

  final LxmcDecodedPlaylist playlist;
}

final class _LxmcDecodeFailure extends _LxmcDecodeOutcome {
  const _LxmcDecodeFailure(this.reason);

  final String reason;
}

final class _LxmcDecodeCrash extends _LxmcDecodeOutcome {
  const _LxmcDecodeCrash(this.error, this.stack);

  final String error;
  final String stack;
}

LxmcDecodedPlaylist decodeLxmcBytes(Uint8List bytes, {String? fileName}) {
  final List<int> decompressed;
  try {
    decompressed = gzip.decode(bytes);
  } catch (_) {
    throw const LxmcDecodeException('not_gzip');
  }

  final dynamic root;
  try {
    root = jsonDecode(utf8.decode(decompressed));
  } catch (_) {
    throw const LxmcDecodeException('invalid_json');
  }

  if (root is! Map || root['type'] != 'playListPart_v2') {
    throw const LxmcDecodeException('not_play_list');
  }
  final data = root['data'];
  if (data is! Map || data['list'] is! List) {
    throw const LxmcDecodeException('not_play_list');
  }

  final name = _cleanName(data['name'], fileName: fileName);
  final tracks = <LxmcDecodedTrack>[];
  var skipped = 0;
  for (final item in data['list'] as List) {
    final track = _mapTrack(item);
    if (track == null) {
      skipped++;
      continue;
    }
    tracks.add(track);
  }
  return LxmcDecodedPlaylist(name: name, tracks: tracks, skipped: skipped);
}

/// 清洗导出名：剥掉 `list__name_` 前缀；为空时退回文件名（去扩展名）。
String _cleanName(Object? raw, {String? fileName}) {
  var name = raw?.toString().trim() ?? '';
  if (name.startsWith(_namePrefix)) {
    name = name.substring(_namePrefix.length).trim();
  }
  if (name.isNotEmpty) return name;

  if (fileName != null && fileName.isNotEmpty) {
    var base = fileName.replaceAll('\\', '/').split('/').last.trim();
    final lower = base.toLowerCase();
    if (lower.endsWith('.lxmc')) {
      base = base.substring(0, base.length - 5);
    }
    if (base.startsWith('lx_list_part_')) {
      base = base.substring('lx_list_part_'.length);
    }
    base = base.trim();
    if (base.isNotEmpty) return base;
  }
  return 'LX Music';
}

/// 单条 `list` 条目 → [LxmcDecodedTrack]；非法（缺 source/标题/平台 id）返回 null。
LxmcDecodedTrack? _mapTrack(dynamic item) {
  if (item is! Map) return null;

  final sourceKey = item['source']?.toString().trim().toLowerCase() ?? '';
  if (sourceKey.isEmpty) return null;

  final metaRaw = item['meta'];
  final meta = <String, dynamic>{};
  if (metaRaw is Map) {
    metaRaw.forEach((key, value) => meta[key.toString()] = value);
  }

  final title = (item['name'] ?? meta['name'] ?? '').toString().trim();
  if (title.isEmpty) return null;

  final songId = _platformSongId(sourceKey, meta, item['id']);
  if (songId.isEmpty) return null;

  final artist =
      (item['singer'] ?? meta['singer'] ?? meta['artist'] ?? '').toString();
  final album =
      (meta['albumName'] ?? meta['album'] ?? item['albumName'] ?? '')
          .toString();
  final cover =
      (meta['picUrl'] ?? meta['img'] ?? meta['pic'] ?? item['pic'] ?? '')
          .toString();

  return LxmcDecodedTrack(
    sourceKey: sourceKey,
    songId: songId,
    title: title,
    artist: artist,
    album: album,
    coverUrl: cover.isEmpty ? null : cover,
    durationMs: _durationMs(item['interval'] ?? meta['interval']),
    // raw = meta 原样（含 qualitys / _qualitys），供播放时按需取链。
    raw: meta,
  );
}

/// 平台取链 id：优先 `meta` 中该平台字段（[platformRawIdOf]），
/// 兜底解析 `item.id` 的平台前缀。
String _platformSongId(
    String sourceKey, Map<String, dynamic> meta, Object? itemId) {
  final fromMeta = platformRawIdOf(sourceKey, meta);
  if (fromMeta.isNotEmpty) return fromMeta;
  final id = itemId?.toString().trim() ?? '';
  if (id.isEmpty) return '';
  final prefix = '${sourceKey}_';
  if (id.startsWith(prefix)) return id.substring(prefix.length);
  final underscore = id.indexOf('_');
  return underscore >= 0 ? id.substring(underscore + 1) : id;
}

/// `"04:25"` / `"1:02:03"` / 秒数 → 毫秒；无法解析返回 null。
int? _durationMs(Object? interval) {
  if (interval is num) {
    return (interval * 1000).round();
  }
  if (interval is! String) return null;
  final text = interval.trim();
  if (text.isEmpty) return null;
  final parts = text.split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var seconds = 0.0;
  for (final part in parts) {
    final value = double.tryParse(part.trim());
    if (value == null) return null;
    seconds = seconds * 60 + value;
  }
  return (seconds * 1000).round();
}
