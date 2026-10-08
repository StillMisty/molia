import 'equality.dart';

/// 曲目来源（本项目只有本地后端）。
enum TrackOrigin { builtin, lx, anyListen, localFile }

/// 曲目唯一标识：`sourceKey`（kw / kg / 脚本 key / any_listen）+ 平台内 id。
///
/// `uri` 与旧 `SourceTrack.id` 的 `'$sourceKey:$id'` 约定保持一致，
/// 阶段 1–3 的兼容层与持久化数据（历史记录里的 `sourceKey:id`）无需迁移。
class TrackId {
  /// 音源 key：内置平台（kw/kg/tx/wy/mg）、脚本自定义 key 或 any_listen。
  final String sourceKey;

  /// 平台内唯一 id（raw 中的 songmid/hash/songId/id/mid...）。
  final String id;

  const TrackId(this.sourceKey, this.id);

  String get uri => '$sourceKey:$id';

  @override
  bool operator ==(Object other) =>
      other is TrackId && other.sourceKey == sourceKey && other.id == id;

  @override
  int get hashCode => Object.hash(sourceKey, id);

  @override
  String toString() => uri;
}

/// 艺术家（最简形态：内置/脚本搜索大多只有一个整串名称）。
class Artist {
  final String name;
  final String? id;

  const Artist({required this.name, this.id});

  @override
  bool operator ==(Object other) =>
      other is Artist && other.name == name && other.id == id;

  @override
  int get hashCode => Object.hash(name, id);

  @override
  String toString() => name;
}

/// 封面：主图 + 尺寸降级链（避免 UI 到处取 images[0]/images[1]）。
class Artwork {
  final Uri uri;
  final List<Uri> fallbacks;

  const Artwork({required this.uri, this.fallbacks = const []});

  @override
  bool operator ==(Object other) =>
      other is Artwork &&
      other.uri == uri &&
      deepEquals(other.fallbacks, fallbacks);

  @override
  int get hashCode => Object.hash(uri, deepHash(fallbacks));

  @override
  String toString() => uri.toString();
}

/// 音质条目（type 如 128k/320k/flac，size 展示用，hash 供部分平台取链）。
class AudioQuality {
  final String type;
  final String? size;
  final String? hash;

  const AudioQuality({required this.type, this.size, this.hash});

  @override
  bool operator ==(Object other) =>
      other is AudioQuality &&
      other.type == type &&
      other.size == size &&
      other.hash == hash;

  @override
  int get hashCode => Object.hash(type, size, hash);

  @override
  String toString() => type;
}

/// 领域层统一曲目模型（不可变）。
///
/// 约定：
/// - [payload] 语义等价于旧 `SourceTrack.raw`，承载原音源数据；
///   **必须原样回传给脚本 `musicUrl / lyric / pic`（不得改写、不得重建）**，
///   UI 与 providers 禁止读取该字段（见 docs/architecture.md §2.1/§5）。
/// - 所有字段不可变；相等性按值比较（payload 深比较 + 引用短路），
///   供 `Selector` / 快照去重可靠使用。
class Track {
  final TrackId id;
  final String title;
  final List<Artist> artists;
  final String? album;
  final Duration? duration;
  final Artwork? artwork;
  final TrackOrigin origin;
  final List<AudioQuality> qualities;

  /// 原音源数据（旧 `SourceTrack.raw`）：只在 data 层与音源引擎之间传递。
  /// 必须原样回传，UI 禁读。
  final Map<String, Object?> payload;

  const Track({
    required this.id,
    required this.title,
    this.artists = const [],
    this.album,
    this.duration,
    this.artwork,
    required this.origin,
    this.qualities = const [],
    this.payload = const {},
  });

  /// 常规 copyWith（注意：无法把可空字段显式置回 null，领域内暂不需要该用法）。
  Track copyWith({
    TrackId? id,
    String? title,
    List<Artist>? artists,
    String? album,
    Duration? duration,
    Artwork? artwork,
    TrackOrigin? origin,
    List<AudioQuality>? qualities,
    Map<String, Object?>? payload,
  }) {
    return Track(
      id: id ?? this.id,
      title: title ?? this.title,
      artists: artists ?? this.artists,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      artwork: artwork ?? this.artwork,
      origin: origin ?? this.origin,
      qualities: qualities ?? this.qualities,
      payload: payload ?? this.payload,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Track &&
      other.id == id &&
      other.title == title &&
      deepEquals(other.artists, artists) &&
      other.album == album &&
      other.duration == duration &&
      other.artwork == artwork &&
      other.origin == origin &&
      deepEquals(other.qualities, qualities) &&
      deepEquals(other.payload, payload);

  @override
  int get hashCode => Object.hash(
        id,
        title,
        deepHash(artists),
        album,
        duration,
        artwork,
        origin,
        deepHash(qualities),
        deepHash(payload),
      );

  @override
  String toString() => 'Track($id, $title)';
}
