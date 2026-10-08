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
import 'dart:typed_data';

import '../sources/raw_track.dart';
import 'lxmc_decoder_models.dart';

/// 导出名称前缀（`list__name_love` → `love`）。
const String _namePrefix = 'list__name_';

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
