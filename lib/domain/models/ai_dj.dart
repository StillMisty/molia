/// AI 推歌领域模型：LLM 配置 / 推荐项 / 解析结果 / 批次。
///
/// 纯 Dart（无 Flutter/provider 依赖）；提示词构建与网络调用在
/// `lib/services/ai/**`，模式状态机在 `lib/providers/ai_dj_provider.dart`。
library;

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

  const ResolvedRecommendation({required this.source, required this.track});
}

/// 一批推荐（含解析失败项，页面折叠展示）。
///
/// 语义：**今日推荐列表**——持久化、可浏览，不随播放会话消耗消失；
/// 「推歌（电台）」只是把这份列表喂进播放队列的自动化。
class AiDjBatch {
  final List<ResolvedRecommendation> items;

  /// 本地搜索未能解析的推荐（不进入队列）。
  final List<AiRecommendation> unresolved;

  final DateTime generatedAt;

  const AiDjBatch({
    required this.items,
    this.unresolved = const [],
    required this.generatedAt,
  });

  bool get isEmpty => items.isEmpty;

  AiDjBatch copyWith({
    List<ResolvedRecommendation>? items,
    List<AiRecommendation>? unresolved,
    DateTime? generatedAt,
  }) =>
      AiDjBatch(
        items: items ?? this.items,
        unresolved: unresolved ?? this.unresolved,
        generatedAt: generatedAt ?? this.generatedAt,
      );
}

/// 「本次发送的数据」摘要：只统计条数，不含内容（隐私透明展示用）。
class AiUpstreamSummary {
  /// 最近事件明细条数（TasteProfileBuilder.recentEventLimit 上限）。
  final int recentEvents;

  /// Top 艺人 / Top 曲目条数。
  final int topArtists;
  final int topTracks;

  /// 已听排除清单条数。
  final int exclusions;

  const AiUpstreamSummary({
    required this.recentEvents,
    required this.topArtists,
    required this.topTracks,
    required this.exclusions,
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

/// 推荐列表缓存有效期选项（天；0 = 永久保留）。
///
/// 语义是「缓存本身」而非提示：未过期时续推优先消费这批列表的剩余曲目，
/// 已过期则直接生成新批（不打断播放，也不弹提示）。
const List<int> kAiCacheTtlDayOptions = [1, 3, 7, 0];

/// 默认缓存有效期（天）。
const int kAiDefaultCacheTtlDays = 1;
