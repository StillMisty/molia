/// AI 推歌生成服务：画像 → 提示词 → LLM → 解析 → 本地搜索解析成可播放曲目。
///
/// 链路（「闭卷生成 + 本地解析」）：
/// 1. [TasteProfileBuilder] 构建聚合画像 + 最近明细 + 排除清单；
/// 2. [LlmClient] 单轮补全，要求纯 JSON；
/// 3. 容错解析（首 `{`…末 `}`，兼容数组/字符串条目）；
/// 4. 与已听排除清单、批内规范化去重；
/// 5. `CatalogService.search` 在可搜索音源并行解析（并发限流，标题/艺人
///    规范化打分），解析失败的作为 unresolved 返回（页面折叠展示）。
library;

import 'dart:convert';
import 'dart:math' as math;

import '../../data/catalog/catalog_service.dart';
import '../../domain/models/ai_dj.dart';
import '../../domain/models/catalog.dart';
import '../../domain/models/failure.dart';
import '../../domain/models/play_statistics.dart';
import '../../domain/models/source.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/source_registry.dart';
import 'ai_text.dart';
import 'llm_client.dart';
import 'taste_profile_builder.dart';

/// 推荐生成器接口：模式控制器只依赖这一层（测试可注入假实现）。
abstract interface class AiRecommendationGenerator {
  /// 生成一批推荐（[count] 首上限）。
  ///
  /// [skippedLabels] / [likedLabels] 是本轮反馈；[excludeLabels] 是本次生成
  /// 额外排除（如「换一首」时排除列表内已有曲目），不进入反馈回流。
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    List<String> skippedLabels,
    List<String> likedLabels,
    List<String> excludeLabels,
  });

  /// 连接测试（地址/Key/模型），失败抛 [SourceFailure]。
  Future<void> testConnection(LlmConfig config);

  /// 上行数据摘要（「本次发送的数据」；不触发 LLM 调用）。
  Future<AiUpstreamSummary> summarizeUpstream();
}

class AiRecommendationService implements AiRecommendationGenerator {
  AiRecommendationService({
    required LlmClient llm,
    required CatalogService catalog,
    required SourceRegistry registry,
    required TasteProfileBuilder profileBuilder,
    this.searchSourceLimit = 3,
    this.resolveConcurrency = 3,
  })  : _llm = llm,
        _catalog = catalog,
        _registry = registry,
        _profileBuilder = profileBuilder;

  final LlmClient _llm;
  final CatalogService _catalog;
  final SourceRegistry _registry;
  final TasteProfileBuilder _profileBuilder;

  /// 每首推荐最多尝试的可搜索音源数。
  final int searchSourceLimit;

  /// 解析并发（同时搜索的曲目数）。
  final int resolveConcurrency;

  static const String systemPrompt =
      '你是一名中文音乐推荐助手。只输出 JSON，不要输出解释或 Markdown 代码块。'
      'JSON 格式：{"songs":[{"title":"歌名","artist":"歌手","reason":"一句话理由"}]}。'
      '要求：推荐用户没听过、且在中国大陆主流音乐平台（QQ音乐/网易云音乐/酷狗/酷我/咪咕）'
      '能搜索到的歌曲；理由用中文、不超过 20 字；不要推荐排除清单中的歌曲。';

  /// 连接测试（地址/Key/模型），失败抛 [SourceFailure]。
  @override
  Future<void> testConnection(LlmConfig config) => _llm.testConnection(config);

  /// 上行数据摘要：只统计条数，不发往任何服务。
  @override
  Future<AiUpstreamSummary> summarizeUpstream() async {
    final profile = await _profileBuilder.build();
    return AiUpstreamSummary(
      recentEvents: profile.recentEvents.length,
      topArtists: profile.topArtists.length,
      topTracks: profile.topTracks.length,
      exclusions: profile.exclusionLabels.length,
    );
  }

  /// 生成一批推荐（[count] 首上限）。
  @override
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
  }) async {
    final profile = await _profileBuilder.build();
    final userPrompt = buildUserPrompt(
      profile: profile,
      count: count,
      skippedLabels: skippedLabels,
      likedLabels: likedLabels,
      excludeLabels: excludeLabels,
    );
    // 要求服务端返回 JSON 对象（提示词已限定格式；不支持的提供商自动退回）。
    final raw = await _llm.complete(
      config: config,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      jsonMode: true,
    );
    final parsed = parseRecommendations(raw, limit: count);
    if (parsed.isEmpty) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: '模型未返回可解析的推荐',
        l10nKey: 'aiDjBadResponse',
        retryable: true,
      );
    }

    // 排除已听 + 批内去重（规范化键）。
    final seen = Set<String>.of(profile.exclusionKeys);
    final candidates = <AiRecommendation>[];
    for (final recommendation in parsed) {
      final key = aiTrackKey(recommendation.title, recommendation.artist);
      if (key.replaceAll('|', '').isEmpty) continue;
      if (!seen.add(key)) continue;
      candidates.add(recommendation);
    }

    final resolution = await _resolveAll(candidates);
    return AiDjBatch(
      items: resolution.resolved,
      unresolved: resolution.unresolved,
      generatedAt: DateTime.now(),
    );
  }

  /// 提示词：画像 JSON + 本轮反馈 + 额外排除 + 推荐数量。
  static String buildUserPrompt({
    required TasteProfile profile,
    required int count,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
  }) {
    final summary = profile.summary;
    final data = {
      'summary': {
        'playCount': summary.playCount,
        'qualifiedPlayCount': summary.qualifiedPlayCount,
        'totalListenedMinutes': summary.totalListenedMs ~/ 60000,
        'uniqueTrackCount': summary.uniqueTrackCount,
        'completionRate': summary.completionRate,
        'skipRate': summary.skipRate,
      },
      'topArtists': [
        for (final entry in profile.topArtists)
          {'artist': entry.artist, 'plays': entry.playCount},
      ],
      'topTracks': [
        for (final entry in profile.topTracks)
          {'title': entry.title, 'artist': entry.artist, 'plays': entry.playCount},
      ],
      'listeningByWeekdayHour': [
        for (final entry in profile.byWeekdayHour)
          {
            'weekday': entry.weekday,
            'hour': entry.hour,
            'minutes': entry.listenedMs ~/ 60000,
          },
      ],
      'sources': [
        for (final entry in profile.sources)
          {'source': entry.sourceKey, 'minutes': entry.listenedMs ~/ 60000},
      ],
      'recentEvents': [
        for (final event in profile.recentEvents)
          {
            'title': event.title,
            'artist': event.artist,
            'listenedSeconds': event.listenedMs ~/ 1000,
            'completed': event.endReason == PlayEventEndReason.completed,
          },
      ],
      'alreadyListened': profile.exclusionLabels,
    };

    final feedback = StringBuffer('本轮反馈：');
    if (skippedLabels.isEmpty && likedLabels.isEmpty) {
      feedback.write('无');
    } else {
      if (skippedLabels.isNotEmpty) {
        feedback.write('跳过了「${skippedLabels.take(20).join('、')}」');
      }
      if (likedLabels.isNotEmpty) {
        if (skippedLabels.isNotEmpty) feedback.write('；');
        feedback.write('收藏了「${likedLabels.take(20).join('、')}」');
      }
    }

    return '以下是我的听歌数据（JSON）：\n${jsonEncode(data)}\n\n'
        '$feedback\n'
        '${excludeLabels.isEmpty ? '' : '这些不要再推荐：${excludeLabels.take(50).join('、')}。\n'}'
        '请推荐 $count 首我可能喜欢的新歌（只输出 JSON）。';
  }

  /// 容错解析：优先与文本更靠前的 `{`/`[` 配对（`{"songs":[...]}` 或裸数组）。
  static List<AiRecommendation> parseRecommendations(
    String content, {
    int limit = 20,
  }) {
    dynamic decoded;
    final objectStart = content.indexOf('{');
    final listStart = content.indexOf('[');
    if (listStart >= 0 && (objectStart < 0 || listStart < objectStart)) {
      decoded = _tryDecode(content, listStart, ']');
    }
    if (decoded == null && objectStart >= 0) {
      decoded = _tryDecode(content, objectStart, '}');
    }
    if (decoded == null && listStart >= 0) {
      decoded = _tryDecode(content, listStart, ']');
    }
    final entries = decoded is Map ? decoded['songs'] : decoded;
    if (entries is! List) return const [];

    String textOf(dynamic value) => value?.toString().trim() ?? '';
    final result = <AiRecommendation>[];
    for (final entry in entries) {
      if (entry is String) {
        final title = entry.trim();
        if (title.isNotEmpty) result.add(AiRecommendation(title: title));
      } else if (entry is Map) {
        final title = [
          entry['title'],
          entry['name'],
          entry['song'],
        ].map(textOf).firstWhere((value) => value.isNotEmpty, orElse: () => '');
        if (title.isEmpty) continue;
        final artist = [
          entry['artist'],
          entry['singer'],
          entry['artists'],
        ].map(textOf).firstWhere((value) => value.isNotEmpty, orElse: () => '');
        result.add(AiRecommendation(
          title: title,
          artist: artist,
          reason: textOf(entry['reason']),
        ));
      }
      if (result.length >= limit) break;
    }
    return result;
  }

  static dynamic _tryDecode(String content, int start, String closeChar) {
    final end = content.lastIndexOf(closeChar);
    if (end <= start) return null;
    try {
      return jsonDecode(content.substring(start, end + 1));
    } catch (_) {
      return null;
    }
  }

  Future<
      ({
        List<ResolvedRecommendation> resolved,
        List<AiRecommendation> unresolved,
      })> _resolveAll(List<AiRecommendation> recommendations) async {
    if (recommendations.isEmpty) {
      return (
        resolved: <ResolvedRecommendation>[],
        unresolved: <AiRecommendation>[],
      );
    }
    final sources = _registry.descriptors
        .where((descriptor) => descriptor.enabled && descriptor.capabilities.search)
        .take(searchSourceLimit)
        .toList();
    final resolved = <ResolvedRecommendation>[];
    final unresolved = <AiRecommendation>[];
    for (var i = 0; i < recommendations.length; i += resolveConcurrency) {
      final chunk = recommendations.sublist(
        i,
        math.min(i + resolveConcurrency, recommendations.length),
      );
      final results = await Future.wait([
        for (final recommendation in chunk)
          _resolveOne(recommendation, sources),
      ]);
      for (var j = 0; j < chunk.length; j++) {
        final track = results[j];
        if (track == null) {
          unresolved.add(chunk[j]);
        } else {
          resolved.add(
            ResolvedRecommendation(source: chunk[j], track: track),
          );
        }
      }
    }
    return (resolved: resolved, unresolved: unresolved);
  }

  Future<Track?> _resolveOne(
    AiRecommendation recommendation,
    List<SourceDescriptor> sources,
  ) async {
    final keyword = [recommendation.title, recommendation.artist]
        .where((value) => value.trim().isNotEmpty)
        .join(' ');
    for (final descriptor in sources) {
      try {
        final result = await _catalog.search(
          descriptor.key,
          SearchQuery(keyword: keyword, limit: 10),
        );
        final best = pickBestMatch(recommendation, result.items);
        if (best != null) return await _withArtwork(descriptor, best);
      } catch (_) {
        // 单音源失败（引擎重启/网络）：换下一个；全失败判未解析。
      }
    }
    return null;
  }

  /// 封面补取：解析命中但无封面时经音源 `artwork()`（脚本 `pic` action /
  /// 内置平台原生取图）补一张；失败保持无封面（不阻塞解析）。
  Future<Track> _withArtwork(SourceDescriptor descriptor, Track track) async {
    if (track.artwork != null) return track;
    try {
      final artwork = await _registry.byKey(descriptor.key)?.artwork(track);
      final uri = artwork?.uri;
      if (uri == null || uri.toString().isEmpty) return track;
      return track.copyWith(artwork: artwork);
    } catch (_) {
      return track;
    }
  }

  /// 标题/艺人规范化打分（标题精确 0.6、包含 0.35；艺人互含 0.35；
  /// 总分 ≥0.6 才接受）。
  static Track? pickBestMatch(
    AiRecommendation recommendation,
    List<Track> items,
  ) {
    final targetTitle = normalizeAiText(recommendation.title);
    final targetArtist = normalizeAiText(recommendation.artist);
    if (targetTitle.isEmpty) return null;
    Track? best;
    var bestScore = 0.0;
    for (final track in items) {
      final title = normalizeAiText(track.title);
      final artist = normalizeAiText(track.artists.map((a) => a.name).join(' '));
      var score = 0.0;
      if (title == targetTitle) {
        score += 0.6;
      } else if (title.contains(targetTitle) || targetTitle.contains(title)) {
        score += 0.35;
      }
      if (targetArtist.isNotEmpty && artist.isNotEmpty) {
        if (artist.contains(targetArtist) || targetArtist.contains(artist)) {
          score += 0.35;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = track;
      }
    }
    return bestScore >= 0.6 ? best : null;
  }
}
