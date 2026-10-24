/// 资料库读取 / 写入的结果类型。
///
/// 为什么单独一层：页面原先只能看到「空列表」与静默失败的 debugPrint，
/// 分不清「这里本来就没有」和「根本没加载成功」；批量写入抛进
/// `unawaited` 的 Future 后既没有结果也没有反馈。这里把两种结果都变成
/// 类型：读取是 loading / ready / failed（failed 保留原始异常供日志与
/// 测试，UI 只展示 l10n 文案），写入是 applied / unchanged / failed。
library;

/// 资料库读取阶段。
enum LibraryReadStatus { loading, ready, failed }

/// 资料库读取结果（合集视图用）。
///
/// [error] 只用于诊断与测试：UI 不展示原始异常，统一给 l10n 文案 + 重试。
class LibraryReadState {
  const LibraryReadState._(this.status, this.error);

  const LibraryReadState.loading() : this._(LibraryReadStatus.loading, null);

  const LibraryReadState.ready() : this._(LibraryReadStatus.ready, null);

  const LibraryReadState.failed(Object error)
      : this._(LibraryReadStatus.failed, error);

  final LibraryReadStatus status;
  final Object? error;

  bool get isLoading => status == LibraryReadStatus.loading;
  bool get isReady => status == LibraryReadStatus.ready;
  bool get isFailed => status == LibraryReadStatus.failed;
}

/// 资料库写入结果。
enum LibraryMutationStatus { applied, unchanged, failed }

/// 一次写入的结果：成功写入 / 无变化（幂等去重等）/ 失败。
///
/// 失败不会抛出到调用方：写入方（provider）统一在边界收口成 failed，
/// 页面据此决定是否清空多选与提示，不再让异常逃进 `unawaited`。
class LibraryMutationOutcome {
  const LibraryMutationOutcome.applied([this.changed = 0])
      : status = LibraryMutationStatus.applied,
        error = null;

  const LibraryMutationOutcome.unchanged()
      : status = LibraryMutationStatus.unchanged,
        changed = 0,
        error = null;

  const LibraryMutationOutcome.failed(this.error)
      : status = LibraryMutationStatus.failed,
        changed = 0;

  final LibraryMutationStatus status;

  /// 实际写入 / 删除的条数（无计数语义的写入为 0）。
  final int changed;

  final Object? error;

  bool get isFailure => status == LibraryMutationStatus.failed;

  /// 成功（含无变化）：页面可以清选择 / 收起编辑态。
  bool get isSuccess => !isFailure;
}
