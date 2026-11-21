/// 收藏事实的唯一持有者：键集合、顺序行、计数与版本。
///
/// 为什么单独一层：收藏不是「一个列表的一行」，而是跨播放页心形、收藏页、
/// 浏览索引、同步失效判定的同一个事实。键集合、列表行、列表计数此前分别
/// 由三个读投影 / 缓存补丁维护，顺序口径也不一致；这里把它们收成一个模块，
/// 写入只有一条路径，读取阶段的缓冲与重放也不再外泄给消费方。
///
/// 模块不订阅仓库变更：组合根（`LibraryProvider`）负责把 `changes` 路由进来，
/// 这样「读投影 + 写补丁」仍然只发生在收藏事实上，而资料库其它视图的失效
/// 范围不会被收藏的读状态机绑架。
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/library.dart';
import '../../domain/ports/library_store.dart';

/// 收藏事实的一帧不可变快照。
///
/// [rows] 为 null 表示收藏列表曲目还没有完整读过（只读过键）；消费方不能
/// 把 null 当成「没有收藏」。
class FavoriteSnapshot {
  FavoriteSnapshot({
    required Set<String> keys,
    required List<PlaylistTrack>? rows,
    required this.count,
    required this.revision,
  }) : keys = Set.unmodifiable(keys),
       rows = rows == null ? null : List.unmodifiable(rows);

  /// 规范收藏键（`sourceKey:songId`）。
  final Set<String> keys;

  /// 收藏列表行，按仓库口径（`sortOrder` → `addedAt`）有序；null = 未加载。
  final List<PlaylistTrack>? rows;

  /// 收藏列表展示计数（清单计数 / 已加载行 / 键集合中取最可信的一项）。
  final int count;

  /// 收藏事实版本：键集合真正变化或整表校准开始时递增。
  final int revision;

  bool contains(String sourceKey, String songId) =>
      keys.contains('$sourceKey:$songId');

  bool containsKey(String key) => keys.contains(key);
}

/// 读取期间到达的单曲切换：只保留每个 key 的最终状态。
///
/// 行要跟着一起重放：旧列表快照落地后会删掉新增行，只补键会让收藏列表
/// 少一首（键已收藏、列表里却没有）。同一 key 后到的取消会丢弃行。
typedef _PendingFavorite = ({bool favorite, PlaylistTrack? track});

/// 收藏事实。
class FavoriteFact extends ChangeNotifier {
  factory FavoriteFact({
    required LibraryStore repository,

    /// 读取超时上限（生产默认 10s；测试可注入更短的值）。
    ///
    /// 数据库连接被长时间占住时，收藏页会把「收藏列表曲目在途」当成
    /// loading；超时把挂住收敛成可重试的失败，晚到的结果不再采用。
    Duration readTimeout = const Duration(seconds: 10),
  }) => FavoriteFact._(repository, readTimeout);

  FavoriteFact._(this._repository, this._readTimeout);

  final LibraryStore _repository;
  final Duration _readTimeout;

  final Set<String> _keys = <String>{};
  List<PlaylistTrack>? _rows;
  int _count = 0;
  int _revision = 0;

  /// 默认收藏列表 id（列表清单读取后绑定）。
  int? _playlistId;

  /// 是否至少成功读到过一次整表收藏键。
  bool _keysLoaded = false;

  /// 当前 [_keys] 是否来自一次完整的仓库快照（计数校准用）。
  bool _keysAuthoritative = false;

  /// 读取代际：收藏键后发起的读取优先，旧快照不能回滚新写入。
  int _keysGeneration = 0;

  /// 行读取代际：释放缓存 / 新一轮校准让更早的行读取结果作废。
  int _rowsGeneration = 0;

  /// 收藏键在途读取数；归零时才重放读取期间的切换。
  int _keysInFlight = 0;

  final Map<String, _PendingFavorite> _pending = <String, _PendingFavorite>{};

  bool _disposed = false;

  /// 当前事实快照。
  FavoriteSnapshot get snapshot => FavoriteSnapshot(
    keys: _keys,
    rows: _rows,
    count: _count,
    revision: _revision,
  );

  /// 收藏事实版本（单调递增）。
  int get revision => _revision;

  /// 收藏列表展示计数。
  int get count => _count;

  /// 收藏列表行；null = 尚未完整读取。
  List<PlaylistTrack>? get rows => _rows;

  bool get hasRows => _rows != null;

  bool contains(String sourceKey, String songId) =>
      _keys.contains('$sourceKey:$songId');

  bool containsKey(String key) => _keys.contains(key);

  /// 绑定默认收藏列表 id。
  ///
  /// 行读取需要 id；id 变化说明旧行已不属于当前收藏列表，直接丢弃。键与
  /// 计数来自 `favoriteKeys` / 列表清单，不因 id 变化失效。
  void bindPlaylist(int? playlistId) {
    if (_playlistId == playlistId) return;
    _playlistId = playlistId;
    _rows = null;
    _rowsGeneration++;
  }

  /// 首屏 / 导入后 / 失败重试：读取整表收藏键（可等待）。
  ///
  /// 与静默校准共用同一套读取代际与在途切换重放：读取期间用户点了收藏，
  /// 旧快照落地后不会被覆盖（否则数据库已收藏，播放页心形仍是空心）。
  Future<void> ensureLoaded({bool force = false}) async {
    if (_disposed || (_keysLoaded && !force)) return;
    _revision++;
    final generation = ++_keysGeneration;
    _keysInFlight++;
    try {
      final fresh = await _repository.favoriteKeys().timeout(_readTimeout);
      if (!_acceptKeySnapshot(generation)) return;
      _replaceKeys(fresh);
      _recount();
    } catch (e) {
      debugPrint('[FavoriteFact] 读取收藏键失败: $e');
    } finally {
      _finishRead();
    }
  }

  /// 批量 / 同步 / 导入后的静默校准。
  ///
  /// [readRows] 只应在「收藏列表行本来已加载」时为 true：保持旧行可见的
  /// 同时校准，不为一次同步把整表收藏曲目读进内存。本轮开始会丢弃旧的
  /// 待重放切换——数据库已经包含那些写入，读取快照才是新基线。
  Future<void> reload({bool readRows = false}) async {
    if (_disposed) return;
    _revision++;
    final keysGeneration = ++_keysGeneration;
    final rowsGeneration = ++_rowsGeneration;
    final rowsWereLoaded = _rows != null;
    _pending.clear();
    _keysInFlight++;

    try {
      try {
        final fresh = await _repository.favoriteKeys().timeout(_readTimeout);
        if (_acceptKeySnapshot(keysGeneration)) {
          _replaceKeys(fresh);
          _recount();
        }
      } catch (e) {
        debugPrint('[FavoriteFact] 校准收藏键失败: $e');
      }

      final playlistId = _playlistId;
      if (readRows && rowsWereLoaded && playlistId != null) {
        try {
          final fresh = await _repository
              .listPlaylistTracks(playlistId)
              .timeout(_readTimeout);
          if (_acceptRowsSnapshot(rowsGeneration)) {
            _rows = List<PlaylistTrack>.of(fresh);
            _recount();
          }
        } catch (e) {
          debugPrint('[FavoriteFact] 校准收藏列表失败: $e');
        }
      }
    } finally {
      _finishRead();
    }
  }

  /// 用一次列表曲目读取的结果替换收藏行（完整快照）。
  ///
  /// 只在读取投影接受结果后调用；更新计数但不改版本（版本只表达键变化）。
  void adoptRows(List<PlaylistTrack> rows) {
    if (_disposed) return;
    _rows = List<PlaylistTrack>.of(rows);
    _recount();
    notifyListeners();
  }

  /// 释放收藏行（托盘隐藏 / 低内存 / 整表失效）。
  ///
  /// 键与计数保留：恢复后心形与收藏入口立即有依据；行在页面重新 ensure 时
  /// 再读。代际自增让释放前的在途行读取落地后作废。
  void releaseRows() {
    if (_rows == null) return;
    _rows = null;
    _rowsGeneration++;
  }

  /// 丢弃可信基线（`.lxmc` 导入等全量失效）。
  ///
  /// 键先保留（UI 不闪空），但不再被当作计数 / 去重的权威快照；随后的
  /// 校准会把真实快照读回来。
  void invalidate() {
    _keysLoaded = false;
    _keysAuthoritative = false;
    _keysGeneration++;
    _rowsGeneration++;
    _rows = null;
    _pending.clear();
    _revision++;
    notifyListeners();
  }

  /// 列表清单读到的默认收藏计数（数据库真值）。
  ///
  /// 只在没有更可信的本地依据时采用：整表收藏键 > 已加载收藏行 > 清单计数。
  /// 不在这里通知：调用方（列表清单读取）会在同一轮统一投影并通知。
  void seedCount(int count) {
    final next = _countFromBaseline(count);
    if (next != _count) _count = next;
  }

  /// 应用一次已落库的单曲切换（仓库变更事件）。
  ///
  /// 读取在途时同时记录最终状态：旧快照落地后由 [_drainPending] 幂等重放。
  /// 重复应用同一状态不会再次递增版本或通知。
  void applyChange(FavoriteToggle toggle) {
    if (_disposed) return;
    if (_keysInFlight > 0) {
      final previous = _pending[toggle.key];
      _pending[toggle.key] = (
        favorite: toggle.favorite,
        track: toggle.favorite ? (toggle.track ?? previous?.track) : null,
      );
    }
    final changed = _mutate(
      add: toggle.favorite ? [toggle.key] : const [],
      remove: toggle.favorite ? const [] : [toggle.key],
      rows: [if (toggle.favorite && toggle.track != null) toggle.track!],
    );
    if (changed) notifyListeners();
  }

  /// 收藏 / 取消收藏（唯一写入路径）。
  ///
  /// 仓库写失败向上抛，由 provider 在边界收口成可提示的结果；失败不污染
  /// 事实。仓库事件通常已在写调用栈内同步补好状态，这里的补丁是幂等的
  /// 兜底（直接使用模块、没有事件转发的调用方也得到正确状态）。
  Future<bool> toggle({
    required String sourceKey,
    required String songId,
    required String title,
    String artist = '',
    String album = '',
    String? coverUrl,
    int? durationMs,
    Map<String, dynamic> raw = const {},
  }) async {
    final favorite = await _repository.toggleFavorite(
      sourceKey: sourceKey,
      songId: songId,
      title: title,
      artist: artist,
      album: album,
      coverUrl: coverUrl,
      durationMs: durationMs,
      raw: raw,
    );
    final key = '$sourceKey:$songId';
    final changed = _mutate(
      add: favorite ? [key] : const [],
      remove: favorite ? const [] : [key],
    );
    if (changed) notifyListeners();
    return favorite;
  }

  /// 批量收藏；返回实际新增数（跳过已收藏）。
  ///
  /// 批量路径拿不到每行的落库位置，只立即补键与计数；行交给随后的整表
  /// 校准，避免先展示一份顺序错误 / 不完整的列表。
  Future<int> addAll(List<PlaylistTrack> tracks) async {
    if (tracks.isEmpty) return 0;
    final added = await _repository.addFavorites(tracks);
    if (added > 0) {
      final changed = _mutate(add: [for (final track in tracks) track.key]);
      if (changed) notifyListeners();
    }
    return added;
  }

  /// 批量取消收藏；返回实际移除数。
  Future<int> removeAll(List<TrackKey> keys) async {
    if (keys.isEmpty) return 0;
    final removed = await _repository.removeFavorites(keys);
    if (removed > 0) {
      final changed = _mutate(
        remove: [for (final key in keys) '${key.sourceKey}:${key.songId}'],
      );
      if (changed) notifyListeners();
    }
    return removed;
  }

  /// 把一次单曲切换应用到外部的有序行投影。
  ///
  /// 浏览索引持有惰性 raw 行（不能直接使用本模块的 [PlaylistTrack] 行），
  /// 但又必须与收藏列表同序；这是它复用同一份插入规则的唯一入口。
  /// 返回同一列表引用表示没有变化，调用方可以跳过重建。
  List<T> applyToggleToProjection<T extends FavoriteOrderedRow>({
    required List<T> rows,
    required FavoriteToggle toggle,
    required T Function(PlaylistTrack track) wrap,
  }) {
    if (!toggle.favorite) {
      final next = [
        for (final row in rows)
          if (row.key != toggle.key) row,
      ];
      return next.length == rows.length ? rows : next;
    }
    final track = toggle.track;
    if (track == null || rows.any((row) => row.key == toggle.key)) {
      return rows;
    }
    final row = wrap(track);
    final index = rows.indexWhere((item) => _compareRows(item, row) > 0);
    return List<T>.of(rows)..insert(index < 0 ? rows.length : index, row);
  }

  void _replaceKeys(Set<String> fresh) {
    _keys
      ..clear()
      ..addAll(fresh);
    _keysLoaded = true;
    _keysAuthoritative = true;
  }

  bool _acceptKeySnapshot(int generation) =>
      !_disposed && generation == _keysGeneration;

  bool _acceptRowsSnapshot(int generation) =>
      !_disposed && generation == _rowsGeneration;

  /// 一次读取结束：归还在途计数，最后一个读取落地后重放并只通知一次。
  void _finishRead() {
    _keysInFlight--;
    if (_disposed) return;
    _drainPending();
    _recount();
    notifyListeners();
  }

  /// 最后一个收藏键读取落地后，按到达顺序折叠并重放期间的切换。
  void _drainPending() {
    if (_keysInFlight > 0 || _pending.isEmpty) return;
    final pending = Map<String, _PendingFavorite>.of(_pending);
    _pending.clear();
    final add = <String>[];
    final remove = <String>[];
    final rows = <PlaylistTrack>[];
    for (final entry in pending.entries) {
      if (entry.value.favorite) {
        add.add(entry.key);
        final track = entry.value.track;
        if (track != null) rows.add(track);
      } else {
        remove.add(entry.key);
      }
    }
    _mutate(add: add, remove: remove, rows: rows);
  }

  /// 键 / 行 / 计数的唯一补丁（幂等）。
  ///
  /// 只有键集合真的变化才递增版本：重放同一次切换、或由事件与写入口各补
  /// 一次，都不会让按版本号失效的订阅方重复重建。
  bool _mutate({
    Iterable<String> add = const [],
    Iterable<String> remove = const [],
    Iterable<PlaylistTrack> rows = const [],
  }) {
    var changed = false;
    var addedCount = 0;
    var removedCount = 0;
    final dropped = <String>{};

    for (final key in add) {
      if (_keys.add(key)) {
        addedCount++;
        changed = true;
      }
    }
    for (final key in remove) {
      dropped.add(key);
      if (_keys.remove(key)) {
        removedCount++;
        changed = true;
      }
    }

    final currentRows = _rows;
    if (currentRows != null) {
      var next = currentRows;
      if (dropped.isNotEmpty) {
        final kept = [
          for (final row in next)
            if (!dropped.contains(row.key)) row,
        ];
        if (kept.length != next.length) {
          next = kept;
          changed = true;
        }
      }
      for (final track in rows) {
        if (next.any((row) => row.key == track.key)) continue;
        next = _insertRow(next, track);
        changed = true;
      }
      _rows = next;
    }

    if (addedCount > 0 || removedCount > 0) {
      _revision++;
      changed = true;
    }
    if (changed) _recount(delta: addedCount - removedCount);
    return changed;
  }

  List<PlaylistTrack> _insertRow(
    List<PlaylistTrack> current,
    PlaylistTrack track,
  ) {
    final index = current.indexWhere((row) => _compareRows(row, track) > 0);
    final next = List<PlaylistTrack>.of(current);
    next.insert(index < 0 ? next.length : index, track);
    return next;
  }

  /// 收藏行的仓库顺序：`sortOrder` 升序，同序按 `addedAt`。
  ///
  /// 内存里没有数据库的隐式 `id` 兜底，同序同时刻的行保持稳定插入顺序。
  static int _compareRows(FavoriteOrderedRow a, FavoriteOrderedRow b) {
    final byOrder = a.sortOrder.compareTo(b.sortOrder);
    return byOrder != 0 ? byOrder : a.addedAt.compareTo(b.addedAt);
  }

  /// 计数的唯一优先级：整表收藏键 > 已加载收藏行 > 清单计数 ± 净变化。
  ///
  /// 前两者都是权威快照，重放时不会把校准已包含的切换再算一次；只有两者
  /// 都不可用时才在现有计数上做单步增减。
  int _countFromBaseline(int baseline) {
    if (_keysAuthoritative) return _keys.length;
    final rows = _rows;
    if (rows != null) return rows.length;
    return baseline;
  }

  void _recount({int delta = 0}) {
    if (_keysAuthoritative) {
      _count = _keys.length;
    } else if (_rows != null) {
      _count = _rows!.length;
    } else if (delta != 0) {
      _count = _count + delta < 0 ? 0 : _count + delta;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pending.clear();
    super.dispose();
  }
}
