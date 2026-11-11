/// 一次生成请求的完整输入：偏好、合并反馈、排除项与数量。
///
/// 预览、显式生成、换一首、静默补歌都从同一个组装点构造本对象：预览只读取
/// 字段，其余路径原样交给 [AiGenerationExecutor]；调用点不再各自拼
/// `preferences` / `skippedLabels` / `likedLabels` / `exclude*`，预览与实际
/// 请求的输入顺序也不会漂移。
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/ai_dj.dart';

/// 已合并的反馈标签（本轮 + 长期记忆；喜欢可能含待回流项）。
@immutable
class AiGenerationFeedback {
  AiGenerationFeedback({
    List<String> skipped = const [],
    List<String> liked = const [],
  }) : skipped = List.unmodifiable(skipped),
       liked = List.unmodifiable(liked);

  final List<String> skipped;
  final List<String> liked;
}

/// 本批排除项：标签进提示词让模型主动避开，规范化键只做本地兜底。
@immutable
class AiGenerationExclusions {
  AiGenerationExclusions({
    List<String> labels = const [],
    List<String> keys = const [],
  }) : labels = List.unmodifiable(labels),
       keys = List.unmodifiable(keys);

  final List<String> labels;
  final List<String> keys;
}

/// 一次生成所需的全部输入（不可变；入口处复制列表，调用方后续改动不影响请求）。
@immutable
class AiGenerationRequest {
  const AiGenerationRequest({
    required this.preferences,
    required this.feedback,
    required this.exclusions,
    required this.count,
  });

  /// 偏好快照（已带本轮种子）。
  final AiPreferences preferences;

  /// 合并后的反馈（本轮 + 持久记忆）。
  final AiGenerationFeedback feedback;

  /// 上一批 + 未解析 + 会话队列的排除快照。
  final AiGenerationExclusions exclusions;

  /// 本次请求数量（提示词请求行、进度目标与批次元数据共用）。
  final int count;
}
