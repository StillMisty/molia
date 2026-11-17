/// 本地歌曲伪合集的数据状态机。
///
/// 为什么单独一层：本地歌曲行是「下载 / 导入记录 + 设备本地缓存索引里命中
/// 完整音频缓存的曲目」的联结，并受索引键 / 下载记录键 / 记录 revision /
/// 缓存 revision 共同驱动。播放历史完全不参与：历史清空 / 删除 / 同步墓碑
/// 不会让缓存行消失。页面只该消费行与加载态，不该在 build 里重算联结、
/// 输入签名与过期结果；缓存目录列举失败也只影响缓存行，不影响下载 / 导入行。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/download.dart';
import '../domain/models/library.dart';
import '../domain/models/local_cache_index.dart';
import '../domain/models/track.dart';

/// 缓存索引读取端口：页面注入 `TrackLocalDataService.cachedAudioTrackIds`。
///
/// 用函数而不是具体服务：合集只关心「这批曲目里哪些命中完整音频缓存」，
/// 单元测试直接给假实现，不需要构造真实缓存目录。
typedef CachedAudioTrackIdsLookup = Future<Set<TrackId>> Function(
  List<Track> tracks,
);

/// 一轮本地歌曲合集的输入快照。
///
/// 列表字段都是只读视图：索引行 / 下载记录由各自状态源持有，这里只在同一个
/// build 帧内读取一次，避免异步期间读到半新半旧的状态；签名只需要键，缓存
/// 行判定时才真正转成领域曲目。
class LocalSongsInput {
  const LocalSongsInput({
    required this.indexEntries,
    required this.indexInitialized,
    required this.downloads,
    required this.supported,
    required this.initialized,
    required this.recordsRevision,
    required this.cacheRevision,
    this.indexRevision = 0,
  });

  /// 设备本地缓存索引（缓存真正写完的曲目快照，缓存完成时间倒序）。
  final List<LocalCacheIndexEntry> indexEntries;

  /// 索引是否已装载；首次进入合集时未装载显示加载态，避免空态闪烁。
  final bool indexInitialized;

  /// 下载记录（含导入项；能力不可用时仍可带旧快照，供签名稳定）。
  final List<DownloadedTrack> downloads;

  /// 下载能力是否可用；false 时本地歌曲合集不出现任何行。
  final bool supported;

  /// 下载记录是否已加载；未加载完成时合集显示加载态，避免空态闪烁。
  final bool initialized;

  /// 下载记录 revision（记录替换 / 删除 / 初始化 / 能力变化时递增）。
  ///
  /// 记录键相同也可能换了快照（标题 / 路径 / 分项），revision 是「是否重算
  /// 缓存行」的失效信号；它不参与展示。
  final int recordsRevision;

  /// 音频缓存 revision（清缓存 / LRU 淘汰后递增）。
  final int cacheRevision;

  /// 缓存索引 revision（同键换快照 / 新增 / 移除时递增）。
  final int indexRevision;

  /// 重算签名 = 索引键 + 下载记录键 + 记录 revision + 索引 revision +
  /// 缓存 revision。
  ///
  /// 顺序敏感：同一批键换了元数据快照也值得重算；签名相同则零等待复用上一
  /// 轮结果。播放历史不在签名里——它已经和本地歌曲解耦。
  int get signature => Object.hash(
    Object.hashAll([for (final entry in indexEntries) entry.key]),
    Object.hashAll([for (final record in downloads) record.key]),
    recordsRevision,
    indexRevision,
    cacheRevision,
  );
}

/// 本地歌曲合集：拥有联结、下载优先去重、输入签名、加载令牌与加载态。
///
/// 页面在浏览本地歌曲合集时每帧调用 [sync]；签名没变时立即返回（或在途
/// 加载的 Future），签名变了才发起一次缓存目录列举。异步结果落地前会比对
/// 令牌，输入已经变过的旧结果直接丢弃——不能把旧索引算出的缓存行盖到新
/// 输入上。
class LocalSongsCollection extends ChangeNotifier {
  LocalSongsCollection({required this._loadCachedAudioTrackIds});

  final CachedAudioTrackIdsLookup _loadCachedAudioTrackIds;

  LocalSongsInput? _input;
  List<CollectionLocalSong> _cachedRows = const [];

  /// [rows] 的缓存：输入签名、索引 / 下载列表身份与缓存行身份都没变时复用
  /// 同一个列表。presenter 按源列表引用缓存视图，每次 build 新分配行列表会
  /// 让本地歌曲视图永远命中不了缓存、选择集每帧全量重扫。
  List<CollectionLocalSong>? _rows;
  int? _rowsSignature;
  List<DownloadedTrack>? _rowsDownloads;
  List<LocalCacheIndexEntry>? _rowsIndexEntries;
  List<CollectionLocalSong>? _rowsCachedRows;

  /// [rows] 被替换的次数（测试 / 诊断信号；内容变化才递增）。
  int _rowsRevision = 0;

  /// 最近一次请求的输入签名（null = 还没同步过）。
  int? _signature;

  /// 最近一次真正落定的缓存行对应的签名；能力不可用时保持 null，
  /// 这样能力恢复后即使输入签名没变也会补一轮缓存列举。
  int? _loadedSignature;

  /// 缓存索引列举在途（只描述异步那一半，是否显示加载态见 [loading]）。
  bool _indexLoading = false;

  /// 过期结果丢弃令牌：每次签名变化 / 能力关闭 / dispose 都递增。
  int _token = 0;

  /// 同一签名下复用在途加载（合集弹层计数要等它落定，不能读半旧状态）。
  Future<void>? _inFlight;

  /// 当前可见行：下载 / 导入记录在前，缓存行在后；同一曲目下载优先。
  ///
  /// 缓存行来自上一轮落定结果（新输入加载期间旧缓存行保持可见，避免列表
  /// 整段闪空）；下载记录始终取当前输入，删除下载后立即消失。
  ///
  /// 输入没变时返回上一份列表本身：presenter 按源列表引用判断视图是否可
  /// 复用，行为算出的新列表会让本地歌曲视图每帧重新投影、选择集每帧重扫。
  /// 失效条件：输入签名（索引键 / 下载键 / 记录 revision / 索引 revision /
  /// 缓存 revision）、索引与下载列表身份（同键换快照不改 revision 的情况）、
  /// 缓存行列表身份（异步列举落定）。
  List<CollectionLocalSong> get rows {
    final input = _input;
    if (input == null || !input.supported) return const [];
    final signature = input.signature;
    final cached = _rows;
    if (cached != null &&
        _rowsSignature == signature &&
        identical(_rowsDownloads, input.downloads) &&
        identical(_rowsIndexEntries, input.indexEntries) &&
        identical(_rowsCachedRows, _cachedRows)) {
      return cached;
    }
    final downloadKeys = {for (final record in input.downloads) record.key};
    final rows = [
      for (final record in input.downloads)
        CollectionLocalSong.download(record),
      for (final row in _cachedRows)
        if (!downloadKeys.contains(row.key)) row,
    ];
    _rows = rows;
    _rowsSignature = signature;
    _rowsDownloads = input.downloads;
    _rowsIndexEntries = input.indexEntries;
    _rowsCachedRows = _cachedRows;
    _rowsRevision++;
    return rows;
  }

  /// [rows] 被替换的次数（内容变化才递增；测试 / 诊断用）。
  int get rowsRevision => _rowsRevision;

  /// 弹层计数与列表行数同源（下载 / 导入 + 缓存行，去重后）。
  int get count => rows.length;

  /// 是否显示加载态。
  ///
  /// - 下载记录 / 缓存索引还没装载完成：始终加载（列表内容还不完整）；
  /// - 已有下载行时不再因为缓存索引在途而整页 loading（删除下载后刚进入
  ///   合集不该闪一下空白，与页面原判定一致）；
  /// - 没有可见行且缓存索引在途：加载，避免先闪「还没有本地歌曲」。
  bool get loading {
    final input = _input;
    if (input == null) return false;
    if (!input.supported) return false;
    if (!input.initialized || !input.indexInitialized) return true;
    // 行是否为空等价于「没有下载记录且没有缓存行」：有下载行时不论缓存
    // 索引是否在途都直接显示列表，避免整页 loading 闪动。
    return _indexLoading && input.downloads.isEmpty && _cachedRows.isEmpty;
  }

  /// 与 [input] 对齐；签名相同且无在途加载时立即完成。
  ///
  /// 返回的 Future 在本轮落定后完成（弹层计数 await 它）；签名相同但上一轮
  /// 仍在途时返回同一个 Future，避免并发列举。
  Future<void> sync(LocalSongsInput input) {
    // 下载记录即使签名不变也可能替换了同一键的记录快照（标题 / 路径），
    // 始终更新输入；行 getter 会按新输入重新组装。
    _input = input;
    final signature = input.signature;
    if (!input.supported) {
      // 能力不可用：没有可等待的工作，缓存行也不该出现；递增令牌让旧一轮
      // 结果在落地时被丢弃。`_loadedSignature` 保持 null（而不是记成当前
      // 签名），这样能力恢复后即使输入签名没变也会补一轮缓存列举。
      _signature = signature;
      _token++;
      _inFlight = null;
      _indexLoading = false;
      _cachedRows = const [];
      _loadedSignature = null;
      // 能力恢复后必须重新组装行（不能把关闭期间的缓存当成当前内容）。
      _rows = null;
      return Future<void>.value();
    }
    if (_signature == signature && _loadedSignature == signature) {
      return _inFlight ?? Future<void>.value();
    }
    if (_signature == signature) {
      // 同一输入的一轮仍在途：复用它，不能并发列举。
      final inFlight = _inFlight;
      if (inFlight != null) return inFlight;
    }
    _signature = signature;
    _indexLoading = true;
    final token = ++_token;
    final load = _load(input, signature, token);
    _inFlight = load;
    return load.whenComplete(() {
      if (identical(_inFlight, load)) _inFlight = null;
    });
  }

  Future<void> _load(LocalSongsInput input, int signature, int token) async {
    var cached = const <CollectionLocalSong>[];
    try {
      final entries = input.indexEntries;
      if (entries.isNotEmpty) {
        final tracks = [
          for (final entry in entries)
            Track(
              id: TrackId(entry.sourceKey, entry.songId),
              title: entry.title,
              origin: TrackOrigin.builtin,
              payload: entry.raw,
            ),
        ];
        final cachedIds = await _loadCachedAudioTrackIds(tracks);
        final downloadKeys = {for (final record in input.downloads) record.key};
        final seen = <String>{};
        cached = [
          for (var i = 0; i < entries.length && i < tracks.length; i++)
            if (cachedIds.contains(tracks[i].id) &&
                !downloadKeys.contains(entries[i].key) &&
                seen.add(entries[i].key))
              CollectionLocalSong.cached(entries[i]),
        ];
      }
    } catch (_) {
      // 列举失败按无缓存行呈现（不影响下载 / 导入行；索引本身仍在 store 里，
      // 下一次通知 / 重算会再次尝试）。
      cached = const [];
    }
    if (token != _token) return; // 输入已变：丢弃过期结果
    _cachedRows = cached;
    _loadedSignature = signature;
    _indexLoading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    // 让在途结果失效：完成回调不能再读写已释放的状态。
    _token++;
    _inFlight = null;
    super.dispose();
  }
}

/// 本地歌曲行：下载 / 导入副本，或缓存索引命中完整音频缓存的曲目。
///
/// 缓存行保留原曲身份（`sourceKey` / `songId` / `raw`），播放走正常解析
/// （命中缓存即 `file://` 离线播放）；删除是「清缓存」，不动下载记录。
///
/// 行形状由本模块定义：它是合集的领域联合，渲染层不持有。
class CollectionLocalSong {
  const CollectionLocalSong.download(this.record) : cached = null;

  const CollectionLocalSong.cached(this.cached) : record = null;

  final DownloadedTrack? record;
  final LocalCacheIndexEntry? cached;

  /// 是否缓存行（无下载 / 导入记录）。
  bool get isCached => record == null;

  /// 是否本地导入（就地引用）。
  bool get isImported => record?.imported ?? false;

  /// 确认文件不见（仅下载 / 导入行）。
  bool get isMissing => record?.isMissing ?? false;

  /// 稳定行 key。
  String get key => record?.key ?? cached!.key;

  String get title => record?.title ?? cached!.title;

  String get artist => record?.artist ?? cached!.artist;

  /// 专辑名：下载 / 导入副本取记录快照，缓存行取索引快照。
  String get album => record?.album ?? cached!.album;

  int? get durationMs =>
      record != null ? record!.durationMs : cached!.durationMs;

  /// 行封面地址：下载副本优先本地封面文件，缓存行用索引里的原图地址。
  String? get artworkUri {
    final record = this.record;
    if (record != null) return record.artworkUri?.toString();
    return cached!.coverUrl;
  }

  /// 播放 / 收藏用的曲目快照（下载副本 = local 源；缓存行 = 原曲）。
  PlaylistTrack toPlaylistTrack({required int addedAt}) => record != null
      ? record!.toPlaylistTrack(addedAt: addedAt)
      : cached!.toPlaylistTrack(addedAt: addedAt);

  /// 收藏键（下载副本 = local 音源；缓存行 = 原曲键）。
  ({String sourceKey, String songId}) get favoriteKey => record != null
      ? (sourceKey: kLocalSourceKey, songId: record!.localSongId)
      : (sourceKey: cached!.sourceKey, songId: cached!.songId);
}
