import '../l10n/app_localizations.dart';
import '../services/save_as_types.dart';

/// 另存成功提示：按落点类型选择文案（桌面绝对路径 / Android 系统「下载」/
/// iOS 文件 App 相对路径）。
///
/// 取消静默、失败用错误文案，不在本函数处理。
String savedLocationMessage(
  AppLocalizations l10n,
  SaveLocationKind kind,
  String displayPath,
) => switch (kind) {
  SaveLocationKind.fileSystem => l10n.savedToPath(displayPath),
  SaveLocationKind.downloads => l10n.savedToDownloads(displayPath),
  SaveLocationKind.filesApp => l10n.savedToFilesApp(displayPath),
};

/// 列表导出的单条反馈：成功与缺失文件合并，避免连续两条 Snackbar 互相覆盖。
String playlistExportMessage(
  AppLocalizations l10n,
  SaveLocationKind kind,
  String displayPath,
  int missingFiles,
) {
  final saved = savedLocationMessage(l10n, kind, displayPath);
  return missingFiles <= 0
      ? saved
      : l10n.playlistExportSavedWithMissing(saved, missingFiles);
}
