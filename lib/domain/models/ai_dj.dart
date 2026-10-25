/// AI 推歌领域模型：LLM 配置 / 推荐项 / 批次 / 偏好 / 反馈记忆。
///
/// 纯 Dart（无 Flutter/provider 依赖）；提示词构建与网络调用在
/// `lib/services/ai/**`，模式状态机在 `lib/providers/ai_dj_provider.dart`。
library;

import 'source.dart';
import 'track.dart';

/// LLM 连接配置（OpenAI-compatible Chat Completions 协议）。
///
/// `apiKey` 只写安全存储、不进日志/导出；`baseUrl` 允许带或不带
/// `/v1` 后缀（请求地址归一在 `LlmClient.chatCompletionsUri`）。
class LlmConfig {
  final String baseUrl;
  final String apiKey;
  final String model;

  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  /// 三项都非空才可用于请求。
  bool get isComplete =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  LlmConfig copyWith({String? baseUrl, String? apiKey, String? model}) =>
      LlmConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        model: model ?? this.model,
      );

  @override
  String toString() => 'LlmConfig($baseUrl, $model)';

  /// 脱敏展示（设置页/日志）。
  String get maskedApiKey {
    final key = apiKey.trim();
    if (key.isEmpty) return '';
    if (key.length <= 8) return '••••';
    return '${key.substring(0, 4)}••••${key.substring(key.length - 4)}';
  }
}

/// 内置服务商预设（「自定义」= baseUrl/model 自行填写，无预设）。
class LlmProviderPreset {
  final String name;
  final String baseUrl;
  final String model;

  const LlmProviderPreset({
    required this.name,
    required this.baseUrl,
    required this.model,
  });

  static const List<LlmProviderPreset> builtIn = [
    LlmProviderPreset(
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-flash',
    ),
    LlmProviderPreset(
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-6-luna',
    ),
  ];
}

/// LLM 输出的一条推荐（未解析为可播放曲目）。
class AiRecommendation {
  final String title;
  final String artist;
  final String reason;

  const AiRecommendation({
    required this.title,
    this.artist = '',
    this.reason = '',
  });

  /// 人读标签（反馈回流 / 跳过排除用）。
  String get label => artist.isEmpty ? title : '$title - $artist';

  @override
  String toString() => 'AiRecommendation($label)';
}

/// 已解析的推荐：LLM 输出 + 本地搜索命中的可播放曲目。
class ResolvedRecommendation {
  final AiRecommendation source;
  final Track track;

  /// 命中的找歌渠道展示名（历史恢复保留；AI 页面不再展示）。
  final String sourceName;

  const ResolvedRecommendation({
    required this.source,
    required this.track,
    this.sourceName = '',
  });

  /// 行尾来源：渠道名缺省时退回音源 key，不显示空标签。
  String get resolvedSourceName =>
      sourceName.trim().isEmpty ? track.id.sourceKey : sourceName.trim();
}

/// 一批推荐（含解析失败项，页面折叠展示）。
///
/// 语义：**历史推荐**中的一批；同一时刻只有一批是「当前推荐」（active），
/// 自动补歌与手动补批只写历史，不切换 active。
class AiDjBatch {
  final String id;

  final List<ResolvedRecommendation> items;

  /// 本地搜索未能解析的推荐（不进入队列）。
  final List<AiRecommendation> unresolved;

  final DateTime generatedAt;

  /// 这批从哪个显式/静默动作产生（历史标记）。
  final AiDjOrigin origin;

  /// 生成时的偏好快照（未记录时可为空）。
  final AiPreferences? preferences;

  /// LLM 原始返回：**只存内存，不落盘、不打日志**。
  final String? rawResponse;

  /// 实际发送的提示词：只存内存（透明化区块展示）。
  final AiPrompt? prompt;

  const AiDjBatch({
    this.id = '',
    required this.items,
    this.unresolved = const [],
    required this.generatedAt,
    this.origin = AiDjOrigin.refresh,
    this.preferences,
    this.rawResponse,
    this.prompt,
  });

  bool get isEmpty => items.isEmpty;

  AiDjBatch copyWith({
    String? id,
    List<ResolvedRecommendation>? items,
    List<AiRecommendation>? unresolved,
    DateTime? generatedAt,
    AiDjOrigin? origin,
    AiPreferences? preferences,
    String? rawResponse,
    AiPrompt? prompt,
  }) =>
      AiDjBatch(
        id: id ?? this.id,
        items: items ?? this.items,
        unresolved: unresolved ?? this.unresolved,
        generatedAt: generatedAt ?? this.generatedAt,
        origin: origin ?? this.origin,
        preferences: preferences ?? this.preferences,
        rawResponse: rawResponse ?? this.rawResponse,
        prompt: prompt ?? this.prompt,
      );
}

/// 批次来源（历史标记）。
enum AiDjOrigin {
  /// 用户显式「生成推荐 / 换一批」，会成为 active。
  refresh('refresh'),

  /// 队列低水位静默补歌：只进历史与队列。
  autoFeed('autoFeed'),

  /// 用户显式「补一批到队尾」：只进历史与队列，可显示进度。
  manualFeed('manualFeed');

  const AiDjOrigin(this.storageValue);

  final String storageValue;

  /// 未知 / 缺失值按 [refresh] 处理（历史标记只影响展示）。
  static AiDjOrigin fromStorage(Object? value) {
    for (final origin in values) {
      if (origin.storageValue == value) return origin;
    }
    return AiDjOrigin.refresh;
  }
}

/// 轻量历史索引项（历史页首屏只读它，曲目按需加载）。
class AiDjHistoryEntry {
  final String id;
  final DateTime generatedAt;
  final int itemCount;
  final int unresolvedCount;
  final AiDjOrigin origin;
  final AiPreferences? preferences;

  const AiDjHistoryEntry({
    required this.id,
    required this.generatedAt,
    required this.itemCount,
    required this.unresolvedCount,
    required this.origin,
    this.preferences,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'generatedAt': generatedAt.millisecondsSinceEpoch,
        'itemCount': itemCount,
        'unresolvedCount': unresolvedCount,
        'origin': origin.storageValue,
        if (preferences != null) 'preferences': preferences!.toJson(),
      };

  static AiDjHistoryEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return AiDjHistoryEntry(
      id: id,
      generatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['generatedAt'] as num?)?.toInt() ?? 0,
      ),
      itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
      unresolvedCount: (json['unresolvedCount'] as num?)?.toInt() ?? 0,
      origin: AiDjOrigin.fromStorage(json['origin']),
      preferences: AiPreferences.tryFromJson(json['preferences']),
    );
  }
}

/// 生成进度阶段（仅显式操作；静默补歌不产生进度）。
enum AiDjPhase { profile, model, resolving }

/// 一次显式生成的进度快照。
class AiDjProgress {
  final AiDjPhase phase;

  /// 解析阶段已完成 / 总数；profile / model 阶段均为 0。
  final int done;
  final int total;
  final DateTime startedAt;

  const AiDjProgress({
    required this.phase,
    required this.startedAt,
    this.done = 0,
    this.total = 0,
  });

  AiDjProgress copyWith({AiDjPhase? phase, int? done, int? total}) =>
      AiDjProgress(
        phase: phase ?? this.phase,
        done: done ?? this.done,
        total: total ?? this.total,
        startedAt: startedAt,
      );

  /// 解析进度（0..1）；profile / model 或总数为 0 时为 null。
  double? get fraction {
    if (total <= 0) return null;
    return (done / total).clamp(0.0, 1.0);
  }
}

/// 显式生成的取消令牌（服务层在阶段边界与解析分片之间检查）。
class AiGenerationCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 提示词快照（预览与实际请求共用同一份构建结果）。
class AiPrompt {
  final String systemPrompt;
  final String userPrompt;

  const AiPrompt({required this.systemPrompt, required this.userPrompt});

  /// 复制/展示用全文。
  String get combined => '$systemPrompt\n\n$userPrompt';

  @override
  bool operator ==(Object other) =>
      other is AiPrompt &&
      other.systemPrompt == systemPrompt &&
      other.userPrompt == userPrompt;

  @override
  int get hashCode => Object.hash(systemPrompt, userPrompt);
}

/// 发送范围（偏好页勾选；默认前六项开、收藏/歌单关）。
enum AiUpstreamSection {
  summary('summary'),
  topArtists('topArtists'),
  topTracks('topTracks'),
  timeAndSource('timeAndSource'),
  recentEvents('recentEvents'),
  listenedExclusions('listenedExclusions'),
  favorites('favorites'),
  playlists('playlists');

  const AiUpstreamSection(this.storageValue);

  final String storageValue;

  static AiUpstreamSection? fromStorage(Object? value) {
    for (final section in values) {
      if (section.storageValue == value) return section;
    }
    return null;
  }
}

/// 默认发送范围：现有统计项全开，收藏与自建歌单默认关（opt-in）。
const Set<AiUpstreamSection> kAiDefaultUpstreamSections = {
  AiUpstreamSection.summary,
  AiUpstreamSection.topArtists,
  AiUpstreamSection.topTracks,
  AiUpstreamSection.timeAndSource,
  AiUpstreamSection.recentEvents,
  AiUpstreamSection.listenedExclusions,
};

/// 批次大小选项（默认 10）。
const List<int> kAiBatchSizeOptions = [10, 20, 30, 50];

/// 默认每批数量。
const int kAiDefaultBatchSize = 10;

/// 探索度选项（稳定 token；文案在 l10n）。
const String kAiExplorationSafe = 'safe';
const String kAiExplorationBalanced = 'balanced';
const String kAiExplorationSurprise = 'surprise';
const List<String> kAiExplorationOptions = [
  kAiExplorationSafe,
  kAiExplorationBalanced,
  kAiExplorationSurprise,
];

/// 年代选项（稳定 token；文案在 l10n）。
const String kAiEraAny = 'any';
const String kAiEraRecent3 = 'recent3';
const String kAiEra2010s = '2010s';
const String kAiEra2000s = '2000s';
const String kAiEraBefore90 = 'before90';
const List<String> kAiEraOptions = [
  kAiEraAny,
  kAiEraRecent3,
  kAiEra2010s,
  kAiEra2000s,
  kAiEraBefore90,
];

/// 风格 / 场景 / 语言选项（稳定 token；提示词映射与 UI 文案各自消费）。
const List<String> kAiStyleOptions = [
  'pop',
  'rock',
  'electronic',
  'folk',
  'rap',
  'rnb',
  'jazz',
  'classical',
  'metal',
  'acg',
  'instrumental',
  'chineseStyle',
];
const List<String> kAiSceneOptions = [
  'commute',
  'focus',
  'relax',
  'workout',
  'sleep',
  'weekend',
];
const List<String> kAiLanguageOptions = [
  'mandarin',
  'cantonese',
  'english',
  'japanese',
  'korean',
  'instrumental',
];

/// 生成偏好（持久化 JSON；改动即时保存，只影响下一次生成）。
class AiPreferences {
  final int batchSize;
  final bool autoFeed;
  final List<String> styles;
  final List<String> scenes;
  final List<String> languages;
  final String era;
  final String exploration;
  final bool onlyUnheard;
  final String extraPrompt;
  final Set<AiUpstreamSection> sections;

  /// 「多来点这种」种子（快照；持久化归 [AiFeedbackMemory]）。
  final List<String> seeds;

  /// 已确认过的敏感发送范围（收藏 / 自建歌单）只提示一次。
  final Set<AiUpstreamSection> acknowledgedScopes;

  const AiPreferences({
    this.batchSize = kAiDefaultBatchSize,
    this.autoFeed = true,
    this.styles = const [],
    this.scenes = const [],
    this.languages = const [],
    this.era = kAiEraAny,
    this.exploration = kAiExplorationBalanced,
    this.onlyUnheard = true,
    this.extraPrompt = '',
    this.sections = kAiDefaultUpstreamSections,
    this.seeds = const [],
    this.acknowledgedScopes = const {},
  });

  static const AiPreferences defaults = AiPreferences();

  /// 补充要求字数上限。
  static const int extraPromptLimit = 120;

  static int sanitizeBatchSize(int value) =>
      kAiBatchSizeOptions.contains(value) ? value : kAiDefaultBatchSize;

  AiPreferences copyWith({
    int? batchSize,
    bool? autoFeed,
    List<String>? styles,
    List<String>? scenes,
    List<String>? languages,
    String? era,
    String? exploration,
    bool? onlyUnheard,
    String? extraPrompt,
    Set<AiUpstreamSection>? sections,
    List<String>? seeds,
    Set<AiUpstreamSection>? acknowledgedScopes,
  }) =>
      AiPreferences(
        batchSize: batchSize ?? this.batchSize,
        autoFeed: autoFeed ?? this.autoFeed,
        styles: styles ?? this.styles,
        scenes: scenes ?? this.scenes,
        languages: languages ?? this.languages,
        era: era ?? this.era,
        exploration: exploration ?? this.exploration,
        onlyUnheard: onlyUnheard ?? this.onlyUnheard,
        extraPrompt: extraPrompt ?? this.extraPrompt,
        sections: sections ?? this.sections,
        seeds: seeds ?? this.seeds,
        acknowledgedScopes: acknowledgedScopes ?? this.acknowledgedScopes,
      );

  Map<String, dynamic> toJson() => {
        'batchSize': batchSize,
        'autoFeed': autoFeed,
        'styles': styles,
        'scenes': scenes,
        'languages': languages,
        'era': era,
        'exploration': exploration,
        'onlyUnheard': onlyUnheard,
        'extraPrompt': extraPrompt,
        'sections': [for (final section in sections) section.storageValue],
        'seeds': seeds,
        'acknowledgedScopes': [
          for (final section in acknowledgedScopes) section.storageValue,
        ],
      };

  /// 宽松解析：缺项/损坏字段回退默认值，不因单个字段丢弃整份偏好。
  static AiPreferences tryFromJson(Object? json) {
    if (json is! Map) return defaults;
    final sections = <AiUpstreamSection>{};
    final rawSections = json['sections'];
    if (rawSections is List) {
      for (final entry in rawSections) {
        final section = AiUpstreamSection.fromStorage(entry);
        if (section != null) sections.add(section);
      }
    }
    final acknowledged = <AiUpstreamSection>{};
    final rawAcknowledged = json['acknowledgedScopes'];
    if (rawAcknowledged is List) {
      for (final entry in rawAcknowledged) {
        final section = AiUpstreamSection.fromStorage(entry);
        if (section != null) acknowledged.add(section);
      }
    }
    final era = json['era']?.toString() ?? kAiEraAny;
    final exploration =
        json['exploration']?.toString() ?? kAiExplorationBalanced;
    final extraPrompt = (json['extraPrompt']?.toString() ?? '').trim();
    return AiPreferences(
      batchSize: sanitizeBatchSize(
        (json['batchSize'] as num?)?.toInt() ?? kAiDefaultBatchSize,
      ),
      autoFeed: json['autoFeed'] is bool ? json['autoFeed'] as bool : true,
      styles: _aiStringList(json['styles']),
      scenes: _aiStringList(json['scenes']),
      languages: _aiStringList(json['languages']),
      era: kAiEraOptions.contains(era) ? era : kAiEraAny,
      exploration: kAiExplorationOptions.contains(exploration)
          ? exploration
          : kAiExplorationBalanced,
      onlyUnheard:
          json['onlyUnheard'] is bool ? json['onlyUnheard'] as bool : true,
      extraPrompt: extraPrompt.length > extraPromptLimit
          ? extraPrompt.substring(0, extraPromptLimit)
          : extraPrompt,
      sections: rawSections is List ? sections : kAiDefaultUpstreamSections,
      seeds: _aiStringList(json['seeds']),
      acknowledgedScopes: acknowledged,
    );
  }
}

/// 宽松读取字符串列表（去空白、丢空项）；偏好与反馈记忆共用。
List<String> _aiStringList(Object? value) => value is List
    ? [
        for (final entry in value)
          if (entry?.toString().trim().isNotEmpty ?? false)
            entry.toString().trim(),
      ]
    : const [];

/// 跨重启保留的反馈记忆（不感兴趣 / 喜欢 / 种子）。
class AiFeedbackMemory {
  final List<String> skipped;
  final List<String> liked;
  final List<String> seeds;

  const AiFeedbackMemory({
    this.skipped = const [],
    this.liked = const [],
    this.seeds = const [],
  });

  static const AiFeedbackMemory empty = AiFeedbackMemory();

  static const int skippedLimit = 200;
  static const int likedLimit = 200;
  static const int seedLimit = 20;

  AiFeedbackMemory withSkipped(List<String> labels) => AiFeedbackMemory(
        skipped: _trim(labels, skippedLimit),
        liked: liked,
        seeds: seeds,
      );

  AiFeedbackMemory addSkipped(String label) => withSkipped([label, ...skipped]);

  AiFeedbackMemory removeSkipped(String label) => withSkipped([
        for (final entry in skipped)
          if (entry != label) entry,
      ]);

  AiFeedbackMemory withLiked(List<String> labels) => AiFeedbackMemory(
        skipped: skipped,
        liked: _trim(labels, likedLimit),
        seeds: seeds,
      );

  AiFeedbackMemory addLiked(String label) => withLiked([label, ...liked]);

  AiFeedbackMemory withSeeds(List<String> values) => AiFeedbackMemory(
        skipped: skipped,
        liked: liked,
        seeds: _trim(values, seedLimit),
      );

  AiFeedbackMemory addSeed(String label) => withSeeds([label, ...seeds]);

  AiFeedbackMemory removeSeed(String label) => withSeeds([
        for (final entry in seeds)
          if (entry != label) entry,
      ]);

  static List<String> _trim(List<String> values, int limit) {
    final seen = <String>{};
    final result = <String>[];
    for (final value in values) {
      final label = value.trim();
      if (label.isEmpty || !seen.add(label)) continue;
      result.add(label);
      if (result.length >= limit) break;
    }
    return result;
  }

  Map<String, dynamic> toJson() => {
        'skipped': skipped,
        'liked': liked,
        'seeds': seeds,
      };

  static AiFeedbackMemory tryFromJson(Object? json) {
    if (json is! Map) return empty;
    return AiFeedbackMemory(
      skipped: _trim(_aiStringList(json['skipped']), skippedLimit),
      liked: _trim(_aiStringList(json['liked']), likedLimit),
      seeds: _trim(_aiStringList(json['seeds']), seedLimit),
    );
  }
}

/// 历史保留策略（唯一实现，store 与 provider 共用）。
const int kAiDjHistoryMaxBatches = 20;
const int kAiDjHistoryMaxTracks = 400;
const Duration kAiDjHistoryRetention = Duration(days: 30);

/// 清理结果：保留项 + 需要同步删除批次键的项。
typedef AiDjHistoryTrimResult = ({
  List<AiDjHistoryEntry> kept,
  List<AiDjHistoryEntry> removed,
});

/// 按 20 批 / 400 首 / 30 天清理历史；active 永不自动清理。
AiDjHistoryTrimResult trimAiDjHistory(
  List<AiDjHistoryEntry> entries, {
  required String? activeBatchId,
  required DateTime now,
}) {
  final cutoff = now.subtract(kAiDjHistoryRetention);
  final sorted = [...entries]
    ..sort((a, b) => b.generatedAt.compareTo(a.generatedAt));
  final kept = <AiDjHistoryEntry>[];
  final removed = <AiDjHistoryEntry>[];
  var tracks = 0;
  for (final entry in sorted) {
    final isActive = entry.id == activeBatchId;
    final expired = entry.generatedAt.isBefore(cutoff);
    final overCount = kept.length >= kAiDjHistoryMaxBatches;
    final overTracks = tracks + entry.itemCount > kAiDjHistoryMaxTracks;
    if (!isActive && (expired || overCount || overTracks)) {
      removed.add(entry);
      continue;
    }
    kept.add(entry);
    tracks += entry.itemCount;
  }
  bool dropOldestNonActive() {
    for (var i = kept.length - 1; i >= 0; i--) {
      if (kept[i].id == activeBatchId) continue;
      final dropped = kept.removeAt(i);
      tracks -= dropped.itemCount;
      removed.add(dropped);
      return true;
    }
    return false;
  }

  while (kept.length > kAiDjHistoryMaxBatches && dropOldestNonActive()) {}
  while (tracks > kAiDjHistoryMaxTracks && dropOldestNonActive()) {}
  return (kept: kept, removed: removed);
}

/// 可搜索渠道按音源页顺序排序（`order` 升序；同序保留注册表顺序）。
List<SourceDescriptor> aiDjSearchableSourcesInPageOrder(
  List<SourceDescriptor> descriptors,
) {
  final indexed = descriptors.asMap().entries.toList()
    ..sort((a, b) {
      final byOrder = a.value.order.compareTo(b.value.order);
      return byOrder != 0 ? byOrder : a.key.compareTo(b.key);
    });
  return [
    for (final entry in indexed)
      if (entry.value.enabled && entry.value.capabilities.search) entry.value,
  ];
}

/// 「本次发送的数据」摘要：只统计条数/来源名，不含内容（隐私透明展示用）。
class AiUpstreamSummary {
  /// 最近事件明细条数（TasteProfileBuilder.recentEventLimit 上限）。
  final int recentEvents;

  /// Top 艺人 / Top 曲目条数。
  final int topArtists;
  final int topTracks;

  /// 已听排除清单条数。
  final int exclusions;

  /// 收藏 / 自建歌单曲目条数（未勾选时为 0）。
  final int favorites;
  final int playlists;

  /// 本次实际使用的找歌渠道名（按解析顺序）。
  final List<String> sourceNames;

  const AiUpstreamSummary({
    required this.recentEvents,
    required this.topArtists,
    required this.topTracks,
    required this.exclusions,
    this.favorites = 0,
    this.playlists = 0,
    this.sourceNames = const [],
  });

  /// 上游数据为空（没有听歌统计）时也允许生成（画像为空）。
  static const AiUpstreamSummary empty = AiUpstreamSummary(
    recentEvents: 0,
    topArtists: 0,
    topTracks: 0,
    exclusions: 0,
  );
}

/// AI 推歌模式的队列上下文名（播放页/队列面板展示）。
const String kAiDjContextName = 'AI 推歌';

/// 模式状态（AI 徽标/页面开关共用）。
enum AiDjStatus {
  /// 未推歌（功能可以仍处于启用：列表可浏览、可手动播放）。
  off,

  /// 生成第一批中。
  preparing,

  /// 电台生效：播放 + 后台续推。
  playing,

  /// 生成失败（保留当前队列继续播放，可重试）。
  error,
}
