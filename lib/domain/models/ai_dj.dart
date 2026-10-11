/// AI 推歌（Phase 2）领域模型：LLM 配置 / 推荐项 / 解析结果 / 批次。
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
      model: 'deepseek-chat',
    ),
    LlmProviderPreset(
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
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
}

/// AI 推歌模式的队列上下文名（播放页/队列面板展示）。
const String kAiDjContextName = 'AI 推歌';

/// 模式状态（AI 徽标/页面开关共用）。
enum AiDjStatus {
  /// 未开启。
  off,

  /// 生成第一批中。
  preparing,

  /// 模式生效：播放 + 后台续推。
  playing,

  /// 生成失败（保留当前队列继续播放，可重试）。
  error,
}
