import 'dart:async';

import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cache_storage.dart';
import 'lyrics_cache.dart';

export 'cache_storage.dart' show CachePartition, CacheUsage;

/// 统一缓存门面：音频 / 歌词 / 封面三个分区的策略、统计与清理。
///
/// 设计要点：
/// - **不依赖 provider**：UI 只读策略、写入策略都直接走本服务；后续在
///   composition root（main.dart）注册为 Provider 即可，本次先以单例
///   [instance] 供播放服务与图片组件使用；
/// - **策略持久化**（SharedPreferences，键名固定）：所有 getter 每次从
///   prefs 读取，setter 写入后立即触发对应动作，因此**无需重启**：
///   - 音频开关：播放时读取；
///   - 音频上限：setter 立即执行 [enforceAudioLimit]；
///   - 歌词 TTL：取词时读取（缩短 TTL 后旧条目立即按过期处理）；
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

  // --- 策略键名（固定，设置 UI / 测试共用） ---
  static const String keyAudioEnabled = 'cache_audio_enabled';
  static const String keyAudioMaxMb = 'cache_audio_max_mb';
  static const String keyLyricsTtlDays = 'cache_lyrics_ttl_days';
  static const String keyArtworkMaxObjects = 'cache_artwork_max_objects';
  static const String keyArtworkStaleDays = 'cache_artwork_stale_days';

  // --- 默认值 ---
  static const bool defaultAudioEnabled = true;
  static const int defaultAudioMaxMb = 1024;
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
  final Logger _logger = Logger();

  final List<void Function(CachePartition)> _policyListeners = [];
  final List<void Function(CachePartition)> _clearListeners = [];

  // ---------------------------------------------------------------------------
  // 策略读写
  // ---------------------------------------------------------------------------

  /// 是否启用音频边播边缓存（默认 true）。
  Future<bool> audioEnabled() async =>
      (await _readBool(keyAudioEnabled)) ?? defaultAudioEnabled;

  Future<void> setAudioEnabled(bool value) async {
    await _write(keyAudioEnabled, value);
    _notify(CachePartition.audio);
  }

  /// 音频缓存上限（MB，默认 1024；0 = 不限制）。
  Future<int> audioMaxMb() async =>
      (await _readInt(keyAudioMaxMb)) ?? defaultAudioMaxMb;

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

  // ---------------------------------------------------------------------------
  // 用量 / 清理
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // 分区维护
  // ---------------------------------------------------------------------------

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
        _logger.i('音频缓存 LRU 淘汰 $deleted 个文件（上限 ${maxMb}MB）');
      }
      return deleted;
    } catch (e) {
      _logger.w('音频缓存淘汰失败: $e');
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
        _logger.i('封面缓存 sweep 清理 $deleted 个文件');
      }
      return deleted;
    } catch (e) {
      _logger.w('封面缓存 sweep 失败: $e');
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

  // ---------------------------------------------------------------------------
  // 策略变更监听（ArtworkCache 用）
  // ---------------------------------------------------------------------------

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
        _logger.w('缓存策略监听回调失败: $e');
      }
    }
  }

  void _notifyCleared(CachePartition partition) {
    for (final listener in List.of(_clearListeners)) {
      try {
        listener(partition);
      } catch (e) {
        _logger.w('缓存清理监听回调失败: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  Future<CacheUsage> _dirUsage(String? dir) async {
    if (dir == null) return CacheUsage.zero;
    try {
      return await _storage.usage(dir);
    } catch (e) {
      _logger.w('缓存用量统计失败: $e');
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
      _logger.w('SharedPreferences 不可用: $e');
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
