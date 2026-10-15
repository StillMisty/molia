import 'raw_track.dart';

export 'raw_track.dart' show SourceQuality;

/// 统一的音乐源曲目模型。
///
/// `raw` 用于在调用音源脚本 `musicUrl / lyric / pic` 时原样回传
/// （LX 脚本依赖 musicInfo 中的平台字段，如 songmid / hash / copyrightId）。
class SourceTrack {
  /// 平台 key：kw / kg / tx / wy / mg 或脚本自定义 key。
  final String sourceKey;

  /// 数据来源：builtin（内置平台搜索）或 lx（脚本扩展搜索）。
  final String origin;

  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final Duration? duration;
  final List<SourceQuality> qualities;
  final Map<String, dynamic> raw;

  const SourceTrack({
    required this.sourceKey,
    required this.origin,
    required this.title,
    required this.artist,
    required this.album,
    this.coverUrl,
    this.duration,
    this.qualities = const [],
    required this.raw,
  });

  /// 平台内歌曲 id：raw 取键优先级 → 兜底 `标题-歌手`。
  ///
  /// 与领域 `TrackId.id`（`trackFromSourceTrack`）**同源**：缓存 key /
  /// 下载记录 / 播放历史都按这个 id 对齐；[id] 只是它的全局唯一包装。
  /// 两者必须成对看：这里少写一层包装，缓存文件名就会与所有读取路径错开。
  String get songId {
    final key = rawIdOf(raw);
    return key.isNotEmpty ? key : '$title-$artist';
  }

  /// 全局唯一标识 `{sourceKey}:{songId}`（队列 / 播放会话 / 媒体会话用）。
  String get id => '$sourceKey:$songId';

  /// 仅用于音源补图等原地更新：raw / 音质列表保持同一引用，
  /// 脚本 `musicUrl / lyric / pic` 回传数据不受影响。
  SourceTrack copyWith({String? coverUrl}) {
    return SourceTrack(
      sourceKey: sourceKey,
      origin: origin,
      title: title,
      artist: artist,
      album: album,
      coverUrl: coverUrl ?? this.coverUrl,
      duration: duration,
      qualities: qualities,
      raw: raw,
    );
  }

  /// 选择请求音质：优先 preferred，其次按 LX 质量顺序回退，最后取支持列表末位。
  String pickQuality(String preferred) => pickQualityFor(
        qualities.map((q) => q.type).where((t) => t.isNotEmpty),
        preferred,
      );

  Map<String, dynamic> toJson() => {
        'sourceKey': sourceKey,
        'origin': origin,
        'title': title,
        'artist': artist,
        'album': album,
        'coverUrl': coverUrl,
        'durationMs': duration?.inMilliseconds,
        'qualities': qualities.map((q) => q.toJson()).toList(),
        'raw': raw,
      };

  factory SourceTrack.fromJson(Map<String, dynamic> json) {
    final durationMs = json['durationMs'];
    return SourceTrack(
      sourceKey: json['sourceKey'] as String? ?? '',
      origin: json['origin'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String? ?? '',
      coverUrl: json['coverUrl'] as String?,
      duration: durationMs is int && durationMs > 0
          ? Duration(milliseconds: durationMs)
          : null,
      qualities: ((json['qualities'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => SourceQuality.fromJson(
                e.map((k, v) => MapEntry(k.toString(), v)),
              ))
          .toList(),
      raw: (json['raw'] as Map?)?.map((k, v) => MapEntry(k.toString(), v)) ??
          const {},
    );
  }
}

/// LX 音质从高到低的顺序（与 lx-music 保持一致）。
const List<String> kLxQualityOrder = [
  'flac24bit',
  'flac',
  'wav',
  'ape',
  '320k',
  '192k',
  '128k',
];

/// 纯函数版音质选择（[SourceTrack.pickQuality] 与其共享同一实现）：
/// 优先 preferred，其次按 [kLxQualityOrder] 先降后升回退，最后取支持列表末位。
String pickQualityFor(Iterable<String> supportedTypes, String preferred) {
  final supported = supportedTypes.toList();
  if (supported.isEmpty) return preferred;
  if (supported.contains(preferred)) return preferred;
  final startIndex = kLxQualityOrder.indexOf(preferred);
  if (startIndex >= 0) {
    for (var i = startIndex + 1; i < kLxQualityOrder.length; i++) {
      if (supported.contains(kLxQualityOrder[i])) return kLxQualityOrder[i];
    }
    for (var i = startIndex - 1; i >= 0; i--) {
      if (supported.contains(kLxQualityOrder[i])) return kLxQualityOrder[i];
    }
  }
  return supported.last;
}

/// 音质上限：把 [preferred] 压到不高于 [cap]（[kLxQualityOrder] 中索引
/// 越大音质越低）。
///
/// 省流模式使用：偏好无损时上限 128k → 取 128k；偏好本就低于上限 → 保持。
/// [cap] 不在音质表内时不限制；[preferred] 为非标准音质时直接按上限。
String capQualityFor(String preferred, String cap) {
  final capIndex = kLxQualityOrder.indexOf(cap);
  if (capIndex < 0) return preferred;
  final preferredIndex = kLxQualityOrder.indexOf(preferred);
  if (preferredIndex < 0) return cap;
  return preferredIndex < capIndex ? cap : preferred;
}