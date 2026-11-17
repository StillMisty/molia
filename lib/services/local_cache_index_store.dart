/// 设备本地缓存索引状态源：本机确认写完的音频缓存曲目。
///
/// 为什么单独一层：收藏页「本地歌曲」的缓存行必须只依赖「缓存确实写完」的
/// 事实，而不是播放历史。播放侧（移动端 LockCaching / 桌面预下载 / 下一首
/// 预取）通过组合根把完成事件交给本 store；历史写入、清空、删除、同步墓碑
/// 都不经过这里，因此不会影响索引与本地歌曲行。
///
/// store 持有内存索引与初始化标记，写入 / 对账 / 移除后通知收藏页；DB 持久化
/// 走窄端口 [LocalCacheIndexPersistence]，测试用假实现即可验证外部行为。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/local_cache_index.dart';
import '../domain/ports/local_cache_index.dart';
import '../sources/source_track.dart';
import 'audio_cache_store.dart';

class LocalCacheIndexStore extends ChangeNotifier {
  LocalCacheIndexStore({
    required this._persistence,
    this.maxEntries = defaultMaxEntries,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// 与播放历史可见窗口同量级：超过后按缓存完成时间倒序裁掉最旧的行。
  static const int defaultMaxEntries = 500;

  final LocalCacheIndexPersistence _persistence;
  final int maxEntries;
  final DateTime Function() _clock;

  /// 当前索引（键 = `sourceKey:songId`）。
  Map<String, LocalCacheIndexEntry> _entries = const {};

  /// 排序视图缓存：写入 / 对账 / 移除后失效。
  List<LocalCacheIndexEntry>? _sortedEntries;

  /// 初始化是否已尝试完成（成功或失败都算「已尝试」）。
  bool _initialized = false;
  Future<void>? _initFuture;

  /// 写入串行化：完成事件可能来自移动端缓存源、当前曲目写入器与下一首
  /// 预取，三个来源不能各自读改写造成丢行。
  Future<void> _writeTail = Future<void>.value();

  int _revision = 0;
  bool _disposed = false;

  /// 索引行（按缓存完成时间倒序；首次读取时生成不可变列表）。
  List<LocalCacheIndexEntry> get entries {
    final cached = _sortedEntries;
    if (cached != null) return cached;
    final sorted = _entries.values.toList()
      ..sort((a, b) {
        final byTime = b.cachedAt.compareTo(a.cachedAt);
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    return _sortedEntries = List<LocalCacheIndexEntry>.unmodifiable(sorted);
  }

  /// 初始化是否已尝试完成。false 时本地歌曲显示加载态，避免先闪空态。
  bool get initialized => _initialized;

  /// 索引内容变化计数（同键换快照也会递增；本地歌曲输入签名的失效信号）。
  int get revision => _revision;

  /// 装载持久化索引（幂等）。
  ///
  /// 读取失败按「已尝试」处理：保留内存里已有的行，不把列表清空，也不让
  /// 页面永久停在骨架；后续写入 / 对账仍可继续工作。
  Future<void> init({bool force = false}) {
    if (!force && _initFuture != null) return _initFuture!;
    _initFuture = _load();
    return _initFuture!;
  }

  Future<void> _load() async {
    try {
      final rows = await _persistence.loadAll();
      _entries = {for (final row in rows) row.key: row};
      _cutOverflow();
    } catch (e) {
      debugPrint('[LocalCacheIndex] 索引装载失败（保留内存行）: $e');
    } finally {
      _initialized = true;
      _sortedEntries = null;
      _revision++;
      _notify();
    }
  }

  /// 记录一次缓存完成（移动端边播边缓存 / 桌面当前曲目 / 下一首预取）。
  ///
  /// 调用方必须已确认最终缓存文件存在（不是 `.part` / `.predl`）；本方法只
  /// 负责幂等 upsert 与上限裁剪。重复完成按曲目键覆盖元数据与完成时间。
  Future<void> recordCompleted(SourceTrack track, {int? cachedAt}) {
    final entry = LocalCacheIndexEntry(
      sourceKey: track.sourceKey,
      songId: track.songId,
      title: track.title,
      artist: track.artist,
      album: track.album,
      coverUrl: track.coverUrl,
      durationMs: track.duration?.inMilliseconds,
      raw: Map<String, dynamic>.from(track.raw),
      cachedAt: cachedAt ?? _clock().millisecondsSinceEpoch,
    );
    return recordCompletedEntry(entry);
  }

  /// 记录一条已构造的索引行（启动对账 / 测试共用）。
  Future<void> recordCompletedEntry(LocalCacheIndexEntry entry) async {
    await init();
    await _serialize(() async {
      final next = {..._entries, entry.key: entry};
      final removed = _trimOverflow(next);
      if (identical(_entries[entry.key], entry) && removed.isEmpty) return;
      _entries = next;
      _invalidate();
      await _persist(
        upsert: [entry],
        remove: [for (final row in removed) _keyOf(row)],
      );
      _bump();
    });
  }

  /// 按键移除（用户清缓存后由缓存维护 / 测试使用；历史删除不会调用它）。
  Future<void> remove(String sourceKey, String songId) async {
    await init();
    await _serialize(() async {
      final key = '$sourceKey:$songId';
      if (!_entries.containsKey(key)) return;
      final next = {..._entries}..remove(key);
      _entries = next;
      _invalidate();
      await _persist(
        upsert: const [],
        remove: [(sourceKey: sourceKey, songId: songId)],
      );
      _bump();
    });
  }

  /// 旧缓存确认对账：只补「缓存文件确认存在」的候选，并清理已无缓存文件
  /// 的索引行。
  ///
  /// [candidates] 是播放历史提供的元数据候选（没有缓存文件的候选永远不会
  /// 被写入）；[scanCache] 返回完整音频缓存文件表，**返回 null 表示目录列举
  /// 失败**——此时完全不动索引。重复执行幂等：已经正确的行不会重复写库，
  /// 也不会重复通知。
  Future<void> reconcile({
    required Iterable<LocalCacheIndexEntry> candidates,
    required Future<Map<String, int>?> Function() scanCache,
  }) async {
    await init();
    final files = await scanCache();
    if (files == null) return;
    await _serialize(() async {
      final next = <String, LocalCacheIndexEntry>{..._entries};
      final upserts = <LocalCacheIndexEntry>[];
      for (final candidate in candidates) {
        if (_cacheFileCount(files, candidate) == 0) continue;
        if (next.containsKey(candidate.key)) continue;
        next[candidate.key] = candidate;
        upserts.add(candidate);
      }
      final removals = <LocalCacheIndexKey>[];
      for (final row in _entries.values) {
        if (_cacheFileCount(files, row) > 0) continue;
        next.remove(row.key);
        removals.add(_keyOf(row));
      }
      final overflow = _trimOverflow(next);
      for (final row in overflow) {
        removals.add(_keyOf(row));
      }
      if (upserts.isEmpty && removals.isEmpty) return;
      _entries = next;
      _invalidate();
      await _persist(upsert: upserts, remove: removals);
      _bump();
    });
  }

  /// 一条候选 / 索引行在当前完整缓存文件表里是否有命中（同曲目任意音质）。
  static int _cacheFileCount(
    Map<String, int> files,
    LocalCacheIndexEntry entry,
  ) => AudioCacheStore.usageForTrackInFiles(
    files,
    sourceKey: entry.sourceKey,
    songId: entry.songId,
  ).count;

  /// 上限裁剪：返回被裁掉的行（调用方负责从持久化删除）。
  List<LocalCacheIndexEntry> _trimOverflow(
    Map<String, LocalCacheIndexEntry> entries,
  ) {
    if (entries.length <= maxEntries) return const [];
    final sorted = entries.values.toList()
      ..sort((a, b) {
        final byTime = b.cachedAt.compareTo(a.cachedAt);
        return byTime != 0 ? byTime : b.key.compareTo(a.key);
      });
    final overflow = sorted.sublist(maxEntries);
    for (final row in overflow) {
      entries.remove(row.key);
    }
    return overflow;
  }

  void _cutOverflow() => _trimOverflow(_entries);

  Future<void> _persist({
    required List<LocalCacheIndexEntry> upsert,
    required List<LocalCacheIndexKey> remove,
  }) async {
    try {
      if (upsert.isNotEmpty) await _persistence.upsertAll(upsert);
      if (remove.isNotEmpty) await _persistence.removeAll(remove);
    } catch (e) {
      // 写库失败不让播放侧产生未捕获异步错误；内存索引仍然生效，重启后
      // 由下一次缓存完成或对账补齐。
      debugPrint('[LocalCacheIndex] 索引写入失败: $e');
    }
  }

  Future<void> _serialize(Future<void> Function() action) {
    final run = _writeTail.then((_) => action());
    _writeTail = run.catchError((Object _) {});
    return run;
  }

  LocalCacheIndexKey _keyOf(LocalCacheIndexEntry row) =>
      (sourceKey: row.sourceKey, songId: row.songId);

  void _invalidate() => _sortedEntries = null;

  void _bump() {
    _revision++;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
