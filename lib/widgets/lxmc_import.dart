import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/lxmc_decoder.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文（与 favorites 页的约定一致）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

// .lxmc 导入流程（收藏页与设置页共用）

/// 选文件 → 导入 → SnackBar 反馈（成功 N 首 / 失败原因）。
Future<void> importLxmcFavoritesFlow(BuildContext context) async {
  final l10n = _l10n(context);
  final provider = context.read<LibraryProvider>();
  final messengerContext = context;

  final List<PlatformFile> files;
  try {
    files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['lxmc'],
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
  if (files.isEmpty) return;

  final file = files.first;
  final Uint8List bytes;
  try {
    // file_picker 13 的 PlatformFile 统一提供 readAsBytes（含 Web）。
    bytes = await file.readAsBytes();
  } catch (e) {
    if (messengerContext.mounted) {
      M3ESnackbar.show(
        messengerContext,
        message: l10n.libraryImportFailed('$e'),
      );
    }
    return;
  }

  try {
    final result = await provider.importLxmcBytes(bytes, fileName: file.name);
    if (!messengerContext.mounted) return;
    M3ESnackbar.show(
      messengerContext,
      message: l10n.libraryImportSuccess(result.imported),
    );
  } on LxmcDecodeException catch (e) {
    if (!messengerContext.mounted) return;
    M3ESnackbar.show(
      messengerContext,
      message: _decodeErrorMessage(l10n, e.reason),
    );
  } catch (e) {
    if (!messengerContext.mounted) return;
    M3ESnackbar.show(
      messengerContext,
      message: l10n.libraryImportFailed('$e'),
    );
  }
}

String _decodeErrorMessage(AppLocalizations l10n, String reason) {
  switch (reason) {
    case 'unsupported':
      return l10n.libraryImportUnsupported;
    case 'no_tracks':
      return l10n.libraryImportNoTracks;
    default:
      return l10n.libraryImportFailed(reason);
  }
}
