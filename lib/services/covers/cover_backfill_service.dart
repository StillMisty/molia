/// 封面补取：本渠道原生 → 本渠道名字搜索 → 跨渠道严格匹配。
///
/// 只服务「曲目当前没有封面」的场景（播放补图 / 下载补图）。已有封面 URL
/// 由调用方先使用；本服务不校验 URL 是否可下载（图片加载失败仍走展示面
/// 默认占位，不在这里做二次网络猜测）。
///
/// 为什么需要跨渠道：本渠道原生取图依赖曲目 raw 字段，字段缺失 / 接口失败
/// 时即使平台搜索能返回同一首歌的封面也拿不到。跨渠道阶段按歌名 + 歌手
/// 搜索五个音乐平台，并用 `song_match.dart` 的严格匹配挡住版本 / 时长不符
/// 的候选——宁可不补，也不贴错封面。
library;

import 'dart:async';

import 'package:logging/logging.dart';

import '../../data/cache/request_cache.dart';
import '../../domain/models/download.dart' show kLocalSourceKey;
import '../../domain/models/track.dart';
import '../../sources/builtin/builtin_platforms.dart';
import '../song_match.dart';

/// 渠道搜索：按关键词返回候选曲目（生产实现走内置平台搜索）。
typedef CoverChannelSearch = Future<List<Track>> Function(
  String channelKey,
  String keyword,
);

/// 渠道是否启用（用户可在音源页停用）。
typedef CoverChannelEnabled = bool Function(String channelKey);

/// 封面补取服务（无 UI / 无播放依赖，可单测）。
class CoverBackfillService {
  CoverBackfillService({
    required this.nativeLoader,
    required this.searchChannel,
    required this.isChannelEnabled,
    String Function(Track track)? keywordOf,
    this.sameSourceTimeout = const Duration(seconds: 2),
    RequestCache? cache,
  }) : _keywordOf = keywordOf ?? _defaultKeywordOf,
       _cache =
           cache ??
           RequestCache(maxEntries: 128, ttl: const Duration(minutes: 10));

  final Future<String?> Function(Track track) nativeLoader;
  final CoverChannelSearch searchChannel;
  final CoverChannelEnabled isChannelEnabled;
  final String Function(Track track) _keywordOf;
  final Duration sameSourceTimeout;
  final RequestCache _cache;
  final Logger _logger = Logger('molia.cover_backfill');

  /// 取封面；已有封面 / 找不到返回 null。
  ///
  /// [allowCrossChannel] 为 false 时只走曲目原生取图（离线 / 省流调用方）。
  /// 正结果缓存 10 分钟并 single-flight；空结果不进缓存，下次起播可重试。
  Future<String?> fetch(Track track, {bool allowCrossChannel = true}) {
    final key =
        'cover:${track.id.uri}:${allowCrossChannel ? 'full' : 'native'}';
    return _cache
        .getOrCreate<String?>(
          key,
          () => _fetch(track, allowCrossChannel: allowCrossChannel),
        )
        .then((url) {
          if (url == null) _cache.invalidate(key);
          return url;
        });
  }

  Future<String?> _fetch(Track track, {required bool allowCrossChannel}) async {
    final native = _notEmpty(await _safeNative(track));
    if (native != null) return native;

    // 本地离线副本没有可用的「原渠道」，也不应因补封面触网。
    if (!allowCrossChannel || track.id.sourceKey == kLocalSourceKey) {
      return null;
    }

    final keyword = _keywordOf(track).trim();
    if (keyword.isEmpty) return null;

    final sourceKey = track.id.sourceKey;
    final sourceAllowed =
        BuiltinPlatforms.musicKeys.contains(sourceKey) &&
        isChannelEnabled(sourceKey);
    final sourceFuture = sourceAllowed
        ? _searchCover(sourceKey, keyword, track)
        : Future<String?>.value(null);
    final otherKeys = [
      for (final channelKey in BuiltinPlatforms.musicKeys)
        if (channelKey != sourceKey && isChannelEnabled(channelKey)) channelKey,
    ];
    final otherFutures = [
      for (final channelKey in otherKeys)
        _searchCover(channelKey, keyword, track),
    ];

    final firstAny = _firstNonNull([sourceFuture, ...otherFutures]);
    // 没有同渠道搜索或没有其它渠道时不需要预算，直接采用现有竞速结果。
    if (!sourceAllowed || otherFutures.isEmpty) return firstAny;

    final sameSource = await sourceFuture.timeout(
      sameSourceTimeout,
      onTimeout: () => null,
    );
    if (sameSource != null) return sameSource;
    return firstAny;
  }

  Future<String?> _searchCover(
    String channelKey,
    String keyword,
    Track target,
  ) async {
    try {
      final candidates = await searchChannel(channelKey, keyword);
      final usable = [
        for (final candidate in candidates)
          if (_notEmpty(candidate.artwork?.uri.toString()) != null) candidate,
      ];
      if (usable.isEmpty) return null;
      final match = pickBestSongMatchBy<Track>(
        usable,
        target: _infoOf(target),
        info: _infoOf,
        requireStrictMatch: true,
      );
      return _notEmpty(match?.artwork?.uri.toString());
    } catch (e) {
      _logger.fine('渠道 $channelKey 补封面失败: $e');
      return null;
    }
  }

  Future<String?> _safeNative(Track track) async {
    try {
      return await nativeLoader(track);
    } catch (e) {
      _logger.fine('原生封面取图失败: $e');
      return null;
    }
  }

  static SongMatchInfo _infoOf(Track track) => SongMatchInfo(
    title: track.title,
    artist: track.artistLabel,
    album: track.album,
    duration: track.duration,
  );

  static String _defaultKeywordOf(Track track) => [
    track.title,
    ...track.artists.map((artist) => artist.name),
  ].map((value) => value.trim()).where((value) => value.isNotEmpty).join(' ');

  /// 第一个非空结果；全部为空 / 失败时返回 null。
  static Future<String?> _firstNonNull(Iterable<Future<String?>> futures) {
    final completer = Completer<String?>();
    var remaining = 0;
    for (final future in futures) {
      remaining++;
      future
          .then((value) {
            if (value != null && !completer.isCompleted) {
              completer.complete(value);
            }
          })
          .whenComplete(() {
            remaining--;
            if (remaining == 0 && !completer.isCompleted) {
              completer.complete(null);
            }
          });
    }
    if (remaining == 0) completer.complete(null);
    return completer.future;
  }

  static String? _notEmpty(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
