import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/library.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_providers.dart';
import '../services/library/lxmc_import_service.dart';

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
  // 非 widget 辅助函数：调用处（收藏页 / 备份页）只传 context，因此从最近的
  // ProviderScope 取容器读依赖，而不是引入 `Provider.of`。
  final provider = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(libraryProvider);
  // 数据层解码异常在服务内翻译成稳定原因，widget 不直接依赖 data 层。
  final service = LxmcImportService(importBytes: provider.importLxmcBytes);
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
    final result = await service.importBytes(bytes, fileName: file.name);
    if (!messengerContext.mounted) return null;
    M3ESnackbar.show(
      messengerContext,
      message: l10n.libraryImportSuccess(result.imported),
    );
    return result;
  } on LxmcImportException catch (e) {
    if (!messengerContext.mounted) return null;
    M3ESnackbar.show(
      messengerContext,
      message: _decodeErrorMessage(l10n, e.reason),
    );
    return null;
  } catch (e) {
    if (!messengerContext.mounted) return null;
    M3ESnackbar.show(messengerContext, message: l10n.libraryImportFailed('$e'));
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
