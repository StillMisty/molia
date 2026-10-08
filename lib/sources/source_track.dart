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

  String get id {
    final key = rawIdOf(raw);
    return '$sourceKey:${key.isNotEmpty ? key : '$title-$artist'}';
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

String kxQualityDisplayName(String quality) {
  switch (quality) {
    case 'flac24bit':
      return 'Hi-Res';
    case 'flac':
      return '无损';
    case 'wav':
      return 'WAV';
    case 'ape':
      return 'APE';
    case '320k':
      return '320K';
    case '192k':
      return '192K';
    case '128k':
      return '128K';
    default:
      return quality;
  }
}
