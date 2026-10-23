/// AI 推歌生成服务：画像 → 提示词 → LLM → 解析 → 本地搜索解析成可播放曲目。
///
/// 链路（「闭卷生成 + 本地解析」）：
/// 1. [TasteProfileBuilder] 按发送范围构建画像（收藏/歌单 opt-in）；
/// 2. [LlmClient] 单轮补全，要求纯 JSON；
/// 3. 容错解析（首 `{`…末 `}`，兼容数组/字符串条目）；
/// 4. 与已听排除清单、批内规范化去重；
/// 5. 按音源页顺序遍历全部可搜索渠道解析，失败项作为 unresolved 返回
///    （页面折叠展示，可只重新搜索、不重新调 LLM）。
///
/// 预览与实际请求共用 [buildPrompt]：相同输入下预览文本 == 实际 userPrompt。
library;

import 'dart:async';
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
    this.resolveConcurrency = 3,
    this.resolveHedgeDelay = const Duration(milliseconds: 250),
  })  : assert(!resolveHedgeDelay.isNegative),
        _llm = llm,
        _catalog = catalog,
        _registry = registry,
        _profileBuilder = profileBuilder;

  final LlmClient _llm;
  final CatalogService _catalog;
  final SourceRegistry _registry;
  final TasteProfileBuilder _profileBuilder;

  /// 解析并发（同时搜索的曲目数）。
  final int resolveConcurrency;

  /// 单曲找歌的对冲延时：先序音源超过该时长仍未返回时，提前启动下一个。
  ///
  /// 只影响「启动时机」，不改变优先级：命中必须按音源页顺序接受，后序源再快
  /// 也要等先序源确认无命中；先序源命中时取消后续启动（已发出的请求无法撤销，
  /// 结果直接丢弃）。
  final Duration resolveHedgeDelay;

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
    final sources = _searchableSources();
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

  /// 解析渠道：按音源页顺序遍历全部可搜索渠道，不设数量上限。
  List<SourceDescriptor> _searchableSources() =>
      aiDjSearchableSourcesInPageOrder(_registry.descriptors);

  Future<
      ({
        List<ResolvedRecommendation> resolved,
        List<AiRecommendation> unresolved,
      })> _resolveAll(
    List<AiRecommendation> recommendations, {
    AiGenerationCancelToken? cancelToken,
    void Function(int done)? onResolved,
  }) async {
    final sources = _searchableSources();
    if (recommendations.isEmpty) {
      return (
        resolved: <ResolvedRecommendation>[],
        unresolved: <AiRecommendation>[],
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
          _resolveOne(recommendation, sources),
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
    );
  }

  /// 按音源页顺序找歌：对冲启动 + 严格优先级接受。
  ///
  /// 串行探测时，一个迟迟不返回的音源会挡住后面所有渠道；这里先启动 index 0，
  /// 超过 [resolveHedgeDelay] 仍未完成才启动 index 1，之后每个延时窗口再放一个。
  /// 已启动音源全部快速完成且未命中时立即启动下一个（不白等延时），因此正常
  /// 快速返回的场景与串行行为一致。
  ///
  /// 命中按 index 顺序接受：index i 的结果只有在其前面所有音源都已完成且未命中
  /// 后才能返回；先序源仍可能在途时继续等待。任一音源命中后不再启动新音源，
  /// 已在途的探测结果直接丢弃。
  Future<({Track track, String sourceName})?> _resolveOne(
    AiRecommendation recommendation,
    List<SourceDescriptor> sources,
  ) {
    if (sources.isEmpty) return Future.value(null);
    final keyword = [recommendation.title, recommendation.artist]
        .where((value) => value.trim().isNotEmpty)
        .join(' ');

    final results =
        List<({Track track, String sourceName})?>.filled(sources.length, null);
    final completed = List<bool>.filled(sources.length, false);
    final completer = Completer<({Track track, String sourceName})?>();
    Timer? hedge;
    var next = 0;
    var settled = false;

    void finish(({Track track, String sourceName})? match) {
      if (settled) return;
      settled = true;
      hedge?.cancel();
      completer.complete(match);
    }

    // launch / schedule 互相调用（探测完成前排下一个），用 late 变量声明。
    late void Function() launch;
    late void Function() schedule;

    void drain() {
      if (settled) return;
      var i = 0;
      for (; i < next; i++) {
        if (!completed[i]) break;
        final match = results[i];
        if (match != null) {
          finish(match);
          return;
        }
      }
      if (i < next) {
        // 还有在途音源：若后面已有候选命中，就停掉计时器等先序确认；
        // 否则保留计时器，到下个窗口再对冲放行下一个。
        for (var j = i; j < next; j++) {
          if (completed[j] && results[j] != null) {
            hedge?.cancel();
            return;
          }
        }
        return;
      }
      if (next >= sources.length) {
        finish(null);
        return;
      }
      // 已启动音源都没有命中：继续下一个不必再等对冲延时。
      hedge?.cancel();
      launch();
      schedule();
    }

    void record(int index, ({Track track, String sourceName})? match) {
      if (settled) return;
      results[index] = match;
      completed[index] = true;
      drain();
    }

    launch = () {
      if (settled || next >= sources.length) return;
      final index = next++;
      _probeSource(recommendation, keyword, sources[index]).then(
        (match) => record(index, match),
        // 探测内部已兜底；双保险，保证被丢弃的在途失败也不会冒泡。
        onError: (Object _) => record(index, null),
      );
    };

    schedule = () {
      hedge?.cancel();
      if (settled || next >= sources.length) return;
      hedge = Timer(resolveHedgeDelay, () {
        if (settled || next >= sources.length) return;
        launch();
        schedule();
      });
    };

    launch();
    schedule();
    return completer.future;
  }

  /// 单个音源探测；异常按「该音源无命中」处理，保证丢弃结果或在途失败不冒泡。
  Future<({Track track, String sourceName})?> _probeSource(
    AiRecommendation recommendation,
    String keyword,
    SourceDescriptor descriptor,
  ) async {
    try {
      final result = await _catalog.search(
        descriptor.key,
        SearchQuery(keyword: keyword, limit: 10),
      );
      final best = pickBestMatch(recommendation, result.items);
      if (best == null) return null;
      return (
        track: await _withArtwork(descriptor, best),
        sourceName: descriptor.displayName,
      );
    } catch (_) {
      // 单音源失败（引擎重启/网络）：按用户渠道顺序换下一个；全失败判未解析。
      return null;
    }
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
