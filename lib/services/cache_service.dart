import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_cache_store.dart';
import 'cache_storage.dart';
import 'lyrics_cache.dart';

export 'cache_storage.dart'
    show
        CacheDeleteResult,
        CachePartition,
        CacheUsage,
        audioCacheMimeSuffix,
        audioCachePartSuffix,
        audioCachePredownloadSuffix;

/// 统一缓存门面：音频 / 歌词 / 封面三个分区的策略、统计与清理。
///
/// 设计要点：
/// - **不依赖 provider**：策略读写都直接走本服务；`main.dart` 以单例
///   [instance] 注册为 Provider 供 UI 使用；
/// - **策略持久化**（SharedPreferences，键名固定）：所有 getter 每次从
///   prefs 读取，setter 写入后立即触发对应动作，因此**无需重启**：
///   - 音频开关：播放时读取；
///   - 音频上限：setter 立即执行 [enforceAudioLimit]；
///   - 歌词 TTL：取词时读取；
///   - 封面上限/过期：setter 通知监听者（`ArtworkCache`）立即 sweep；
/// - **平台文件操作**走 [CacheStorage]（`dart:io` 只在实现层），策略逻辑与
///   文件系统解耦；
/// - **音频缓存磁盘约定**（文件名 / 完整判据 / 索引 / 命中 / 清扫）
///   唯一实现在 [AudioCacheStore]：本服务只做策略与通知，避免写入侧与读取侧
///   再次分叉（见 ADR-0008）；
/// - **歌词缓存**：默认实例是 prefs-only；生产组合根启动时经
///   [attachLyricsCache] 接入文件后端，取词与缓存页统计共享同一实例。
class CacheService {
  CacheService({
    SharedPreferences? prefs,
    CacheStorage? storage,
    LyricsCache? lyricsCache,
    Duration audioProtectAge = const Duration(minutes: 10),
  })  : _prefs = prefs,
        _storage = storage ?? createPlatformCacheStorage(),
        _lyricsCache = lyricsCache ?? LyricsCache(prefs: prefs),
        _audioProtectAge = audioProtectAge {
    _audioStore = AudioCacheStore(storage: _storage);
  }

  /// 全局单例（main.dart 注册前的默认入口）。
  static final CacheService instance = CacheService();

  /// 由组合根接入生产歌词缓存（文件后端）。
  ///
  /// [instance] 在静态初始化时创建，此时还没有 `path_provider` / 文件系统
  /// 上下文，因此默认实例保持 prefs-only。组合根在启动早期用
  /// `LyricsCache.appSupport()` 替换，让取词与缓存页统计共享同一实例。
  /// 不要在运行期反复替换（会丢掉已持有的引用）。
  void attachLyricsCache(LyricsCache cache) {
    _lyricsCache = cache;
  }

  /// 缓存内容版本号：写入 / 清理 / 淘汰后递增，供「占用展示」跨页刷新。
  ///
  /// 值本身无意义，只表示「缓存变了」；消费方用 [ValueListenableBuilder] 或
  /// 监听后重算占用（歌曲信息页 / 单曲缓存子页）。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 通知缓存内容已变化（微任务里递增）。
  ///
  /// 调用点可能位于图片加载完成回调或构建期附近，同步通知会触发
  /// 「构建期 setState」断言；占用展示晚一帧无感知。
  void notifyCacheChanged() {
    scheduleMicrotask(() => revision.value++);
  }

  // 策略键名（固定，设置 UI / 测试共用）
  static const String keyAudioEnabled = 'cache_audio_enabled';
  static const String keyAudioMaxMb = 'cache_audio_max_mb';
  static const String keyLyricsTtlDays = 'cache_lyrics_ttl_days';
  static const String keyArtworkMaxObjects = 'cache_artwork_max_objects';
  static const String keyArtworkStaleDays = 'cache_artwork_stale_days';

  static const bool defaultAudioEnabled = true;

  /// 容量不可知（设备容量通道不可用 / 查询失败）时的音频上限回退值（MB）。
  static const int defaultAudioMaxMb = 1024;

  /// 建议上限 = 设备总容量 ÷ 该除数（128GB 设备 ≈ 1GB）。
  static const int audioMaxStorageDivisor = 128;

  /// 建议上限的下限（MB）：小容量设备也保留可用缓存。
  static const int audioMaxSuggestionFloorMb = 256;

  static const int defaultLyricsTtlDays = 30;
  static const int defaultArtworkMaxObjects = 1500;
  static const int defaultArtworkStaleDays = 365;

  /// 歌词缓存键前缀（与 [LyricsCache.keyPrefix] 同一约定）。
  static const String lyricsCacheKeyPrefix = LyricsCache.keyPrefix;

  static const int _mbBytes = 1024 * 1024;

  final CacheStorage _storage;
  LyricsCache _lyricsCache;
  final Duration _audioProtectAge;
  late final AudioCacheStore _audioStore;
  SharedPreferences? _prefs;
  final Logger _logger = Logger('molia.cache_service');

  /// 音频缓存目录约定（命名 / 完整性 / 索引 / 命中 / 清扫）的唯一实现。
  AudioCacheStore get audioStore => _audioStore;

  final List<void Function(CachePartition)> _policyListeners = [];
  final List<void Function(CachePartition)> _clearListeners = [];

  /// 是否启用音频边播边缓存（默认 true）。
  Future<bool> audioEnabled() async =>
      (await _readBool(keyAudioEnabled)) ?? defaultAudioEnabled;

  Future<void> setAudioEnabled(bool value) async {
    await _write(keyAudioEnabled, value);
    _notify(CachePartition.audio);
    notifyCacheChanged();
  }

  /// 音频缓存上限（MB，0 = 不限制）。
  ///
  /// 缺键时按 [suggestedAudioMaxMb]（设备总容量 ÷ [audioMaxStorageDivisor]）
  /// 建议，容量不可知时回退 [defaultAudioMaxMb]；读取不写回（缺省与默认等价）。
  Future<int> audioMaxMb() async =>
      (await _readInt(keyAudioMaxMb)) ?? await _resolvedDefaultAudioMaxMb();

  /// 建议的音频缓存上限（MB）：设备总容量 ÷ [audioMaxStorageDivisor]，
  /// 不低于 [audioMaxSuggestionFloorMb]；容量不可知时返回 null（UI 不展示建议）。
  Future<int?> suggestedAudioMaxMb() async {
    final total = await _totalSpaceBytes();
    if (total == null || total <= 0) return null;
    final suggested = total ~/ (_mbBytes * audioMaxStorageDivisor);
    return suggested < audioMaxSuggestionFloorMb
        ? audioMaxSuggestionFloorMb
        : suggested;
  }

  /// 缺键默认值：解析一次后缓存（容量是设备级常量，无需每次查询通道）。
  int? _defaultAudioMaxMb;
  Future<int> _resolvedDefaultAudioMaxMb() async =>
      _defaultAudioMaxMb ??= (await suggestedAudioMaxMb()) ?? defaultAudioMaxMb;

  Future<int?> _totalSpaceBytes() async {
    try {
      return await _storage.totalSpaceBytes();
    } catch (_) {
      // 平台通道缺失 / 查询失败：按容量不可知处理。
      return null;
    }
  }

  /// 写入后立即执行一次 LRU 淘汰，无需重启。
  Future<void> setAudioMaxMb(int value) async {
    await _write(keyAudioMaxMb, value < 0 ? 0 : value);
    _notify(CachePartition.audio);
    await enforceAudioLimit(force: true);
  }

  /// 歌词缓存 TTL（天，默认 30；0 = 永不过期）。
  Future<int> lyricsTtlDays() async =>
      (await _readInt(keyLyricsTtlDays)) ?? defaultLyricsTtlDays;

  /// 取词时读取；缩短 TTL 后旧条目在下一次取词时立即视为过期。
  Future<void> setLyricsTtlDays(int value) async {
    await _write(keyLyricsTtlDays, value < 0 ? 0 : value);
    _notify(CachePartition.lyrics);
  }

  /// 封面缓存最大对象数（默认 1500；0 = 不限制）。
  Future<int> artworkMaxObjects() async =>
      (await _readInt(keyArtworkMaxObjects)) ?? defaultArtworkMaxObjects;

  /// 写入后通知 `ArtworkCache` 立即 sweep。
  Future<void> setArtworkMaxObjects(int value) async {
    await _write(keyArtworkMaxObjects, value < 0 ? 0 : value);
    _notify(CachePartition.artwork);
  }

  /// 封面缓存过期天数（默认 365；0 = 永不过期）。
  Future<int> artworkStaleDays() async =>
      (await _readInt(keyArtworkStaleDays)) ?? defaultArtworkStaleDays;

  /// 写入后通知 `ArtworkCache` 立即 sweep。
  Future<void> setArtworkStaleDays(int value) async {
    await _write(keyArtworkStaleDays, value < 0 ? 0 : value);
    _notify(CachePartition.artwork);
  }

  /// 分区用量（字节 + 条数）。
  Future<CacheUsage> usage(CachePartition partition) async {
    switch (partition) {
      case CachePartition.lyrics:
        return _lyricsCache.usage();
      case CachePartition.audio:
        return _dirUsage(await _safeDir(_storage.audioCacheDir));
      case CachePartition.artwork:
        return _dirUsage(await _safeDir(_storage.artworkCacheDir));
    }
  }

  /// 清理单个分区；完成后通知 [addClearListener]（用于封面索引等联动清理）。
  Future<void> clear(CachePartition partition) async {
    switch (partition) {
      case CachePartition.lyrics:
        await _lyricsCache.clear();
      case CachePartition.audio:
        final dir = await _safeDir(_storage.audioCacheDir);
        if (dir != null) await _storage.clear(dir);
      case CachePartition.artwork:
        final dir = await _safeDir(_storage.artworkCacheDir);
        if (dir != null) await _storage.clear(dir);
    }
    _notifyCleared(partition);
    notifyCacheChanged();
  }

  /// 清理全部分区。
  Future<void> clearAll() async {
    for (final partition in CachePartition.values) {
      await clear(partition);
    }
  }

  /// 音频 LRU 淘汰的节流窗口：淘汰要列举整个缓存目录并逐文件 `stat`，
  /// 每次起播 / 每次预取完成都跑一遍是 O(缓存文件数) 的串行 IO；窗口内的
  /// 后续调用跳过（写入还在继续，下一次淘汰自然会覆盖）。
  static const Duration audioEnforceMinInterval = Duration(minutes: 5);

  DateTime _lastAudioEnforce = DateTime.fromMillisecondsSinceEpoch(0);
  bool _audioEnforcing = false;

  /// 音频 LRU 淘汰（每次播放写入后 / 修改上限后调用）。
  ///
  /// [force] 用于「用户刚改了容量上限」这类必须立即生效的场景。
  Future<int> enforceAudioLimit({bool force = false}) async {
    if (_audioEnforcing) return 0;
    final now = DateTime.now();
    if (!force && now.difference(_lastAudioEnforce) < audioEnforceMinInterval) {
      return 0;
    }
    _audioEnforcing = true;
    _lastAudioEnforce = now;
    try {
      final maxMb = await audioMaxMb();
      if (maxMb <= 0) return 0; // 0 = 不限制
      final dir = await _safeDir(_storage.audioCacheDir);
      if (dir == null) return 0;
      final deleted = await _storage.enforceAudioLimit(
        dir,
        maxBytes: maxMb * _mbBytes,
        protectAge: _audioProtectAge,
      );
      if (deleted > 0) {
        _logger.info('音频缓存 LRU 淘汰 $deleted 个文件（上限 ${maxMb}MB）');
        notifyCacheChanged();
      }
      return deleted;
    } catch (e) {
      _logger.warning('音频缓存淘汰失败: $e');
      return 0;
    } finally {
      _audioEnforcing = false;
    }
  }

  /// 封面策略 sweep（启动时 / 修改策略后 / 定期由 ArtworkCache 触发）。
  Future<int> enforceArtworkPolicy() async {
    try {
      final dir = await _safeDir(_storage.artworkCacheDir);
      if (dir == null) return 0;
      final maxObjects = await artworkMaxObjects();
      final staleDays = await artworkStaleDays();
      final deleted = await _storage.sweepArtwork(
        dir,
        maxObjects: maxObjects,
        staleDays: staleDays,
      );
      if (deleted > 0) {
        _logger.info('封面缓存 sweep 清理 $deleted 个文件');
        notifyCacheChanged();
      }
      return deleted;
    } catch (e) {
      _logger.warning('封面缓存 sweep 失败: $e');
      return 0;
    }
  }

  /// 音频缓存目录（持久）；目录不可用返回 null。
  Future<String?> audioCacheDirPath() => _audioStore.directoryPath();

  /// 音频缓存索引（**只含完整可播放文件**：文件名 → 字节数）。
  ///
  /// 完整判据与列举口径见 [AudioCacheStore.index]。
  Future<Map<String, int>> audioCacheIndex() => _audioStore.index();

  /// 单曲音频缓存占用（所有音质变体；只认完整文件）。
  Future<CacheUsage> audioUsageForTrack({
    required String sourceKey,
    required String songId,
  }) =>
      _audioStore.usageForTrack(sourceKey: sourceKey, songId: songId);

  /// 单曲音频缓存「写入中」占用（半成品 / 边车）。
  ///
  /// 只用于占用展示解释（「有占用、但还不能离线播放」）；命中判定不看它。
  Future<CacheUsage> audioWritingUsageForTrack({
    required String sourceKey,
    required String songId,
  }) =>
      _audioStore.writingUsageForTrack(sourceKey: sourceKey, songId: songId);

  /// 清理单曲音频缓存（所有音质变体，含半成品）。
  ///
  /// [protectAge] 内修改过的文件视为正在写入（边播边缓存）跳过，
  /// 结果里的 `skipped` 用于区分「本来没缓存」与「播放中暂不能删」。
  Future<CacheDeleteResult> clearAudioForTrack({
    required String sourceKey,
    required String songId,
    Duration? protectAge,
  }) async {
    final result = await _audioStore.clearForTrack(
      sourceKey: sourceKey,
      songId: songId,
      protectAge: protectAge ?? _audioProtectAge,
    );
    if (result.deleted.count > 0) {
      _logger.info(
        '清理单曲音频缓存 ${result.deleted.count} 个文件'
        '（${result.deleted.bytes} 字节，跳过 ${result.skipped} 个活动文件）',
      );
      notifyCacheChanged();
    }
    return result;
  }

  /// 启动清扫音频缓存半成品（`.part` / `.predl`）。
  ///
  /// 半成品只可能由本进程写出，重启后残留的一律是中断产物；`.mime` 是完整
  /// 文件的边车，不在这里单独删（见 [AudioCacheStore.cleanupPartials]）。
  Future<int> cleanupAudioPartials() async {
    final deleted = await _audioStore.cleanupPartials();
    if (deleted > 0) {
      _logger.info('清扫音频缓存半成品 $deleted 个');
      notifyCacheChanged();
    }
    return deleted;
  }

  /// 单曲歌词缓存占用。
  Future<CacheUsage> lyricsUsageForTrack(String trackId) =>
      _lyricsCache.usageOf(trackId);

  /// 清理单曲歌词缓存（规范键 + 历史重复键）。
  Future<void> clearLyricsForTrack(String trackId) async {
    await _lyricsCache.remove(trackId);
    notifyCacheChanged();
  }

  /// 封面缓存目录（持久）；目录不可用返回 null。
  Future<String?> artworkCacheDirPath() => _safeDir(_storage.artworkCacheDir);

  // 策略变更监听（ArtworkCache 用）。

  void addPolicyListener(void Function(CachePartition) listener) {
    if (!_policyListeners.contains(listener)) _policyListeners.add(listener);
  }

  void removePolicyListener(void Function(CachePartition) listener) {
    _policyListeners.remove(listener);
  }

  /// 分区被清理后的联动监听（如封面管理器清空自身索引）。
  void addClearListener(void Function(CachePartition) listener) {
    if (!_clearListeners.contains(listener)) _clearListeners.add(listener);
  }

  void removeClearListener(void Function(CachePartition) listener) {
    _clearListeners.remove(listener);
  }

  void _notify(CachePartition partition) {
    for (final listener in List.of(_policyListeners)) {
      try {
        listener(partition);
      } catch (e) {
        _logger.warning('缓存策略监听回调失败: $e');
      }
    }
  }

  void _notifyCleared(CachePartition partition) {
    for (final listener in List.of(_clearListeners)) {
      try {
        listener(partition);
      } catch (e) {
        _logger.warning('缓存清理监听回调失败: $e');
      }
    }
  }

  Future<CacheUsage> _dirUsage(String? dir) async {
    if (dir == null) return CacheUsage.zero;
    try {
      return await _storage.usage(dir);
    } catch (e) {
      _logger.warning('缓存用量统计失败: $e');
      return CacheUsage.zero;
    }
  }

  Future<String?> _safeDir(Future<String?> Function() resolve) async {
    try {
      return await resolve();
    } catch (e) {
      // 平台通道缺失（测试 / 独立服务）或目录解析失败：按不可用处理。
      return null;
    }
  }

  Future<SharedPreferences?> _getPrefs() async {
    final cached = _prefs;
    if (cached != null) return cached;
    try {
      return _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      _logger.warning('SharedPreferences 不可用: $e');
      return null;
    }
  }

  Future<bool?> _readBool(String key) async {
    final prefs = await _getPrefs();
    return prefs?.getBool(key);
  }

  Future<int?> _readInt(String key) async {
    final prefs = await _getPrefs();
    final value = prefs?.get(key);
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  Future<void> _write(String key, Object value) async {
    final prefs = await _getPrefs();
    if (prefs == null) return;
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    }
  }
}
