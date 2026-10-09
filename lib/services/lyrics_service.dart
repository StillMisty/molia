import 'dart:async';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/lyrics_result.dart';
import 'cache_service.dart';
import 'lyrics_cache.dart';
import 'lyrics/lyric_provider.dart';
import 'lyrics/qq_provider.dart';
import 'lyrics/netease_provider.dart';
import 'lyrics/lrclib_provider.dart';

export '../models/lyrics_result.dart';

class LyricsService {
  final Logger _logger = Logger();
  final List<LyricProvider> _providers;
  final CacheService _cacheService;
  final LyricsCache _lyricsCache;

  LyricsService({
    List<LyricProvider>? providers,
    SharedPreferences? prefs,
    CacheService? cacheService,
    LyricsCache? lyricsCache,
  })  : _providers = providers ?? [NetEaseProvider(), QQProvider(), LRCLibProvider()],
        _lyricsCache = lyricsCache ?? LyricsCache(prefs: prefs),
        _cacheService = cacheService ?? CacheService.instance;

  /// 获取歌词（原文 + 可选翻译 / 罗马音）
  ///
  /// 返回 [LyricsResult] 包含歌词文本与来源信息
  Future<LyricsResult?> getLyrics(String songName, String artistName, String trackId) async {
    try {
      final cached = await _lyricsCache.read(trackId);
      if (cached != null) {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        // TTL 从统一缓存策略读取（0 = 永不过期），修改后无需重启。
        final ttlDays = await _cacheService.lyricsTtlDays();
        final ttlSeconds = ttlDays * 24 * 60 * 60;
        if (ttlDays <= 0 || now - cached.timestamp < ttlSeconds) {
          _logger.i('从缓存获取歌词: $trackId (来源: ${cached.provider})');
          return LyricsResult(
            lyric: cached.lyric,
            translation: cached.translation,
            roma: cached.roma,
            provider: cached.provider,
          );
        }
        _logger.i('缓存已过期: $trackId');
      }

      // 如果缓存中没有或已过期，从网络获取
      _logger.i('从网络获取歌词: $songName - $artistName');

      final result = await _getFromProviders(songName, artistName);

      if (result != null) {
        await _lyricsCache.write(
          trackId,
          LyricCacheData(
            provider: result.provider,
            lyric: result.lyric,
            translation: result.translation,
            roma: result.roma,
            timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          ),
        );
        _logger.i('歌词已缓存: $trackId (来源: ${result.provider})');
        return result;
      }

      return null;
    } catch (e) {
      _logger.e('获取歌词失败: $e');
      return null;
    }
  }

  /// 手动选择歌词写入统一缓存（供 LyricsProvider.saveManual 复用）。
  ///
  /// 手动选择的文本没有独立的翻译 / 罗马音，写入时清空旧扩展行。
  Future<void> saveLyrics(
    String trackId,
    String lyric,
    String providerName,
  ) async {
    await _lyricsCache.write(
      trackId,
      LyricCacheData(
        provider: providerName,
        lyric: lyric,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
  }

  /// 从单个提供者获取结构化歌词
  Future<LyricsResult?> _fetchFromProvider(
      LyricProvider provider, String title, String artist) async {
    final payload = await provider.getLyrics(title, artist);
    if (payload == null) return null;
    return LyricsResult(
      lyric: payload.lyric,
      translation: payload.translation,
      roma: payload.roma,
      provider: provider.name,
    );
  }

  /// 并行请求所有提供者，取第一个非空结果。
  ///
  /// 失败路径不再顺序重试（旧实现会为每个提供者重复发一轮相同请求，
  /// 既慢一倍也没有真正的「延长超时」——提供者内部本就没有超时参数）。
  Future<LyricsResult?> _getFromProviders(String title, String artist) async {
    try {
      final futures = _providers
          .map((provider) async {
            try {
              return await _fetchFromProvider(provider, title, artist);
            } catch (e) {
              _logger.w('从 ${provider.name} 获取歌词失败: $e');
              return null;
            }
          })
          .toList();

      final results = await Future.wait(futures);
      for (final result in results) {
        if (result != null) return result;
      }
      return null;
    } catch (e) {
      _logger.e('从提供者获取歌词失败: $e');
      return null;
    }
  }

  /// 获取当前使用的提供者列表
  List<String> getProviderNames() {
    return _providers.map((provider) => provider.name).toList();
  }
}
