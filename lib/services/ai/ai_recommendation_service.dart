/// AI 推歌生成服务：画像 → 提示词 → LLM → 解析 → 本地搜索解析成可播放曲目。
///
/// 链路（「闭卷生成 + 本地解析」）：
/// 1. [TasteProfileBuilder] 按发送范围构建画像（收藏/歌单 opt-in）；
/// 2. [LlmClient] 单轮补全，要求纯 JSON；
/// 3. 容错解析（首 `{`…末 `}`，兼容数组/字符串条目）；
/// 4. 与已听排除清单、批内规范化去重；
/// 5. 按用户选择的找歌渠道（空 = 自动前 3）严格解析，失败项作为 unresolved
///    返回（页面折叠展示，可只重新搜索、不重新调 LLM）。
///
/// 预览与实际请求共用 [buildPrompt]：相同输入下预览文本 == 实际 userPrompt。
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
  /// [skippedLabels] / [likedLabels] 是本轮反馈（provider 已合并持久化记忆）；
  /// [excludeLabels] 是本次生成额外排除（如「换一首」时排除列表内已有曲目），
  /// 不进入反馈回流。[onProgress] 只在显式生成时传入；静默补歌不传。
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    AiPreferences preferences = AiPreferences.defaults,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
    AiGenerationCancelToken? cancelToken,
    void Function(AiDjProgress progress)? onProgress,
  });

  /// 预览与 [generate] 相同输入下实际会发送的提示词（不触发 LLM 调用）。
  Future<AiPrompt> buildPromptPreview({
    required int count,
    AiPreferences preferences = AiPreferences.defaults,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
  });

  /// 未解析项重新搜索（不重新调 LLM）；返回合并后的批次。
  Future<AiDjBatch> resolveUnresolved({
    required AiDjBatch batch,
    AiPreferences preferences = AiPreferences.defaults,
    AiGenerationCancelToken? cancelToken,
    void Function(AiDjProgress progress)? onProgress,
  });

  /// 连接测试（地址/Key/模型），失败抛 [SourceFailure]。
  Future<void> testConnection(LlmConfig config);

  /// 上行数据摘要（「本次发送的数据」；不触发 LLM 调用）。
  Future<AiUpstreamSummary> summarizeUpstream({
    AiPreferences preferences = AiPreferences.defaults,
  });
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

  /// 自动渠道数（偏好未选渠道时取音源页顺序前 N 个）。
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
  Future<AiUpstreamSummary> summarizeUpstream({
    AiPreferences preferences = AiPreferences.defaults,
  }) async {
    final profile = await _profileBuilder.build(preferences: preferences);
    final sources = _sourcesFor(preferences).sources;
    return AiUpstreamSummary(
      recentEvents:
          preferences.sections.contains(AiUpstreamSection.recentEvents)
              ? profile.recentEvents.length
              : 0,
      topArtists: profile.topArtists.length,
      topTracks: profile.topTracks.length,
      exclusions: profile.exclusionLabels.length,
      favorites: profile.favorites.length,
      playlists: [
        for (final playlist in profile.playlists) playlist.tracks.length,
      ].fold(0, (sum, value) => sum + value),
      sourceNames: [for (final source in sources) source.displayName],
    );
  }

  /// 预览与 [generate] 相同输入下实际会发送的提示词。
  @override
  Future<AiPrompt> buildPromptPreview({
    required int count,
    AiPreferences preferences = AiPreferences.defaults,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
  }) async {
    final profile = await _profileBuilder.build(preferences: preferences);
    return buildPrompt(
      profile: profile,
      preferences: preferences,
      count: count,
      skippedLabels: skippedLabels,
      likedLabels: likedLabels,
      excludeLabels: excludeLabels,
    );
  }

  /// 生成一批推荐（[count] 首上限）。
  @override
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    AiPreferences preferences = AiPreferences.defaults,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
    AiGenerationCancelToken? cancelToken,
    void Function(AiDjProgress progress)? onProgress,
  }) async {
    final startedAt = DateTime.now();
    void progress(AiDjPhase phase, {int done = 0, int total = 0}) {
      onProgress?.call(AiDjProgress(
        phase: phase,
        done: done,
        total: total,
        startedAt: startedAt,
      ));
    }

    progress(AiDjPhase.profile);
    _checkCancelled(cancelToken);
    final profile = await _profileBuilder.build(preferences: preferences);
    _checkCancelled(cancelToken);

    final prompt = buildPrompt(
      profile: profile,
      preferences: preferences,
      count: count,
      skippedLabels: skippedLabels,
      likedLabels: likedLabels,
      excludeLabels: excludeLabels,
    );

    progress(AiDjPhase.model);
    final raw = await _llm.complete(
      config: config,
      systemPrompt: prompt.systemPrompt,
      userPrompt: prompt.userPrompt,
      jsonMode: true,
    );
    _checkCancelled(cancelToken);

    final parsed = parseRecommendations(raw, limit: count);
    if (parsed.isEmpty) {
      throw const SourceFailure(
        kind: FailureKind.unknown,
        message: '模型未返回可解析的推荐',
        l10nKey: 'aiDjBadResponse',
        retryable: true,
      );
    }

    // 排除已听 / 收藏 / 歌单（provider 偏好 opened）+ 批内去重（规范化键）。
    final seen = Set<String>.of(profile.exclusionKeys);
    final candidates = <AiRecommendation>[];
    for (final recommendation in parsed) {
      final key = aiTrackKey(recommendation.title, recommendation.artist);
      if (key.replaceAll('|', '').isEmpty) continue;
      if (!seen.add(key)) continue;
      candidates.add(recommendation);
    }

    progress(AiDjPhase.resolving, total: candidates.length);
    final resolution = await _resolveAll(
      candidates,
      preferences: preferences,
      cancelToken: cancelToken,
      onResolved: (done) =>
          progress(AiDjPhase.resolving, done: done, total: candidates.length),
    );
    _checkCancelled(cancelToken);

    return AiDjBatch(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      items: resolution.resolved,
      unresolved: resolution.unresolved,
      generatedAt: DateTime.now(),
      preferences: preferences,
      rawResponse: raw,
      prompt: prompt,
      channelFallback: resolution.channelFallback,
    );
  }

  /// 未解析项重新搜索：只走本地搜索，不重新调 LLM；结果合并回原批次。
  @override
  Future<AiDjBatch> resolveUnresolved({
    required AiDjBatch batch,
    AiPreferences preferences = AiPreferences.defaults,
    AiGenerationCancelToken? cancelToken,
    void Function(AiDjProgress progress)? onProgress,
  }) async {
    if (batch.unresolved.isEmpty) return batch;
    final startedAt = DateTime.now();
    onProgress?.call(AiDjProgress(
      phase: AiDjPhase.resolving,
      total: batch.unresolved.length,
      startedAt: startedAt,
    ));
    final resolution = await _resolveAll(
      batch.unresolved,
      preferences: preferences,
      cancelToken: cancelToken,
      onResolved: (done) => onProgress?.call(AiDjProgress(
        phase: AiDjPhase.resolving,
        done: done,
        total: batch.unresolved.length,
        startedAt: startedAt,
      )),
    );
    _checkCancelled(cancelToken);
    final seen = {for (final item in batch.items) item.track.id.uri};
    final items = [
      ...batch.items,
      for (final item in resolution.resolved)
        if (seen.add(item.track.id.uri)) item,
    ];
    return batch.copyWith(
      items: items,
      unresolved: resolution.unresolved,
      channelFallback: resolution.channelFallback,
    );
  }

  /// 提示词：按发送范围裁剪的画像 JSON + 偏好 + 种子 + 本轮反馈 + 额外排除。
  static AiPrompt buildPrompt({
    required TasteProfile profile,
    required AiPreferences preferences,
    required int count,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
  }) {
    final sections = preferences.sections;
    final data = <String, dynamic>{};
    if (sections.contains(AiUpstreamSection.summary)) {
      final summary = profile.summary;
      data['summary'] = {
        'playCount': summary.playCount,
        'qualifiedPlayCount': summary.qualifiedPlayCount,
        'totalListenedMinutes': summary.totalListenedMs ~/ 60000,
        'uniqueTrackCount': summary.uniqueTrackCount,
        'completionRate': summary.completionRate,
        'skipRate': summary.skipRate,
      };
    }
    if (sections.contains(AiUpstreamSection.topArtists)) {
      data['topArtists'] = [
        for (final entry in profile.topArtists)
          {'artist': entry.artist, 'plays': entry.playCount},
      ];
    }
    if (sections.contains(AiUpstreamSection.topTracks)) {
      data['topTracks'] = [
        for (final entry in profile.topTracks)
          {
            'title': entry.title,
            'artist': entry.artist,
            'plays': entry.playCount
          },
      ];
    }
    if (sections.contains(AiUpstreamSection.timeAndSource)) {
      data['listeningByWeekdayHour'] = [
        for (final entry in profile.byWeekdayHour)
          {
            'weekday': entry.weekday,
            'hour': entry.hour,
            'minutes': entry.listenedMs ~/ 60000,
          },
      ];
      data['sources'] = [
        for (final entry in profile.sources)
          {'source': entry.sourceKey, 'minutes': entry.listenedMs ~/ 60000},
      ];
    }
    if (sections.contains(AiUpstreamSection.recentEvents)) {
      data['recentEvents'] = [
        for (final event in profile.recentEvents)
          {
            'title': event.title,
            'artist': event.artist,
            'listenedSeconds': event.listenedMs ~/ 1000,
            'completed': event.endReason == PlayEventEndReason.completed,
          },
      ];
    }
    if (sections.contains(AiUpstreamSection.listenedExclusions)) {
      data['alreadyListened'] = profile.exclusionLabels;
    }
    if (sections.contains(AiUpstreamSection.favorites)) {
      data['favorites'] = [
        for (final entry in profile.favorites)
          {'title': entry.title, 'artist': entry.artist},
      ];
    }
    if (sections.contains(AiUpstreamSection.playlists)) {
      data['playlists'] = [
        for (final playlist in profile.playlists)
          {
            'name': playlist.name,
            'tracks': [
              for (final track in playlist.tracks)
                {'title': track.title, 'artist': track.artist},
            ],
          },
      ];
    }

    final preferenceJson = <String, dynamic>{};
    if (preferences.styles.isNotEmpty) {
      preferenceJson['styles'] = [
        for (final style in preferences.styles) _styleText(style),
      ];
    }
    if (preferences.scenes.isNotEmpty) {
      preferenceJson['scenes'] = [
        for (final scene in preferences.scenes) _sceneText(scene),
      ];
    }
    if (preferences.languages.isNotEmpty) {
      preferenceJson['languages'] = [
        for (final language in preferences.languages) _languageText(language),
      ];
    }
    if (preferences.era != kAiEraAny) {
      preferenceJson['era'] = _eraText(preferences.era);
    }
    preferenceJson['exploration'] = _explorationText(preferences.exploration);
    preferenceJson['onlyUnheard'] = preferences.onlyUnheard;
    if (preferences.extraPrompt.trim().isNotEmpty) {
      preferenceJson['extra'] = preferences.extraPrompt.trim();
    }
    data['preferences'] = preferenceJson;

    final feedback = StringBuffer('本轮反馈：');
    if (skippedLabels.isEmpty &&
        likedLabels.isEmpty &&
        preferences.seeds.isEmpty) {
      feedback.write('无');
    } else {
      if (skippedLabels.isNotEmpty) {
        feedback.write('跳过了「${skippedLabels.take(20).join('、')}」');
      }
      if (likedLabels.isNotEmpty) {
        if (skippedLabels.isNotEmpty) feedback.write('；');
        feedback.write('收藏了「${likedLabels.take(20).join('、')}」');
      }
      if (preferences.seeds.isNotEmpty) {
        if (skippedLabels.isNotEmpty || likedLabels.isNotEmpty) {
          feedback.write('；');
        }
        feedback.write('多来点这种「${preferences.seeds.take(20).join('、')}」');
      }
    }

    final userPrompt = '以下是我的听歌数据（JSON）：\n${jsonEncode(data)}\n\n'
        '$feedback\n'
        '${excludeLabels.isEmpty ? '' : '这些不要再推荐：${excludeLabels.take(50).join('、')}。\n'}'
        '请推荐 $count 首我可能喜欢的新歌（只输出 JSON）。';
    return AiPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt);
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

  /// 解析渠道：空 = 音源页顺序前 3；已选 = 只按音源页顺序过滤所选，不兜底。
  ///
  /// 所选渠道全部不可用（停用 / 不支持搜索）时回退自动渠道并标记
  /// [channelFallback]，供偏好页提示。
  ({List<SourceDescriptor> sources, bool channelFallback}) _sourcesFor(
    AiPreferences preferences,
  ) {
    final searchable = [
      for (final descriptor in _orderedDescriptors())
        if (descriptor.enabled && descriptor.capabilities.search) descriptor,
    ];
    final auto = searchable.take(searchSourceLimit).toList();
    if (preferences.sourceKeys.isEmpty) {
      return (sources: auto, channelFallback: false);
    }
    final selectedKeys = preferences.sourceKeys.toSet();
    final selected = [
      for (final descriptor in searchable)
        if (selectedKeys.contains(descriptor.key)) descriptor,
    ];
    if (selected.isNotEmpty) {
      return (sources: selected, channelFallback: false);
    }
    return (
      sources: auto,
      channelFallback: auto.isNotEmpty,
    );
  }

  /// 音源页顺序（`order` 升序；同序保留注册表原始顺序）。
  List<SourceDescriptor> _orderedDescriptors() {
    final indexed = _registry.descriptors.asMap().entries.toList()
      ..sort((a, b) {
        final byOrder = a.value.order.compareTo(b.value.order);
        return byOrder != 0 ? byOrder : a.key.compareTo(b.key);
      });
    return [for (final entry in indexed) entry.value];
  }

  Future<
      ({
        List<ResolvedRecommendation> resolved,
        List<AiRecommendation> unresolved,
        bool channelFallback,
      })> _resolveAll(
    List<AiRecommendation> recommendations, {
    required AiPreferences preferences,
    AiGenerationCancelToken? cancelToken,
    void Function(int done)? onResolved,
  }) async {
    final sourceSelection = _sourcesFor(preferences);
    if (recommendations.isEmpty) {
      return (
        resolved: <ResolvedRecommendation>[],
        unresolved: <AiRecommendation>[],
        channelFallback: false,
      );
    }
    final resolved = <ResolvedRecommendation>[];
    final unresolved = <AiRecommendation>[];
    for (var i = 0; i < recommendations.length; i += resolveConcurrency) {
      _checkCancelled(cancelToken);
      final chunk = recommendations.sublist(
        i,
        math.min(i + resolveConcurrency, recommendations.length),
      );
      final results = await Future.wait([
        for (final recommendation in chunk)
          _resolveOne(recommendation, sourceSelection.sources),
      ]);
      _checkCancelled(cancelToken);
      for (var j = 0; j < chunk.length; j++) {
        final match = results[j];
        if (match == null) {
          unresolved.add(chunk[j]);
        } else {
          resolved.add(ResolvedRecommendation(
            source: chunk[j],
            track: match.track,
            sourceName: match.sourceName,
          ));
        }
      }
      onResolved
          ?.call(math.min(i + resolveConcurrency, recommendations.length));
    }
    return (
      resolved: resolved,
      unresolved: unresolved,
      channelFallback: sourceSelection.channelFallback,
    );
  }

  Future<({Track track, String sourceName})?> _resolveOne(
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
        if (best != null) {
          return (
            track: await _withArtwork(descriptor, best),
            sourceName: descriptor.displayName,
          );
        }
      } catch (_) {
        // 单音源失败（引擎重启/网络）：按用户渠道顺序换下一个；全失败判未解析。
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
      final artist =
          normalizeAiText(track.artists.map((a) => a.name).join(' '));
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

  static void _checkCancelled(AiGenerationCancelToken? token) {
    if (token?.isCancelled ?? false) {
      throw const SourceFailure(
        kind: FailureKind.cancelled,
        message: 'AI 推荐生成已取消',
        l10nKey: 'aiDjCancelled',
      );
    }
  }

  static String _styleText(String token) => switch (token) {
        'pop' => '流行',
        'rock' => '摇滚',
        'electronic' => '电子',
        'folk' => '民谣',
        'rap' => '说唱',
        'rnb' => 'R&B',
        'jazz' => '爵士',
        'classical' => '古典',
        'metal' => '金属',
        'acg' => 'ACG',
        'instrumental' => '纯音乐',
        'chineseStyle' => '国风',
        _ => token,
      };

  static String _sceneText(String token) => switch (token) {
        'commute' => '通勤',
        'focus' => '专注',
        'relax' => '放松',
        'workout' => '运动',
        'sleep' => '睡前',
        'weekend' => '周末',
        _ => token,
      };

  static String _languageText(String token) => switch (token) {
        'mandarin' => '华语',
        'cantonese' => '粤语',
        'english' => '英语',
        'japanese' => '日语',
        'korean' => '韩语',
        'instrumental' => '纯音乐',
        _ => token,
      };

  static String _eraText(String token) => switch (token) {
        kAiEraRecent3 => '近三年',
        kAiEra2010s => '2010s',
        kAiEra2000s => '2000s',
        kAiEraBefore90 => '90 年代及更早',
        _ => '不限',
      };

  static String _explorationText(String token) => switch (token) {
        kAiExplorationSafe => '稳妥（贴近常听风格）',
        kAiExplorationSurprise => '惊喜（大胆探索新风格）',
        _ => '均衡',
      };
}
