/// 下载失败文案：已知 `l10nKey` 精确映射，未知回退通用失败（带原始信息）。
///
/// 歌曲信息页 / 下载弹层 / 来源行「下载并分享」共用（`SourceFailure` 的
/// UI 侧唯一映射点，页面不直接展示 `$e`）。
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
