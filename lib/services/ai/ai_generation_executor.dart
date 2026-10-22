/// AI 生成执行器：token / epoch / 取消 / 忙碌位 / 可见进度的唯一持有者。
///
/// 四条生成路径（显式生成、静默补歌、换一首、重找未解析）只提供
/// [AiGenerationIntent] 与两个闭包：调用生成器、提交结果。执行器按意图决定：
/// - 显式：占用忙碌位与三阶段进度，可取消，晚到结果按 epoch 丢弃；
/// - 静默：独立 token、不显示进度，显式操作开始时被抢占；
/// - 换一首：不可取消、不占显式忙碌位，只标记行内 `replacingUri`。
///
/// 进度走独立 [state]（ValueListenable），provider 只把忙碌位 / 行内替换的
/// 离散变化转发成聚合通知，页面可按块窄订阅而不跟着每个分片重建。
library;

import 'package:flutter/foundation.dart';

import '../../domain/models/ai_dj.dart';
import '../../domain/models/failure.dart';

/// 生成任务类别：决定取消、忙碌位、进度与失败策略。
enum AiGenerationLane {
  /// 显式生成 / 重找未解析：可见、可取消、互斥。
  explicit,

  /// 单曲「换一首」：不可取消、不占显式忙碌位、行内进度。
  replace,

  /// 静默补歌：无可见进度，显式操作可抢占。
  silent,
}

/// 失败落到哪个状态位。
enum AiGenerationFailurePolicy {
  /// 显式操作：写入 provider 的 `lastError`。
  surface,

  /// 静默补歌：计入自动补歌连续失败，不写 `lastError`。
  autoFeed,
}

/// 一次生成意图：来源、数量、是否可见、失败策略（后两者由 [lane] 派生）。
@immutable
class AiGenerationIntent {
  const AiGenerationIntent({
    required this.origin,
    required this.count,
    required this.lane,
    this.initialProgress,
    this.replacingUri,
  });

  /// 写入历史 / 日志的来源；换一首与重找未解析不归档，只用于日志。
  final AiDjOrigin origin;

  /// 本次生成的数量（日志 / 进度口径；真正请求数量由调用方闭包传）。
  final int count;

  final AiGenerationLane lane;

  /// 显式 lane 的初始进度；为空时从 profile 阶段开始。
  final AiDjProgress? initialProgress;

  /// 换一首时被替换曲目的 uri（行内进度标记）。
  final String? replacingUri;

  /// 是否占用可见忙碌位与进度卡。
  bool get visible => lane == AiGenerationLane.explicit;

  AiGenerationFailurePolicy get failurePolicy => lane == AiGenerationLane.silent
      ? AiGenerationFailurePolicy.autoFeed
      : AiGenerationFailurePolicy.surface;
}

/// 执行器对外发布的生成状态（独立于 provider 的聚合通知）。
@immutable
class AiGenerationState {
  const AiGenerationState({
    this.busy = false,
    this.progress,
    this.replacingUri,
  });

  static const AiGenerationState idle = AiGenerationState();

  final bool busy;
  final AiDjProgress? progress;
  final String? replacingUri;

  @override
  bool operator ==(Object other) =>
      other is AiGenerationState &&
      other.busy == busy &&
      other.replacingUri == replacingUri &&
      identical(other.progress, progress);

  @override
  int get hashCode =>
      Object.hash(busy, replacingUri, identityHashCode(progress));
}

/// 生成器调用闭包：`onProgress` 只对显式 lane 非空。
typedef AiGenerationInvoke = Future<AiDjBatch> Function(
  AiGenerationCancelToken cancelToken,
  void Function(AiDjProgress progress)? onProgress,
);

/// 结果提交闭包：执行器仍持有本轮状态时调用；抛错按失败策略处理。
typedef AiGenerationCommit<T> = Future<T> Function(AiDjBatch batch);

typedef AiGenerationFailureHandler = void Function(
  AiGenerationIntent intent,
  SourceFailure failure,
);

class AiGenerationExecutor {
  AiGenerationExecutor({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final ValueNotifier<AiGenerationState> _state =
      ValueNotifier<AiGenerationState>(AiGenerationState.idle);

  AiGenerationCancelToken? _explicitToken;
  AiGenerationCancelToken? _silentToken;

  /// 显式 lane 的代次：取消 / 新一轮都会自增，用于丢弃晚到结果。
  int _epoch = 0;
  bool _disposed = false;

  ValueListenable<AiGenerationState> get state => _state;
  AiGenerationState get stateValue => _state.value;

  bool get isBusy => _state.value.busy;
  AiDjProgress? get progress => _state.value.progress;
  String? get replacingUri => _state.value.replacingUri;

  /// 静默补歌是否在途（含生成后的提交阶段）。
  bool get autoFeedInFlight => _silentToken != null;

  /// 运行一次生成。
  ///
  /// 返回 [commit] 的结果；取消 / 被新显式任务抢占 / 失败时返回 null。
  Future<T?> run<T>({
    required AiGenerationIntent intent,
    required AiGenerationInvoke invoke,
    required AiGenerationCommit<T> commit,
    required AiGenerationFailureHandler onFailure,
  }) async {
    if (_disposed) return null;
    final token = AiGenerationCancelToken();
    int? epoch;

    switch (intent.lane) {
      case AiGenerationLane.explicit:
        if (isBusy) return null;
        // 显式优先：取消在途静默任务，晚到的静默结果在 token 检查处丢弃。
        cancelAutoFeed();
        epoch = ++_epoch;
        _explicitToken = token;
        _publish(AiGenerationState(
          busy: true,
          progress: intent.initialProgress ??
              AiDjProgress(phase: AiDjPhase.profile, startedAt: _clock()),
          replacingUri: _state.value.replacingUri,
        ));
      case AiGenerationLane.silent:
        if (isBusy || _silentToken != null) return null;
        _silentToken = token;
      case AiGenerationLane.replace:
        if (isBusy || _state.value.replacingUri != null) return null;
        _publish(AiGenerationState(
          busy: _state.value.busy,
          progress: _state.value.progress,
          replacingUri: intent.replacingUri,
        ));
        if (intent.replacingUri == null) return null;
    }

    try {
      final batch = await invoke(
        token,
        intent.visible
            ? (progress) {
                if (!_isCurrent(intent, token, epoch)) return;
                _publish(AiGenerationState(
                  busy: true,
                  progress: progress,
                  replacingUri: _state.value.replacingUri,
                ));
              }
            : null,
      );
      if (!_isCurrent(intent, token, epoch)) return null;
      return await commit(batch);
    } on SourceFailure catch (failure) {
      if (failure.kind == FailureKind.cancelled ||
          !_isCurrent(intent, token, epoch)) {
        return null;
      }
      onFailure(intent, failure);
      return null;
    } catch (error) {
      if (!_isCurrent(intent, token, epoch)) return null;
      onFailure(intent, SourceFailure.from(error));
      return null;
    } finally {
      _finish(intent, token, epoch);
    }
  }

  /// 取消显式生成：不写错误、不动列表；晚到结果按 epoch 丢弃。
  ///
  /// 换一首不在此列（它没有 token / epoch）。
  void cancelExplicit() {
    if (_explicitToken == null && !isBusy && progress == null) return;
    _epoch++;
    _explicitToken?.cancel();
    _explicitToken = null;
    _publish(AiGenerationState(replacingUri: _state.value.replacingUri));
  }

  /// 取消在途静默补歌：只丢弃尚未入队的结果，不触碰可见状态。
  void cancelAutoFeed() {
    _silentToken?.cancel();
    _silentToken = null;
  }

  bool _isCurrent(
    AiGenerationIntent intent,
    AiGenerationCancelToken token,
    int? epoch,
  ) =>
      switch (intent.lane) {
        AiGenerationLane.explicit => epoch == _epoch && !token.isCancelled,
        AiGenerationLane.silent => !token.isCancelled,
        // 换一首没有取消通道：批内竞争由提交闭包自己按 active id 判断；
        // 只额外挡住 provider 已 dispose 的提交。
        AiGenerationLane.replace => !_disposed,
      };

  void _finish(
    AiGenerationIntent intent,
    AiGenerationCancelToken token,
    int? epoch,
  ) {
    switch (intent.lane) {
      case AiGenerationLane.explicit:
        if (epoch != _epoch) return;
        _explicitToken = null;
        _publish(AiGenerationState(replacingUri: _state.value.replacingUri));
      case AiGenerationLane.silent:
        if (identical(_silentToken, token)) _silentToken = null;
      case AiGenerationLane.replace:
        if (_state.value.replacingUri == intent.replacingUri) {
          _publish(AiGenerationState(
            busy: _state.value.busy,
            progress: _state.value.progress,
          ));
        }
    }
  }

  void _publish(AiGenerationState next) {
    if (_disposed) return;
    if (_state.value != next) _state.value = next;
  }

  void dispose() {
    _disposed = true;
    _explicitToken?.cancel();
    _silentToken?.cancel();
    _explicitToken = null;
    _silentToken = null;
    _state.dispose();
  }
}
