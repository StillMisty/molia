import 'dart:async';

import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/services/ai/ai_recommendation_service.dart';

/// 可脚本化的 AI 生成器假实现（不触碰 LLM / 网络）。
class FakeAiDjGenerator implements AiRecommendationGenerator {
  FakeAiDjGenerator({AiDjBatch Function()? batchFactory})
      : batchFactory = batchFactory ??
            (() => AiDjBatch(items: const [], generatedAt: DateTime.now()));

  AiDjBatch Function() batchFactory;

  /// 非空时 [generate] 抛出它。
  Object? error;

  /// 非空时 [generate] 等它完成（测试取消 / 自动补歌竞态）。
  Completer<void>? gate;

  /// 非空时 [resolveUnresolved] 返回它（默认原样返回）。
  AiDjBatch Function(AiDjBatch batch)? unresolvedFactory;

  int calls = 0;
  int unresolvedCalls = 0;
  int? lastCount;
  AiPreferences? lastPreferences;
  List<String> lastSkipped = const [];
  List<String> lastLiked = const [];
  List<String> lastExcluded = const [];
  List<String> lastPreviewLiked = const [];
  AiPreferences? lastPreviewPreferences;
  AiUpstreamSummary summary = AiUpstreamSummary.empty;
  AiPrompt preview = const AiPrompt(systemPrompt: 'System', userPrompt: 'User');

  /// 可选：按 likedLabels 生成 prompt（验证预览与实际请求完全一致）。
  String Function(List<String> likedLabels)? promptForLiked;
  AiPrompt? lastActualPrompt;

  /// 显式生成时模拟三阶段进度（provider 测试用）。
  bool emitProgress = false;

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
    calls++;
    lastCount = count;
    lastPreferences = preferences;
    lastSkipped = skippedLabels;
    lastLiked = likedLabels;
    lastExcluded = excludeLabels;
    lastActualPrompt = promptForLiked == null
        ? null
        : AiPrompt(
            systemPrompt: preview.systemPrompt,
            userPrompt: promptForLiked!(likedLabels),
          );
    final startedAt = DateTime.now();
    if (onProgress != null && emitProgress) {
      onProgress(AiDjProgress(phase: AiDjPhase.profile, startedAt: startedAt));
      onProgress(AiDjProgress(phase: AiDjPhase.model, startedAt: startedAt));
      onProgress(AiDjProgress(
        phase: AiDjPhase.resolving,
        startedAt: startedAt,
        total: count,
      ));
    }
    final wait = gate;
    if (wait != null) await wait.future;
    if (cancelToken?.isCancelled ?? false) {
      throw const SourceFailure(
        kind: FailureKind.cancelled,
        message: 'cancelled',
      );
    }
    final failure = error;
    if (failure != null) throw failure;
    if (onProgress != null && emitProgress) {
      onProgress(AiDjProgress(
        phase: AiDjPhase.resolving,
        startedAt: startedAt,
        done: count,
        total: count,
      ));
    }
    return batchFactory();
  }

  @override
  Future<AiPrompt> buildPromptPreview({
    required int count,
    AiPreferences preferences = AiPreferences.defaults,
    List<String> skippedLabels = const [],
    List<String> likedLabels = const [],
    List<String> excludeLabels = const [],
  }) async {
    lastPreviewLiked = likedLabels;
    lastPreviewPreferences = preferences;
    return AiPrompt(
      systemPrompt: preview.systemPrompt,
      userPrompt: promptForLiked?.call(likedLabels) ?? preview.userPrompt,
    );
  }

  @override
  Future<AiDjBatch> resolveUnresolved({
    required AiDjBatch batch,
    AiPreferences preferences = AiPreferences.defaults,
    AiGenerationCancelToken? cancelToken,
    void Function(AiDjProgress progress)? onProgress,
  }) async {
    unresolvedCalls++;
    onProgress?.call(AiDjProgress(
      phase: AiDjPhase.resolving,
      startedAt: DateTime.now(),
      total: batch.unresolved.length,
      done: batch.unresolved.length,
    ));
    return unresolvedFactory?.call(batch) ?? batch;
  }

  @override
  Future<void> testConnection(LlmConfig config) async {}

  @override
  Future<AiUpstreamSummary> summarizeUpstream({
    AiPreferences preferences = AiPreferences.defaults,
  }) async =>
      summary;
}
