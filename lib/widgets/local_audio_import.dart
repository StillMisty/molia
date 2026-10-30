import 'package:file_picker/file_picker.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/download/download_manager.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文（与 lxmc_import / 收藏页同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 「导入本地歌曲」流程：多选音频文件 → `DownloadManager.importLocalFiles`
/// （就地引用：不复制、不移动）→ SnackBar 反馈。
///
/// 与 `.lxmc` 导入（`lxmc_import.dart`）同一形态：文件选择与反馈在 UI 层，
/// 标签解析 / 落库在服务层（可单测）。下载能力不可用时入口本身不出现，
/// 这里再兜一层防御。
Future<void> importLocalAudioFilesFlow(BuildContext context) async {
  final l10n = _l10n(context);
  final downloads = context.read<DownloadManager?>();
  final messengerContext = context;
  if (downloads == null || !downloads.supported) return;

  final List<PlatformFile> files;
  try {
    files = await FilePicker.pickFiles(
      type: FileType.audio,
      dialogTitle: l10n.libraryImportLocalSongs,
    );
  } catch (e) {
    if (messengerContext.mounted) {
      M3ESnackbar.show(
        messengerContext,
        message: l10n.libraryImportFailed('$e'),
      );
    }
    return;
  }
  // 平台可能不给路径（部分内容来源只给字节）：计入跳过，不算失败。
  final paths = [
    for (final file in files)
      if ((file.path ?? '').trim().isNotEmpty) file.path!.trim(),
  ];
  var skipped = files.length - paths.length;
  if (paths.isEmpty) return;

  final (imported, notAudio) = await downloads.importLocalFiles(paths);
  skipped += notAudio;
  if (!messengerContext.mounted) return;
  M3ESnackbar.show(
    messengerContext,
    message: skipped == 0
        ? l10n.libraryImportLocalSongsDone(imported)
        : l10n.libraryImportLocalSongsSkipped(imported, skipped),
  );
}
