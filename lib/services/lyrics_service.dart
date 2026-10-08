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

  /// 获取歌词
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
            provider: cached.provider,
          );
        }
        _logger.i('缓存已过期: $trackId');
      }

      // 如果缓存中没有或已过期，从网络获取
      _logger.i('从网络获取歌词: $songName - $artistName');

      final lyrics = await _getFromProviders(songName, artistName);

      if (lyrics != null) {
        final provider = lyrics['provider'] as String;
        final lyricText = lyrics['lyric'] as String;

        final cacheData = LyricCacheData(
          provider: provider,
          lyric: lyricText,
          timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );

        await _lyricsCache.write(trackId, cacheData);
        _logger.i('歌词已缓存: $trackId (来源: $provider)');

        return LyricsResult(
          lyric: lyricText,
          provider: provider,
        );
      }

      return null;
    } catch (e) {
      _logger.e('获取歌词失败: $e');
      return null;
    }
  }

  /// 从单个提供者获取歌词
  Future<Map<String, String>?> _fetchFromProvider(
      LyricProvider provider, String title, String artist) async {
    final lyric = await provider.getLyric(title, artist);
    return lyric != null ? {'provider': provider.name, 'lyric': lyric} : null;
  }

  /// 从多个提供者并行获取歌词
  /// 返回 Map 包含 provider 与 lyric
  Future<Map<String, String>?> _getFromProviders(String title, String artist) async {
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
      final validResults = results.where((result) => result != null).toList();

      if (validResults.isNotEmpty) {
        return validResults.first;
      }

      // 如果并行获取都失败，尝试顺序获取（增加超时时间）
      for (final provider in _providers) {
        _logger.i('尝试从 ${provider.name} 获取歌词（延长超时）');
        final result = await _fetchFromProvider(provider, title, artist);
        if (result != null) {
          return result;
        }
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
