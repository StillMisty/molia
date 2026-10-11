import 'dart:async';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/models/track.dart';
import '../models/lyrics_result.dart';
import 'cache_service.dart';
import 'lyrics_cache.dart';
import 'lyrics/lyric_provider.dart';
import 'lyrics/qq_provider.dart';
import 'lyrics/netease_provider.dart';
import 'lyrics/kugou_provider.dart';
import 'lyrics/kuwo_provider.dart';
import 'lyrics/migu_provider.dart';
import 'lyrics/lrclib_provider.dart';

export '../models/lyrics_result.dart';

/// 曲目原生取词加载器（组合根注入：`SourceManager` 路由脚本 `lyric`
/// action / any-listen / 内置平台原生实现）。
///
/// 返回值 [LyricsResult.provider] 为来源标签（如 `kw`/`kg`/脚本 key）。
typedef TrackLyricLoader = Future<LyricsResult?> Function(Track track);

class LyricsService {
  final Logger _logger = Logger();
  final List<LyricProvider> _providers;
  final CacheService _cacheService;
  final LyricsCache _lyricsCache;
  final TrackLyricLoader? _trackLyricLoader;

  LyricsService({
    List<LyricProvider>? providers,
    SharedPreferences? prefs,
    CacheService? cacheService,
    LyricsCache? lyricsCache,
    TrackLyricLoader? trackLyricLoader,
  })  : _providers = providers ??
            [
              NetEaseProvider(),
              QQProvider(),
              KugouProvider(),
              KuwoProvider(),
              MiguProvider(),
              LRCLibProvider(),
            ],
        _trackLyricLoader = trackLyricLoader,
        _lyricsCache = lyricsCache ?? LyricsCache(prefs: prefs),
        _cacheService = cacheService ?? CacheService.instance;

  /// 获取歌词（原文 + 可选翻译 / 罗马音 / 逐字）。
  ///
  /// 顺序：缓存 → 曲目原生取词（精确平台 ID，需传入 [track]）→
  /// 跨平台名字搜索回退（首个非空结果即返回，不再等待最慢的提供者）。
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId, {
    Track? track,
  }) async {
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
            lxlyric: cached.lxlyric,
            provider: cached.provider,
          );
        }
        _logger.i('缓存已过期: $trackId');
      }

      // 曲目原生取词：平台精确 ID（songmid/hash/mrcUrl…），优先于名字搜索。
      final loader = _trackLyricLoader;
      if (track != null && loader != null) {
        try {
          final native = await loader(track);
          if (native != null && native.lyric.trim().isNotEmpty) {
            await _writeCache(trackId, native);
            _logger.i('原生取词成功: $trackId (来源: ${native.provider})');
            return native;
          }
        } catch (e) {
          _logger.w('原生取词失败: $e');
        }
      }

      // 跨平台名字搜索回退。
      _logger.i('从网络获取歌词: $songName - $artistName');
      final result = await _getFromProviders(songName, artistName);
      if (result != null) {
        await _writeCache(trackId, result);
        _logger.i('歌词已缓存: $trackId (来源: ${result.provider})');
        return result;
      }
      return null;
    } catch (e) {
      _logger.e('获取歌词失败: $e');
      return null;
    }
  }

  Future<void> _writeCache(String trackId, LyricsResult result) {
    return _lyricsCache.write(
      trackId,
      LyricCacheData(
        provider: result.provider,
        lyric: result.lyric,
        translation: result.translation,
        roma: result.roma,
        lxlyric: result.lxlyric,
        timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
  }

  /// 手动选择歌词写入统一缓存（供 LyricsProvider.saveManual 复用）。
  ///
  /// 手动选择的文本通常没有独立的翻译 / 罗马音 / 逐字：对应参数缺省时
  /// 清空旧扩展行（与旧行为一致）；搜索页透传时则保留平台数据。
  Future<void> saveLyrics(
    String trackId,
    String lyric,
    String providerName, {
    String? translation,
    String? roma,
    String? lxlyric,
  }) async {
    await _lyricsCache.write(
      trackId,
      LyricCacheData(
        provider: providerName,
        lyric: lyric,
        translation: translation,
        roma: roma,
        lxlyric: lxlyric,
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
      lxlyric: payload.lxlyric,
      provider: provider.name,
    );
  }

  /// 并行请求所有提供者，**首个非空结果即返回**。
  ///
  /// 旧实现用 `Future.wait` 等全部完成再取第一个非空：歌词展示延迟被最慢
  /// 的提供者（通常 10s 超时）决定。现在谁先返回非空就用谁；其余请求继续
  /// 完成但结果丢弃（HTTP 无法真正取消，不阻塞展示即可）。
  Future<LyricsResult?> _getFromProviders(String title, String artist) {
    if (_providers.isEmpty) return Future.value(null);
    final completer = Completer<LyricsResult?>();
    var remaining = _providers.length;
    for (final provider in _providers) {
      _fetchFromProvider(provider, title, artist).then((result) {
        if (result != null && !completer.isCompleted) {
          completer.complete(result);
        }
      }).catchError((Object e) {
        _logger.w('从 ${provider.name} 获取歌词失败: $e');
      }).whenComplete(() {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }
    return completer.future;
  }

  /// 获取当前使用的提供者列表
  List<String> getProviderNames() {
    return _providers.map((provider) => provider.name).toList();
  }
}
