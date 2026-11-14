/// 统一分享弹层：海报预览 + 一个主操作 + 次要输出。
///
/// 听歌统计 / 年度报告 / 列表分享共用这一份结构：预览图让用户先确认要发出去
/// 的内容，主操作只有「分享」，保存图片与复制文本退到次要按钮。导出数据属于
/// 页面 ⋮ 菜单，不在这里重复出现。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../services/poster/poster_share_file.dart';
import '../services/save_as.dart';
import '../theme/m3e_context.dart';
import '../utils/responsive.dart';
import '../utils/save_as_label.dart';
import 'empty_state.dart';
import 'simple_modal_body.dart';

/// 分享文件通道：参数是临时 PNG 路径与分享文案。仅测试替换。
typedef PosterFileShare = Future<void> Function(String path, String shareText);

/// 打开统一分享弹层。
///
/// [renderPoster] 返回 null 表示当前没有可分享内容（显示 [emptyMessage]）。
/// [copyText] 非空时显示「复制文本」次要按钮。
Future<void> showPosterShareSheet(
  BuildContext context, {
  required String title,
  required Future<Uint8List?> Function() renderPoster,
  required String shareText,
  required String fileName,
  required String saveDialogTitle,
  required String emptyMessage,
  String? copyText,
  PosterFileShare? shareFile,
}) {
  // 弹层挂在根 Navigator 上，拿不到页面里的 Provider；依赖必须在打开前取好。
  final saveAs = context.read<SaveAs?>();
  final notifications = context.read<NotificationService?>();
  return ResponsiveNavigation.showSimpleModal<void>(
    context: context,
    title: title,
    child: PosterShareSheet(
      renderPoster: renderPoster,
      shareText: shareText,
      fileName: fileName,
      saveDialogTitle: saveDialogTitle,
      emptyMessage: emptyMessage,
      copyText: copyText,
      shareFile: shareFile,
      saveAs: saveAs,
      notifications: notifications,
    ),
  );
}

/// 统一分享弹层正文。页面通常经 [showPosterShareSheet] 打开，测试可直接挂载。
class PosterShareSheet extends StatefulWidget {
  const PosterShareSheet({
    super.key,
    required this.renderPoster,
    required this.shareText,
    required this.fileName,
    required this.saveDialogTitle,
    required this.emptyMessage,
    this.copyText,
    this.shareFile,
    this.saveAs,
    this.notifications,
  });

  /// 生成海报字节；null 表示没有可分享内容。
  final Future<Uint8List?> Function() renderPoster;

  /// 分享时附带的纯文本（海报文件名由 [fileName] 决定）。
  final String shareText;

  final String fileName;
  final String saveDialogTitle;
  final String emptyMessage;

  /// 非空时显示「复制文本」。
  final String? copyText;

  /// 分享通道；null 时用 [SharePlus.instance]。仅测试注入。
  final PosterFileShare? shareFile;

  /// 弹层在根 Navigator 上，页面 Provider 不可达：打开前由调用方注入。
  final SaveAs? saveAs;
  final NotificationService? notifications;

  @override
  State<PosterShareSheet> createState() => _PosterShareSheetState();
}

class _PosterShareSheetState extends State<PosterShareSheet> {
  Uint8List? _bytes;
  bool _generating = true;
  bool _failed = false;
  bool _empty = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 生成会读主题 / l10n；等首帧后再启动，避免在 initState 依赖 InheritedWidget。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_generate());
    });
  }

  Future<void> _generate() async {
    if (_generating && _bytes != null) return;
    setState(() {
      _generating = true;
      _failed = false;
      _empty = false;
    });
    try {
      final bytes = await widget.renderPoster();
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _empty = bytes == null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  NotificationService? get _notifications =>
      widget.notifications ?? context.read<NotificationService?>();

  void _message(String text) {
    final service = _notifications;
    if (service != null) {
      service.showSnackBar(text);
    } else {
      M3ESnackbar.show(context, message: text);
    }
  }

  void _error(String text) {
    final service = _notifications;
    if (service != null) {
      service.showErrorSnackBar(text);
    } else {
      M3ESnackbar.show(context, message: text);
    }
  }

  Future<void> _shareImage() async {
    final bytes = _bytes;
    if (bytes == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final shareFile =
        widget.shareFile ??
        (path, shareText) => SharePlus.instance.share(
          ShareParams(files: [XFile(path)], text: shareText),
        );
    setState(() => _busy = true);
    try {
      await withTemporaryPosterPng(
        bytes,
        (file) => shareFile(file.path, widget.shareText),
      );
    } catch (_) {
      if (mounted) _error(l10n.shareFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveImage() async {
    final bytes = _bytes;
    if (bytes == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final saveAs = widget.saveAs ?? context.read<SaveAs?>();
    if (saveAs == null) {
      _error(l10n.shareSaveFailed);
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await saveAs.saveBytes(
        fileName: widget.fileName,
        bytes: bytes,
        mimeType: 'image/png',
        relativeDir: saveAsPostersDirName,
        dialogTitle: widget.saveDialogTitle,
      );
      if (!mounted) return;
      switch (result) {
        case SaveAsSaved(:final displayPath, :final kind):
          _message(savedLocationMessage(l10n, kind, displayPath));
        case SaveAsCancelled():
          return;
        case SaveAsFailed():
          _error(l10n.shareSaveFailed);
      }
    } catch (_) {
      if (mounted) _error(l10n.shareSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyText() async {
    final text = widget.copyText;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _message(AppLocalizations.of(context)!.shareCopied);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final bytes = _bytes;
    final copyText = widget.copyText;
    return SafeArea(
      child: SimpleModalBody(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          if (bytes != null)
            _preview(bytes)
          else if (_generating)
            _generatingPreview(l10n)
          else if (_failed)
            _failedPreview(l10n)
          else if (_empty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: EmptyState(
                icon: Icons.image_not_supported_rounded,
                message: widget.emptyMessage,
              ),
            ),
          if (bytes != null) ...[
            const SizedBox(height: 16),
            M3EButton.filled(
              key: const Key('posterShareAction'),
              onPressed: _busy ? null : () => unawaited(_shareImage()),
              icon: const Icon(Icons.ios_share_rounded),
              label: Text(l10n.shareAction),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: M3EButton.outlined(
                    key: const Key('posterSaveImageAction'),
                    onPressed: _busy ? null : () => unawaited(_saveImage()),
                    icon: const Icon(Icons.download_rounded),
                    label: Text(l10n.shareSaveImage),
                  ),
                ),
                if (copyText != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: M3EButton.outlined(
                      key: const Key('posterCopyTextAction'),
                      onPressed: _busy ? null : () => unawaited(_copyText()),
                      icon: const Icon(Icons.copy_rounded),
                      label: Text(l10n.shareCopyText),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 3:4 预览：与三类海报的 1440×1920 成品一致，限宽避免弹层被整图撑高。
  Widget _preview(Uint8List bytes) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              key: const Key('posterSharePreview'),
              cacheWidth: 720,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }

  Widget _generatingPreview(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: M3ECard(
            variant: M3ECardVariant.filled,
            color: scheme.surfaceContainerHigh,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const M3ELoadingIndicator(),
                const SizedBox(height: 12),
                Text(
                  l10n.shareGenerating,
                  style: context.typeScale.bodySmall.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _failedPreview(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 260),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: M3ECard(
            variant: M3ECardVariant.filled,
            color: scheme.surfaceContainerHigh,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  size: 40,
                  color: scheme.error,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.shareGenerateFailed,
                  textAlign: TextAlign.center,
                  style: context.typeScale.bodySmall.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                M3EButton.text(
                  onPressed: () => unawaited(_generate()),
                  child: Text(l10n.retryButton),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
