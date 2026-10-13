import 'dart:async';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cache_storage.dart';
import 'lyrics_cache.dart';

export 'cache_storage.dart' show CachePartition, CacheUsage;

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
/// - **平台文件操作**走 [CacheStorage]（Web 为空实现），策略逻辑与
///   `dart:io` 解耦。
class CacheService {
  CacheService({
    SharedPreferences? prefs,
    CacheStorage? storage,
    LyricsCache? lyricsCache,
    Duration audioProtectAge = const Duration(minutes: 10),
  })  : _prefs = prefs,
        _storage = storage ?? createPlatformCacheStorage(),
        _lyricsCache = lyricsCache ?? LyricsCache(prefs: prefs),
        _audioProtectAge = audioProtectAge;

  /// 全局单例（main.dart 注册前的默认入口）。
  static final CacheService instance = CacheService();

  // 策略键名（固定，设置 UI / 测试共用）
  static const String keyAudioEnabled = 'cache_audio_enabled';
  static const String keyAudioMaxMb = 'cache_audio_max_mb';
  static const String keyLyricsTtlDays = 'cache_lyrics_ttl_days';
  static const String keyArtworkMaxObjects = 'cache_artwork_max_objects';
  static const String keyArtworkStaleDays = 'cache_artwork_stale_days';

  static const bool defaultAudioEnabled = true;

  /// 容量不可知（Web / 桌面 / 查询失败）时的音频上限回退值（MB）。
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
  final LyricsCache _lyricsCache;
  final Duration _audioProtectAge;
  SharedPreferences? _prefs;
  final Logger _logger = Logger('molia.cache_service');

  final List<void Function(CachePartition)> _policyListeners = [];
  final List<void Function(CachePartition)> _clearListeners = [];

  /// 是否启用音频边播边缓存（默认 true）。
  Future<bool> audioEnabled() async =>
      (await _readBool(keyAudioEnabled)) ?? defaultAudioEnabled;

  Future<void> setAudioEnabled(bool value) async {
    await _write(keyAudioEnabled, value);
    _notify(CachePartition.audio);
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
      _defaultAudioMaxMb ??=
          (await suggestedAudioMaxMb()) ?? defaultAudioMaxMb;

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
    await enforceAudioLimit();
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
  }

  /// 清理全部分区。
  Future<void> clearAll() async {
    for (final partition in CachePartition.values) {
      await clear(partition);
    }
  }

  /// 音频 LRU 淘汰（每次播放写入后 / 修改上限后调用）。
  Future<int> enforceAudioLimit() async {
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
      }
      return deleted;
    } catch (e) {
      _logger.warning('音频缓存淘汰失败: $e');
      return 0;
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
      }
      return deleted;
    } catch (e) {
      _logger.warning('封面缓存 sweep 失败: $e');
      return 0;
    }
  }

  /// 音频缓存目录（持久）；平台不可用（Web）返回 null。
  Future<String?> audioCacheDirPath() => _safeDir(_storage.audioCacheDir);

  /// 封面缓存目录（持久）；平台不可用（Web）返回 null。
  Future<String?> artworkCacheDirPath() => _safeDir(_storage.artworkCacheDir);

  /// 生成音频缓存文件名：`sourceKey_songId_quality`（quality 未知用 auto）。
  ///
  /// 非文件名字符（`:`、`/` 等）替换为 `_`；发生替换时追加原串哈希后缀，
  /// 避免 `a:b` 与 `a_b` 这类不同 key 映射到同一文件名。
  static String audioCacheKey({
    required String sourceKey,
    required String songId,
    String quality = 'auto',
  }) {
    final effectiveQuality = quality.trim().isEmpty ? 'auto' : quality.trim();
    final raw = '${sourceKey}_${songId}_$effectiveQuality';
    final sanitized = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (sanitized == raw) return raw;
    final truncated =
        sanitized.length > 100 ? sanitized.substring(0, 100) : sanitized;
    final hash = raw.hashCode.toUnsigned(32).toRadixString(16);
    return '${truncated}_$hash';
  }

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
      // 平台通道缺失（测试/Web）或目录解析失败：按不可用处理。
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
