/// 下载失败文案：已知 `l10nKey` 精确映射，未知回退通用失败（带原始信息）。
///
/// 曲目菜单 / 来源行「下载并分享」/ 本地数据页 / 下载管理页共用
/// （`SourceFailure` 的 UI 侧唯一映射点，页面不直接展示 `$e`）。
library;

import '../domain/models/failure.dart';
import '../l10n/app_localizations.dart';

String downloadFailureLabel(AppLocalizations l10n, SourceFailure failure) {
  switch (failure.l10nKey) {
    case 'downloadUnsupported':
      return l10n.downloadUnsupported;
    case 'downloadAlreadyExists':
      return l10n.downloadAlreadyExists;
    case 'downloadCancelled':
      return l10n.downloadCancelled;
    case 'downloadFileMissing':
      return l10n.downloadFileMissing;
    default:
      return l10n.downloadFailed(failure.message);
  }
}

/// 下载失败的统一反馈文案：取消返回 null（所有入口静默），已知失败走
/// [downloadFailureLabel]，非 [SourceFailure] 的异常归一到通用失败。
///
/// 为什么返回 null 而不是抛 / 空串：调用方只需 `if (message != null) 提示`，
/// 不会误把「取消」渲染成一条失败提示。
String? downloadFailureMessage(AppLocalizations l10n, Object error) {
  final failure = error is SourceFailure ? error : SourceFailure.from(error);
  if (failure.kind == FailureKind.cancelled) return null;
  return downloadFailureLabel(l10n, failure);
}
