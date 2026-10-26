/// 封面原图查看器：全屏 `contain` 展示当前真实封面，可保存原图。
///
/// 方形缩略图（列表 / 播放页 / 页头）一律 `BoxFit.cover` 裁切；这里不裁切，
/// 保持原图比例。保存走 `SaveAs` 的公共输出（桌面另存为 / Android 系统
/// 「下载」/ iOS 文件 App）的 `covers/`，不写应用内下载记录。
///
/// 入口：歌曲信息页 / 封面选择弹层 / 专辑 / 歌手 / 发现详情页头图；播放页
/// 大封面保持切歌手势，不挂查看器。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/covers/cover_image_fetcher.dart';
import '../services/data_saver_service.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../services/save_as.dart';
import '../theme/m3e_context.dart';
import '../utils/save_as_label.dart';
import 'app_network_image.dart';

/// 查看器关闭后的意图：调用方据此打开封面选择弹层。
enum CoverViewerAction { editCover }

/// 打开封面原图查看器。
///
/// [coverUrl] 是解析后的真实封面地址（自定义 / 原始）；[fileNameBase] 是
/// 保存文件的标题基名（缺省用 [title]）。[source] 仅供测试注入。
Future<CoverViewerAction?> showCoverViewer(
  BuildContext context, {
  required String coverUrl,
  required String title,
  String? subtitle,
  String? fileNameBase,
  bool allowEdit = false,
  CoverOriginalSource? source,
}) {
  assert(coverUrl.isNotEmpty, '封面查看器需要非空封面地址');
  return Navigator.of(context, rootNavigator: true).push<CoverViewerAction>(
    MaterialPageRoute<CoverViewerAction>(
      builder: (_) => CoverViewerPage(
        coverUrl: coverUrl,
        title: title,
        subtitle: subtitle,
        fileNameBase: fileNameBase,
        allowEdit: allowEdit,
        source: source,
      ),
    ),
  );
}

class CoverViewerPage extends StatefulWidget {
  const CoverViewerPage({
    super.key,
    required this.coverUrl,
    required this.title,
    this.subtitle,
    this.fileNameBase,
    this.allowEdit = false,
    this.source,
  });

  final String coverUrl;
  final String title;
  final String? subtitle;
  final String? fileNameBase;

  /// 是否显示「更换封面」；歌曲信息入口为 true，其余入口只读。
  final bool allowEdit;

  /// 原图读取端口（测试注入；null = 生产实现）。
  final CoverOriginalSource? source;

  @override
  State<CoverViewerPage> createState() => _CoverViewerPageState();
}

class _CoverViewerPageState extends State<CoverViewerPage> {
  late final CoverOriginalSource _source = widget.source ?? CoverImageFetcher();

  bool _saving = false;

  AppLocalizations _l10n(BuildContext context) =>
      AppLocalizations.of(context) ??
      lookupAppLocalizations(const Locale('zh'));

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.maybeOf(context);
    final dpr = media?.devicePixelRatio ?? 1.0;
    final screen = media?.size ?? const Size(1080, 1920);
    final cacheWidth = (screen.width * dpr).round();

    return Scaffold(
      key: const Key('coverViewerPage'),
      backgroundColor: scheme.surface,
      appBar: M3EAppBar.top(
        title: Text(widget.title),
        subtitle: (widget.subtitle ?? '').isEmpty
            ? null
            : Text(widget.subtitle!),
        automaticallyImplyLeading: true,
        backgroundColor: scheme.surface,
      ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: scheme.surfaceContainerLowest,
              child: SizedBox.expand(
                child: AppNetworkImage(
                  key: const Key('coverViewerImage'),
                  url: widget.coverUrl,
                  fit: BoxFit.contain,
                  // 只给宽度：双轴会被 ResizeImage 当成精确尺寸而拉伸。
                  memCacheWidth: cacheWidth,
                  placeholder: ColoredBox(
                    color: scheme.surfaceContainerHighest,
                  ),
                  errorWidget: _buildError(context, l10n, scheme),
                ),
              ),
            ),
          ),
          _buildActions(context, l10n, scheme),
        ],
      ),
    );
  }

  Widget _buildError(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image_rounded,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.coverLoadFailed,
              textAlign: TextAlign.center,
              style: context.typeScale.bodyMedium.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(
    BuildContext context,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    final buttons = <Widget>[
      if (widget.allowEdit)
        Expanded(
          child: M3EButton.tonal(
            key: const Key('coverViewerEditButton'),
            size: M3EButtonSize.md,
            onPressed: _saving ? null : _edit,
            icon: const Icon(Icons.image_rounded),
            label: Text(l10n.coverChangeImage),
          ),
        ),
      if (widget.allowEdit) const SizedBox(width: 12),
      Expanded(
        child: M3EButton.filled(
          key: const Key('coverViewerSaveButton'),
          size: M3EButtonSize.md,
          onPressed: _saving ? null : () => unawaited(_save()),
          icon: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: M3EProgressIndicator.circular(
                    size: 18,
                    strokeWidth: 2,
                  ),
                )
              : const Icon(Icons.download_rounded),
          label: Text(l10n.coverSaveOriginal),
        ),
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Row(children: buttons),
            ),
          ),
        ),
      ),
    );
  }

  void _edit() {
    HapticsService.selectionClick();
    Navigator.of(context).pop(CoverViewerAction.editCover);
  }

  Future<void> _save() async {
    if (_saving) return;
    final l10n = _l10n(context);
    final saveAs = context.read<SaveAs?>();
    final notifications = context.read<NotificationService?>();
    if (saveAs == null) {
      notifications?.showErrorSnackBar(l10n.saveFailed);
      return;
    }

    final dataSaver = context.read<DataSaverService?>();
    if (_isNetworkUrl(widget.coverUrl) && (dataSaver?.active ?? false)) {
      final confirmed = await M3EDialog.show<bool>(
        context,
        dialog: M3EDialog(
          title: l10n.downloadDataSaverTitle,
          content: Text(l10n.downloadDataSaverConfirm),
          actions: [
            M3EButton.text(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            M3EButton.filled(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.downloadContinue),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    HapticsService.lightImpact();
    setState(() => _saving = true);
    try {
      final bytes = await _source.read(widget.coverUrl);
      if (!mounted) return;
      if (bytes == null) {
        notifications?.showErrorSnackBar(l10n.coverLoadFailed);
        return;
      }
      final extension = CoverImageFetcher.extensionFor(
        url: widget.coverUrl,
        bytes: bytes,
      );
      final result = await saveAs.saveBytes(
        fileName: CoverImageFetcher.fileNameFor(
          base: widget.fileNameBase ?? widget.title,
          extension: extension,
        ),
        bytes: bytes,
        mimeType: CoverImageFetcher.mimeTypeFor(extension),
        relativeDir: saveAsCoversDirName,
        dialogTitle: l10n.save,
      );
      if (!mounted) return;
      switch (result) {
        case SaveAsSaved(:final displayPath, :final kind):
          notifications?.showSuccessSnackBar(
            savedLocationMessage(l10n, kind, displayPath),
          );
        case SaveAsCancelled():
          return;
        case SaveAsFailed():
          notifications?.showErrorSnackBar(l10n.saveFailed);
      }
    } catch (_) {
      if (mounted) notifications?.showErrorSnackBar(l10n.saveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static bool _isNetworkUrl(String url) {
    final scheme = Uri.tryParse(url)?.scheme ?? '';
    return scheme == 'http' || scheme == 'https' || url.startsWith('//');
  }
}
