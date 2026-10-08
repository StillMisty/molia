/// 音源种类。
///
/// 本文件自定枚举（阶段 0 不触碰 `lib/sources/**`）；
/// 阶段 2 与 `source_manager.dart` 的 `SourceKind` 迁移对齐。
enum SourceKind { builtin, lx, anyListen }

/// 音源能力位：UI 依据能力显隐控件，禁止散落 `if (isLocalPlayback)` 判断。
class SourceCapabilities {
  final bool search;

  /// search 返回的 hasMore/total 是否可信。
  final bool pagination;

  /// 能产生本地可播流。
  final bool resolveUrl;
  final bool lyrics;
  final bool artwork;

  /// 专辑/歌单/艺人详情。
  final bool collection;
  final bool favorite;
  final bool lyricsTranslation;

  const SourceCapabilities({
    this.search = false,
    this.pagination = false,
    this.resolveUrl = false,
    this.lyrics = false,
    this.artwork = false,
    this.collection = false,
    this.favorite = false,
    this.lyricsTranslation = false,
  });

  @override
  bool operator ==(Object other) =>
      other is SourceCapabilities &&
      other.search == search &&
      other.pagination == pagination &&
      other.resolveUrl == resolveUrl &&
      other.lyrics == lyrics &&
      other.artwork == artwork &&
      other.collection == collection &&
      other.favorite == favorite &&
      other.lyricsTranslation == lyricsTranslation;

  @override
  int get hashCode => Object.hash(
        search,
        pagination,
        resolveUrl,
        lyrics,
        artwork,
        collection,
        favorite,
        lyricsTranslation,
      );
}

/// 音源描述（搜索页选择器 / 音源管理页消费）。
class SourceDescriptor {
  /// 'kw' / 脚本 key / 'any_listen'。
  final String key;
  final String displayName;
  final SourceKind kind;
  final SourceCapabilities capabilities;

  /// 用户开关 / 登录态。
  final bool enabled;

  /// 用户排序（承接 `lx_source_order`）。
  final int order;

  const SourceDescriptor({
    required this.key,
    required this.displayName,
    required this.kind,
    this.capabilities = const SourceCapabilities(),
    this.enabled = true,
    this.order = 0,
  });

  @override
  bool operator ==(Object other) =>
      other is SourceDescriptor &&
      other.key == key &&
      other.displayName == displayName &&
      other.kind == kind &&
      other.capabilities == capabilities &&
      other.enabled == enabled &&
      other.order == order;

  @override
  int get hashCode =>
      Object.hash(key, displayName, kind, capabilities, enabled, order);

  @override
  String toString() => 'SourceDescriptor($key)';
}
