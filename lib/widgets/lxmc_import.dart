import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../data/lxmc_decoder.dart';
import '../domain/models/library.dart';
import '../l10n/app_localizations.dart';
import '../providers/library_provider.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本页而不注册 delegate，
/// 此时回退到简体中文（与 favorites 页的约定一致）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// .lxmc 导入流程（收藏页与设置页共用）：选文件 → 导入 → SnackBar 反馈
/// （成功 N 首 / 失败原因）。
///
/// 成功返回导入结果（收藏页据此切换到新列表）；取消 / 失败返回 null。
Future<LxmcImportResult?> importLxmcFavoritesFlow(BuildContext context) async {
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
    return null;
  }
  if (files.isEmpty) return null;

  final file = files.first;
  final Uint8List bytes;
  try {
    // file_picker 13 的 PlatformFile 统一提供 readAsBytes（不依赖本地路径）。
    bytes = await file.readAsBytes();
  } catch (e) {
    if (messengerContext.mounted) {
      M3ESnackbar.show(
        messengerContext,
        message: l10n.libraryImportFailed('$e'),
      );
    }
    return null;
  }

  try {
    final result = await provider.importLxmcBytes(bytes, fileName: file.name);
    if (!messengerContext.mounted) return null;
    M3ESnackbar.show(
      messengerContext,
      message: l10n.libraryImportSuccess(result.imported),
    );
    return result;
  } on LxmcDecodeException catch (e) {
    if (!messengerContext.mounted) return null;
    M3ESnackbar.show(
      messengerContext,
      message: _decodeErrorMessage(l10n, e.reason),
    );
    return null;
  } catch (e) {
    if (!messengerContext.mounted) return null;
    M3ESnackbar.show(
      messengerContext,
      message: l10n.libraryImportFailed('$e'),
    );
    return null;
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
