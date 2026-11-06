/// AI 推歌生成服务：画像 → 提示词 → LLM → 解析 → 本地搜索解析成可播放曲目。
///
/// 链路（「闭卷生成 + 本地解析」）：
/// 1. [TasteProfileBuilder] 按发送范围构建画像（收藏/歌单可关闭），
///    提示词用紧凑行格式、按应用语言切换文案；收藏始终参与本地排除；
/// 2. [LlmClient] 单轮补全，启用 JSON Output；
/// 3. 严格按 `{"songs":[...]}` 契约解析（非 JSON / 空正文不猜测，
///    空正文由客户端按 DeepSeek 官方建议重试）；
/// 4. 与已听排除清单、批内规范化去重；
/// 5. 按音源页顺序遍历全部可搜索渠道解析，失败项作为 unresolved 返回
///    （页面折叠展示，可只重新搜索、不重新调 LLM）；
/// 6. 解析成真实曲目后再按收藏稳定键 / 规范化键过滤一次，避免推荐已收藏歌。
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
import '../../domain/models/source.dart';
import '../../domain/models/track.dart';
import '../../domain/ports/source_registry.dart';
import 'ai_prompt_text.dart';
import 'ai_text.dart';
import 'llm_client.dart';
import 'taste_profile_builder.dart';

/// 推荐生成器接口：模式控制器只依赖这一层（测试可注入假实现）。
abstract interface class AiRecommendationGenerator {
  /// 生成一批推荐（[count] 首上限）。
  ///
  /// [skippedLabels] / [likedLabels] 是本轮反馈（provider 已合并持久化记忆）；
  /// [excludeLabels] 是本次生成额外排除（如「换一首」/上一批已有曲目），
  /// [excludeKeys] 是同一批排除项的规范化键，用于本地兜底过滤，不进入
  /// 反馈回流。[onProgress] 只在显式生成时传入；静默补歌不传。
  Future<AiDjBatch> generate({
    required LlmConfig config,
    required int count,
    AiPreferences preferences = AiPreferences.defaults,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
    List<String> excludeKeys = const [],
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
    required this._llm,
    required this._catalog,
    required this._registry,
    required this._profileBuilder,
    AiPromptLanguage Function()? promptLanguage,
    this.resolveConcurrency = 3,
    this.resolveHedgeDelay = const Duration(milliseconds: 250),
    this.resolveTimeout = const Duration(seconds: 10),
  }) : assert(!resolveHedgeDelay.isNegative),
       assert(resolveTimeout > Duration.zero),
       _promptLanguage = promptLanguage ?? (() => AiPromptLanguage.zh);

  final LlmClient _llm;
  final CatalogService _catalog;
  final SourceRegistry _registry;
  final TasteProfileBuilder _profileBuilder;

  /// 每次生成/预览时现取应用语言；设置页切换语言后下一次立即生效。
  final AiPromptLanguage Function() _promptLanguage;

  /// 解析并发（同时搜索的曲目数）。
  final int resolveConcurrency;

  /// 单曲找歌的对冲延时：先序音源超过该时长仍未返回时，提前启动下一个。
  ///
  /// 只影响「启动时机」，不改变优先级：命中必须按音源页顺序接受，后序源再快
  /// 也要等先序源确认无命中；先序源命中时取消后续启动（已发出的请求无法撤销，
  /// 结果直接丢弃）。
  final Duration resolveHedgeDelay;

  /// 单曲单音源探测的超时。
  ///
  /// 慢/挂起的音源不能把整批进度卡住：超时按该音源未命中处理，继续后续
  /// 音源并推进进度。底层请求无法取消，晚到结果由 [Future.timeout] 忽略。
  final Duration resolveTimeout;

  /// 连接测试（地址/Key/模型），失败抛 [SourceFailure]。
  @override
  Future<void> testConnection(LlmConfig config) {
    final copy = AiPromptCopy.of(_promptLanguage());
    return _llm.testConnection(
      config,
      systemPrompt: copy.testConnectionSystemPrompt,
      userPrompt: copy.testConnectionUserPrompt,
    );
  }

  /// 上行数据摘要：只统计条数，不发往任何服务。
  @override
  Future<AiUpstreamSummary> summarizeUpstream({
    AiPreferences preferences = AiPreferences.defaults,
  }) async {
    final profile = await _profileBuilder.build(preferences: preferences);
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
      language: _promptLanguage(),
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
    List<String> excludeKeys = const [],
    AiGenerationCancelToken? cancelToken,
    void Function(AiDjProgress progress)? onProgress,
  }) async {
    final startedAt = DateTime.now();
    void progress(
      AiDjPhase phase, {
      int done = 0,
      int total = 0,
      int resolved = 0,
      int unresolved = 0,
    }) {
      onProgress?.call(
        AiDjProgress(
          phase: phase,
          done: done,
          total: total,
          targetCount: count,
          resolved: resolved,
          unresolved: unresolved,
          startedAt: startedAt,
        ),
      );
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
      language: _promptLanguage(),
    );

    progress(AiDjPhase.model);
    // 不传 max_tokens：DeepSeek 等推理模型会把它计入思维链，固定预算容易
    // 在 JSON 输出前耗尽；交给服务端默认预算更稳。
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

    // 排除已听 / 收藏 / 歌单（provider 偏好 opened）+ 上一批/队列（provider
    // 传入的规范化键）+ 批内去重。提示词里的 [本批排除] 只负责让模型主动
    // 避开；本地兜底保证模型忽略时也不会重复。
    final seen = Set<String>.of(profile.exclusionKeys)..addAll(excludeKeys);
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
      onProgress: (done, resolved, unresolved) => progress(
        AiDjPhase.resolving,
        done: done,
        total: candidates.length,
        resolved: resolved,
        unresolved: unresolved,
      ),
    );
    _checkCancelled(cancelToken);

    return AiDjBatch(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      // 标题/歌手去重拦不住「同一首歌换了音源写法」：解析成真实曲目后
      // 再按收藏稳定键 / 规范化键过滤一次。
      items: _dropFavorited(
        resolution.resolved,
        trackKeys: profile.favoriteTrackKeys,
        labelKeys: profile.favoriteLabelKeys,
      ),
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
    final targetCount = batch.unresolved.length;
    onProgress?.call(
      AiDjProgress(
        phase: AiDjPhase.resolving,
        total: targetCount,
        targetCount: targetCount,
        startedAt: startedAt,
      ),
    );
    // 上次未找到的曲目这次可能解析到已收藏的版本：重试同样做二次过滤，
    // 否则「重新找一次」会把收藏里的歌重新塞回列表。
    final favorites = await _profileBuilder.favoriteExclusions();
    final resolution = await _resolveAll(
      batch.unresolved,
      cancelToken: cancelToken,
      onProgress: (done, resolved, unresolved) => onProgress?.call(
        AiDjProgress(
          phase: AiDjPhase.resolving,
          done: done,
          total: targetCount,
          targetCount: targetCount,
          resolved: resolved,
          unresolved: unresolved,
          startedAt: startedAt,
        ),
      ),
    );
    _checkCancelled(cancelToken);
    final seen = {for (final item in batch.items) item.track.id.uri};
    final items = [
      ...batch.items,
      for (final item in _dropFavorited(
        resolution.resolved,
        trackKeys: favorites.trackKeys,
        labelKeys: favorites.labelKeys,
      ))
        if (seen.add(item.track.id.uri)) item,
    ];
    return batch.copyWith(items: items, unresolved: resolution.unresolved);
  }

  /// 提示词里时段/反馈/本批排除的展示上限（token 预算）。
  static const int promptTimeSlotLimit = 12;
  static const int promptFeedbackLimit = 20;
  static const int promptExcludeLimit = 50;

  /// 单条文本的长度上限：防止异常长的歌名/歌手破坏提示词结构。
  static const int _promptTitleLimit = 80;
  static const int _promptArtistLimit = 60;
  static const int _promptLabelLimit = 100;
  static const int _promptPlaylistNameLimit = 40;

  /// 提示词：按发送范围裁剪的紧凑行画像 + 偏好 + 种子 + 本轮反馈 + 额外排除。
  ///
  /// 格式选择紧凑行而不是逐条 JSON：同样的信息少大量重复 key，透明度弹窗仍
  /// 可直接阅读。system 放输出契约与数据边界，user 放数据、约束与请求。
  static AiPrompt buildPrompt({
    required TasteProfile profile,
    required AiPreferences preferences,
    required int count,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
    AiPromptLanguage language = AiPromptLanguage.zh,
  }) {
    final copy = AiPromptCopy.of(language);
    final sections = preferences.sections;
    final buffer = StringBuffer();

    if (sections.contains(AiUpstreamSection.summary)) {
      final summary = profile.summary;
      if (summary.playCount == 0) {
        buffer.writeln('${copy.summaryLabel} ${copy.noListeningData}');
      } else {
        buffer.writeln(
          '${copy.summaryLabel} ${['${copy.summaryPlays} ${summary.playCount}', '${copy.summaryCompletion} ${_percent(summary.completionRate)}', '${copy.summarySkip} ${_percent(summary.skipRate)}'].join(copy.fieldSeparator)}',
        );
      }
    }

    final preferenceParts = <String>[];
    if (preferences.styles.isNotEmpty) {
      preferenceParts.add(
        '${copy.preferencesStyles} '
        '${[for (final style in preferences.styles) copy.styleText(style)].join('/')}',
      );
    }
    if (preferences.scenes.isNotEmpty) {
      preferenceParts.add(
        '${copy.preferencesScenes} '
        '${[for (final scene in preferences.scenes) copy.sceneText(scene)].join('/')}',
      );
    }
    if (preferences.languages.isNotEmpty) {
      preferenceParts.add(
        '${copy.preferencesLanguages} '
        '${[for (final language in preferences.languages) copy.languageText(language)].join('/')}',
      );
    }
    if (preferences.era != kAiEraAny) {
      preferenceParts.add(
        '${copy.preferencesEra} ${copy.eraText(preferences.era)}',
      );
    }
    preferenceParts.add(
      '${copy.preferencesExploration} '
      '${copy.explorationText(preferences.exploration)}',
    );
    preferenceParts.add(copy.onlyUnheardText(preferences.onlyUnheard));
    buffer.writeln(
      '${copy.preferencesLabel} ${preferenceParts.join(copy.fieldSeparator)}',
    );

    if (sections.contains(AiUpstreamSection.topArtists)) {
      _writeSection(buffer, copy.topArtistsLabel, [
        for (final entry in profile.topArtists)
          _text(entry.artist, maxLength: _promptArtistLimit),
      ], copy.itemSeparator);
    }
    if (sections.contains(AiUpstreamSection.topTracks)) {
      _writeSection(buffer, copy.topTracksLabel, [
        for (final entry in profile.topTracks) _song(entry.title, entry.artist),
      ], copy.itemSeparator);
    }
    if (sections.contains(AiUpstreamSection.timeAndSource) &&
        profile.byWeekdayHour.isNotEmpty) {
      final topSlots = [...profile.byWeekdayHour]
        ..sort((a, b) {
          final byMinutes = b.listenedMs.compareTo(a.listenedMs);
          if (byMinutes != 0) return byMinutes;
          final byDay = a.weekday.compareTo(b.weekday);
          return byDay != 0 ? byDay : a.hour.compareTo(b.hour);
        });
      final slots = topSlots.take(promptTimeSlotLimit).toList()
        ..sort((a, b) {
          final byDay = a.weekday.compareTo(b.weekday);
          return byDay != 0 ? byDay : a.hour.compareTo(b.hour);
        });
      _writeSection(buffer, copy.listeningHoursLabel, [
        for (final slot in slots) copy.timeSlot(slot.weekday, slot.hour),
      ], copy.itemSeparator);
    }
    if (sections.contains(AiUpstreamSection.favorites)) {
      _writeSection(buffer, copy.favoritesLabel, [
        for (final entry in profile.favorites) _song(entry.title, entry.artist),
      ], copy.itemSeparator);
    }
    if (sections.contains(AiUpstreamSection.playlists)) {
      final playlistItems = <String>[];
      for (final playlist in profile.playlists) {
        final name = _text(playlist.name, maxLength: _promptPlaylistNameLimit);
        if (name.isEmpty) continue;
        final tracks = [
          for (final track in playlist.tracks) _song(track.title, track.artist),
        ].where((track) => track.isNotEmpty).toList();
        if (tracks.isEmpty) continue;
        playlistItems.add('$name: ${tracks.join(copy.itemSeparator)}');
      }
      _writeSection(
        buffer,
        copy.playlistsLabel,
        playlistItems,
        copy.playlistSeparator,
      );
    }
    // 最近播放与已听清单合并成一份去重列表：两者都是「听过」，分开发只会
    // 让同一首歌重复出现。最近播放优先，秒数/完播标记不再发送。
    final heard = _cleanLabels([
      if (sections.contains(AiUpstreamSection.recentEvents))
        for (final event in profile.recentEvents.take(
          TasteProfileBuilder.recentEventLimit,
        ))
          _song(event.title, event.artist),
      if (sections.contains(AiUpstreamSection.listenedExclusions))
        ...profile.exclusionLabels.take(
          TasteProfileBuilder.exclusionPromptLimit,
        ),
    ]).take(TasteProfileBuilder.exclusionPromptLimit).toList();
    _writeSection(buffer, copy.alreadyHeardLabel, heard, copy.itemSeparator);

    final skipped = _cleanLabels(skippedLabels.take(promptFeedbackLimit));
    final liked = _cleanLabels(likedLabels.take(promptFeedbackLimit));
    final seeds = _cleanLabels(preferences.seeds.take(promptFeedbackLimit));
    final excludes = _cleanLabels(excludeLabels.take(promptExcludeLimit));
    _writeSection(buffer, copy.skippedLabel, skipped, copy.itemSeparator);
    _writeSection(buffer, copy.likedLabel, liked, copy.itemSeparator);
    _writeSection(buffer, copy.moreLikeThisLabel, seeds, copy.itemSeparator);
    _writeSection(buffer, copy.excludeBatchLabel, excludes, copy.itemSeparator);

    final extra = _text(
      preferences.extraPrompt,
      maxLength: AiPreferences.extraPromptLimit,
    );
    if (extra.isNotEmpty) {
      buffer.writeln('${copy.extraRequestLabel} $extra');
    }

    buffer.writeln();
    buffer.writeln(
      copy.requirementsLine(
        onlyUnheard: preferences.onlyUnheard,
        hasTopTracks:
            sections.contains(AiUpstreamSection.topTracks) &&
            profile.topTracks.isNotEmpty,
        hasHeard: heard.isNotEmpty,
        hasFavorites:
            sections.contains(AiUpstreamSection.favorites) &&
            profile.favorites.isNotEmpty,
        hasPlaylists:
            sections.contains(AiUpstreamSection.playlists) &&
            profile.playlists.isNotEmpty,
        hasSkipped: skipped.isNotEmpty,
        hasLiked: liked.isNotEmpty,
        hasSeeds: seeds.isNotEmpty,
        hasExcludeBatch: excludes.isNotEmpty,
        hasExtraRequest: extra.isNotEmpty,
        maxPerArtist: perArtistLimit(count),
      ),
    );
    buffer.writeln(copy.request(count));
    return AiPrompt(
      systemPrompt: copy.systemPrompt,
      userPrompt: buffer.toString().trim(),
    );
  }

  /// 同歌手数量上限：批次越大越放宽，避免 96 首被 2 首/歌手卡死。
  static int perArtistLimit(int count) =>
      count <= kAiDefaultBatchSize ? 2 : (count <= 48 ? 3 : 4);

  static void _writeSection(
    StringBuffer buffer,
    String label,
    Iterable<String> items,
    String separator,
  ) {
    final values = <String>[];
    for (final item in items) {
      if (item.isNotEmpty) values.add(item);
    }
    if (values.isEmpty) return;
    buffer.writeln('$label ${values.join(separator)}');
  }

  static String _song(String title, String artist) {
    final cleanTitle = _text(title, maxLength: _promptTitleLimit);
    if (cleanTitle.isEmpty) return '';
    final cleanArtist = _text(artist, maxLength: _promptArtistLimit);
    return cleanArtist.isEmpty ? cleanTitle : '$cleanTitle - $cleanArtist';
  }

  static List<String> _cleanLabels(Iterable<String> labels) {
    final seen = <String>{};
    final result = <String>[];
    for (final label in labels) {
      final text = _text(label, maxLength: _promptLabelLimit);
      if (text.isEmpty || !seen.add(text)) continue;
      result.add(text);
    }
    return result;
  }

  /// 压成单行并限长：歌名/歌手里的换行会破坏「一段一行」的结构。
  static String _text(String value, {required int maxLength}) {
    final collapsed = value
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (collapsed.length <= maxLength) return collapsed;
    return '${collapsed.substring(0, maxLength)}…';
  }

  static String _percent(double value) => '${(value * 100).round()}%';

  /// 解析 JSON Output：只接受提示词约定的 `{"songs":[...]}`。
  ///
  /// DeepSeek JSON Output 会保证 content 是合法 JSON（无法识别的内容会被
  /// 替换成空格），所以不再从正文里提取/修补 JSON；空正文由 [LlmClient]
  /// 按官方建议重试。
  static List<AiRecommendation> parseRecommendations(
    String content, {
    int limit = 20,
  }) {
    if (limit <= 0) return const [];
    final text = content.trim();
    if (text.isEmpty) return const [];

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    final songs = decoded['songs'];
    if (songs is! List) return const [];

    final result = <AiRecommendation>[];
    for (final entry in songs) {
      if (entry is! Map) continue;
      final title = entry['title']?.toString().trim() ?? '';
      if (title.isEmpty) continue;
      result.add(
        AiRecommendation(
          title: title,
          artist: entry['artist']?.toString().trim() ?? '',
          reason: entry['reason']?.toString().trim() ?? '',
        ),
      );
      if (result.length >= limit) break;
    }
    return result;
  }

  /// 解析渠道：按音源页顺序遍历全部可搜索渠道，不设数量上限。
  List<SourceDescriptor> _searchableSources() =>
      aiDjSearchableSourcesInPageOrder(_registry.descriptors);

  Future<
    ({List<ResolvedRecommendation> resolved, List<AiRecommendation> unresolved})
  >
  _resolveAll(
    List<AiRecommendation> recommendations, {
    AiGenerationCancelToken? cancelToken,
    void Function(int done, int resolved, int unresolved)? onProgress,
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
    var done = 0;
    var resolvedCount = 0;
    var unresolvedCount = 0;
    var lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);

    // 每首完成就回调，但最多 10Hz：本地搜索很快时不必为每一首都重建卡片。
    // 最后一首强制发送，保证进度一定到 total。
    void report({required bool force}) {
      final now = DateTime.now();
      if (!force &&
          now.difference(lastProgressAt) < const Duration(milliseconds: 100)) {
        return;
      }
      lastProgressAt = now;
      onProgress?.call(done, resolvedCount, unresolvedCount);
    }

    for (var i = 0; i < recommendations.length; i += resolveConcurrency) {
      _checkCancelled(cancelToken);
      final chunk = recommendations.sublist(
        i,
        math.min(i + resolveConcurrency, recommendations.length),
      );
      final results = await Future.wait([
        for (final recommendation in chunk)
          _resolveOne(recommendation, sources).then((match) {
            done++;
            if (match == null) {
              unresolvedCount++;
            } else {
              resolvedCount++;
            }
            report(force: done == recommendations.length);
            return match;
          }),
      ]);
      _checkCancelled(cancelToken);
      for (var j = 0; j < chunk.length; j++) {
        final match = results[j];
        if (match == null) {
          unresolved.add(chunk[j]);
        } else {
          resolved.add(
            ResolvedRecommendation(
              source: chunk[j],
              track: match.track,
              sourceName: match.sourceName,
            ),
          );
        }
      }
    }
    return (resolved: resolved, unresolved: unresolved);
  }

  /// 丢掉解析结果里已经在收藏中的曲目。
  ///
  /// 两个判据互补：
  /// - `sourceKey:songId`：同音源精确命中，标题/歌手写法无关；
  /// - `规范化(title)|规范化(artist)`：同一首歌换音源时仍能拦住。
  static List<ResolvedRecommendation> _dropFavorited(
    List<ResolvedRecommendation> items, {
    required Set<String> trackKeys,
    required Set<String> labelKeys,
  }) {
    if (trackKeys.isEmpty && labelKeys.isEmpty) return items;
    return [
      for (final item in items)
        if (!trackKeys.contains(
              '${item.track.id.sourceKey}:${item.track.id.id}',
            ) &&
            !labelKeys.contains(
              aiTrackKey(item.track.title, item.track.artistLabel),
            ))
          item,
    ];
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
    final keyword = [
      recommendation.title,
      recommendation.artist,
    ].where((value) => value.trim().isNotEmpty).join(' ');

    final results = List<({Track track, String sourceName})?>.filled(
      sources.length,
      null,
    );
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
      final result = await _catalog
          .search(descriptor.key, SearchQuery(keyword: keyword, limit: 10))
          .timeout(resolveTimeout);
      final best = pickBestMatch(recommendation, result.items);
      if (best == null) return null;
      return (
        track: await _withArtwork(descriptor, best),
        sourceName: descriptor.displayName,
      );
    } catch (_) {
      // 单音源失败 / 超时（引擎重启/网络）：按用户渠道顺序换下一个；
      // 全失败判未解析。超时不能让整批进度卡在这个音源上。
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
      final artist = normalizeAiText(
        track.artists.map((a) => a.name).join(' '),
      );
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
}
