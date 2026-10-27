import 'dart:async';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/perf/data_path_trace.dart';
import '../domain/models/track.dart';
import '../models/lyrics_result.dart';
import 'cache_service.dart';
import 'lyrics_cache.dart';
import 'lyrics/lyric_provider.dart';
import 'lyrics/lyrics_source_registry.dart';

export '../models/lyrics_result.dart';

/// 曲目原生取词加载器（组合根注入：`SourceManager` 路由脚本 `lyric`
/// action / any-listen / 内置平台原生实现）。
///
/// 返回值 [LyricsResult.provider] 为来源标签（如 `kw`/`kg`/脚本 key）。
typedef TrackLyricLoader = Future<LyricsResult?> Function(Track track);

class LyricsService {
  final Logger _logger = Logger('molia.lyrics_service');
  final List<LyricProvider> _providers;
  final CacheService _cacheService;
  final LyricsCache _lyricsCache;
  final TrackLyricLoader? _trackLyricLoader;

  /// 是否允许网络歌词回退（缺省允许）。
  ///
  /// 组合根对本地下载曲目返回 false：离线歌词缺失时不发起跨平台网络搜索
  /// （「离线播放全程不联网」）；在线曲目行为不变。
  final bool Function(Track track)? _networkFallbackAllowed;

  /// 曲目原生歌词现在是否可用（B 站登录后 true）：缓存来源与曲目不同源时
  /// 优先重试原生，而不是继续用跨平台缓存。
  final bool Function(Track track)? _nativeLyricAvailable;

  /// 同渠道名字搜索的优先预算。
  ///
  /// 跨平台回退会同时发起全部请求，但只有曲目来源渠道能在预算内决定结果；
  /// 超时后改用其它渠道的首个非空结果（此时通常已在途 / 已完成，不再额外
  /// 等待网络）。没有同渠道 provider 的曲目保持原有并行竞速。
  final Duration sameSourceTimeout;

  /// [providers] 只用于测试注入；缺省取 [LyricsSourceRegistry.standard] 的
  /// 自动回退来源（五个音乐平台 + LRCLIB，B 站字幕不在其中）。
  ///
  /// 注册表是 static final（延迟初始化），这里只读列表，不创建实例、不发
  /// 请求；provider 的网络调用仍只发生在真正取词时。`standard` 的 B 站
  /// 可用性闭包绑定 `BiliSession.shared`（生产账号服务默认写同一份）；
  /// 自动回退列表本来就不含 B 站，会话注入不改变取词顺序。
  LyricsService({
    List<LyricProvider>? providers,
    SharedPreferences? prefs,
    CacheService? cacheService,
    LyricsCache? lyricsCache,
    this._trackLyricLoader,
    this._networkFallbackAllowed,
    this._nativeLyricAvailable,
    this.sameSourceTimeout = const Duration(seconds: 3),
  })  : _providers = providers ?? LyricsSourceRegistry.standard.autoProviders,
        _lyricsCache = lyricsCache ?? LyricsCache(prefs: prefs),
        _cacheService = cacheService ?? CacheService.instance;

  /// 获取歌词（原文 + 可选翻译 / 罗马音 / 逐字）。
  ///
  /// 顺序：缓存 → 曲目原生取词（精确平台 ID，需传入 [track]）→
  /// 本渠道名字搜索（同源预算内优先）→ 其它渠道并行竞速兜底。
  ///
  /// [ignoreCache] 为 true 时跳过缓存读取（登录 / 手动刷新场景）。
  Future<LyricsResult?> getLyrics(
    String songName,
    String artistName,
    String trackId, {
    Track? track,
    bool ignoreCache = false,
  }) async {
    try {
      final cacheWatch = DataPathTrace.enabled && !ignoreCache
          ? (Stopwatch()..start())
          : null;
      final cached = ignoreCache ? null : await _lyricsCache.read(trackId);
      if (cacheWatch != null) {
        DataPathTrace.record(
          'lyrics.cache',
          cacheWatch.elapsed,
          fields: () => {'hit': cached == null ? 0 : 1},
        );
      }
      if (cached != null) {
        // B 站登录后，缓存里的网易云 / 其它平台结果不再优先：先试一次
        // 曲目原生字幕。手动选择过的歌词（manual）尊重用户选择。
        final preferNative =
            track != null &&
            !cached.manual &&
            cached.provider != track.id.sourceKey &&
            (_nativeLyricAvailable?.call(track) ?? false);
        if (!preferNative) {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          // TTL 从统一缓存策略读取（0 = 永不过期），修改后无需重启。
          final ttlDays = await _cacheService.lyricsTtlDays();
          final ttlSeconds = ttlDays * 24 * 60 * 60;
          if (ttlDays <= 0 || now - cached.timestamp < ttlSeconds) {
            _logger.info('从缓存获取歌词: $trackId (来源: ${cached.provider})');
            return LyricsResult(
              lyric: cached.lyric,
              translation: cached.translation,
              roma: cached.roma,
              lxlyric: cached.lxlyric,
              provider: cached.provider,
            );
          }
          _logger.info('缓存已过期: $trackId');
        } else {
          _logger.info('缓存来源与曲目不同源，优先原生取词: $trackId');
        }
      }

      // 曲目原生取词：平台精确 ID（songmid/hash/mrcUrl…），优先于名字搜索。
      final loader = _trackLyricLoader;
      if (track != null && loader != null) {
        try {
          final native = await DataPathTrace.async(
            'lyrics.native',
            () => loader(track),
            fields: () => {'source': track.id.sourceKey},
          );
          if (native != null && native.lyric.trim().isNotEmpty) {
            await DataPathTrace.async(
              'lyrics.cacheWrite',
              () => _writeCache(trackId, native),
              fields: () => {'chars': native.lyric.length},
            );
            _logger.info('原生取词成功: $trackId (来源: ${native.provider})');
            return native;
          }
        } catch (e) {
          _logger.warning('原生取词失败: $e');
        }
      }

      // 本地下载曲目：离线歌词缺失时不回退网络（离线播放全程不触网）。
      if (track != null && !(_networkFallbackAllowed?.call(track) ?? true)) {
        _logger.info('跳过网络歌词回退（离线曲目）: $trackId');
        return null;
      }

      _logger.info('从网络获取歌词: $songName - $artistName');
      final result = await DataPathTrace.async(
        'lyrics.network',
        () => _getFromProviders(
          songName,
          artistName,
          preferredChannelKey: track?.id.sourceKey,
        ),
      );
      if (result != null) {
        await DataPathTrace.async(
          'lyrics.cacheWrite',
          () => _writeCache(trackId, result),
          fields: () => {'chars': result.lyric.length},
        );
        _logger.info('歌词已缓存: $trackId (来源: ${result.provider})');
        return result;
      }
      return null;
    } catch (e) {
      _logger.severe('获取歌词失败: $e');
      return null;
    }
  }

  /// 当前缓存是否为用户手动选择的歌词（登录后刷新不应覆盖）。
  Future<bool> hasManualLyrics(String trackId) async {
    try {
      final cached = await _lyricsCache.read(trackId);
      return cached?.manual ?? false;
    } catch (_) {
      return false;
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
        manual: false,
      ),
    );
  }

  /// 手动选择歌词写入统一缓存（供 LyricsProvider.saveManual 复用）。
  ///
  /// 手动选择的文本通常没有独立的翻译 / 罗马音 / 逐字：对应参数缺省时
  /// 清空扩展行（翻译 / 罗马音 / 逐字）；搜索页透传时则保留平台数据。
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
        manual: true,
      ),
    );
  }

  /// 从单个提供者获取结构化歌词
  Future<LyricsResult?> _fetchFromProvider(
    LyricProvider provider,
    String title,
    String artist,
  ) async {
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

  /// 并行请求所有提供者：同渠道优先，其它渠道首个非空兜底。
  ///
  /// 所有请求在进入方法时同时发起（预取），因此同渠道超时后通常不用再等
  /// 一轮网络。判定规则：
  /// - 没有同渠道 provider（B 站 / 脚本 / 本地）→ 保持首个非空即返回；
  /// - 同渠道在 [sameSourceTimeout] 内返回非空 → 直接用它（即使其它渠道
  ///   更早返回）；
  /// - 同渠道为空 / 抛错 / 超时 → 用其它渠道的首个非空结果；
  /// - 同渠道晚到的非空结果仍可作为兜底（已经包含在竞速里）。
  Future<LyricsResult?> _getFromProviders(
    String title,
    String artist, {
    String? preferredChannelKey,
  }) {
    if (_providers.isEmpty) return Future.value(null);

    // provider → 在途请求；错误在这里统一归一为 null，竞速不再处理异常。
    final pending = <LyricProvider, Future<LyricsResult?>>{
      for (final provider in _providers)
        provider: _fetchFromProvider(provider, title, artist).catchError(
          (Object e) {
            _logger.warning('从 ${provider.name} 获取歌词失败: $e');
            return null;
          },
        ),
    };
    final firstAny = _firstNonEmpty(pending.values);

    final preferred = _providerForChannel(preferredChannelKey);
    if (preferred == null || _providers.length == 1) return firstAny;

    return pending[preferred]!
        .timeout(sameSourceTimeout, onTimeout: () => null)
        .then((sameSource) {
      if (sameSource != null) {
        _logger.info('同源歌词命中: ${preferred.name}');
        return sameSource;
      }
      _logger.info('同源歌词未命中 / 超时，使用跨平台回退: ${preferred.name}');
      return firstAny;
    });
  }

  /// 曲目来源渠道对应的自动回退 provider（没有 / 已停用时为 null）。
  LyricProvider? _providerForChannel(String? channelKey) {
    final key = channelKey?.trim();
    if (key == null || key.isEmpty) return null;
    for (final provider in _providers) {
      if (provider.channelKey == key) return provider;
    }
    return null;
  }

  /// 第一个非空结果；全部为空 / 失败时返回 null。
  static Future<LyricsResult?> _firstNonEmpty(
    Iterable<Future<LyricsResult?>> futures,
  ) {
    final completer = Completer<LyricsResult?>();
    var remaining = 0;
    for (final future in futures) {
      remaining++;
      future.then((result) {
        if (result != null && !completer.isCompleted) {
          completer.complete(result);
        }
      }).whenComplete(() {
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      });
    }
    if (remaining == 0) completer.complete(null);
    return completer.future;
  }

  /// 获取当前使用的提供者列表
  List<String> getProviderNames() {
    return _providers.map((provider) => provider.name).toList();
  }
}
