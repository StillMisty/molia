/// 音源种类。
///
/// 领域层自定枚举（`lib/domain/**` 不依赖 `lib/sources/**`）；
/// 与 `source_manager.dart` 的同名枚举由 data 层适配器互相映射。
/// `local` 是本地下载副本（不参与搜索/发现/渠道排序）。
enum SourceKind { builtin, lx, anyListen, local }

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

  /// 歌手能力：歌手搜索 + 歌手详情（歌手页取数）。
  final bool artist;

  /// 按歌词搜歌（歌词片段 → 歌曲）。
  final bool lyricSearch;

  final bool favorite;
  final bool lyricsTranslation;

  /// 能按曲目取评论（热门 / 最新，分页）。
  final bool comment;

  const SourceCapabilities({
    this.search = false,
    this.pagination = false,
    this.resolveUrl = false,
    this.lyrics = false,
    this.artwork = false,
    this.collection = false,
    this.artist = false,
    this.lyricSearch = false,
    this.favorite = false,
    this.lyricsTranslation = false,
    this.comment = false,
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
      other.artist == artist &&
      other.lyricSearch == lyricSearch &&
      other.favorite == favorite &&
      other.lyricsTranslation == lyricsTranslation &&
      other.comment == comment;

  @override
  int get hashCode => Object.hash(
        search,
        pagination,
        resolveUrl,
        lyrics,
        artwork,
        collection,
        artist,
        lyricSearch,
        favorite,
        lyricsTranslation,
        comment,
      );
}

/// 音源描述：一个渠道的事实唯一形状。
///
/// 搜索页选择器 / 资料页渠道 / 音源管理页 / AI 推歌 / 自动换源都消费它，
/// 由 `SourceProfile.toDescriptor` 从画像投影一次；不再有第二套渠道结构
/// 各自复制字段。
class SourceDescriptor {
  /// 'kw' / 脚本 key / 'any_listen'。
  final String key;
  final String displayName;
  final SourceKind kind;
  final SourceCapabilities capabilities;

  /// 用户开关 / 登录态。
  final bool enabled;

  /// 是否具备内置「发现」能力（热榜 / 歌单 / 热搜：五个音乐平台 + B 站；
  /// B 站没有歌单浏览）。
  final bool discoverable;

  /// 用户排序（承接 `lx_source_order`）。
  final int order;

  const SourceDescriptor({
    required this.key,
    required this.displayName,
    required this.kind,
    this.capabilities = const SourceCapabilities(),
    this.enabled = true,
    this.discoverable = false,
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
      other.discoverable == discoverable &&
      other.order == order;

  @override
  int get hashCode => Object.hash(
        key,
        displayName,
        kind,
        capabilities,
        enabled,
        discoverable,
        order,
      );

  @override
  String toString() => 'SourceDescriptor($key)';
}
