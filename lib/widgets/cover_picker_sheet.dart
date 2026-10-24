/// 共享封面选择弹层：每曲封面与全局默认封面共用一套交互。
///
/// 入口：
/// - 播放页歌曲信息「歌曲封面」行；
/// - 歌词海报预览页「封面」行；
/// - 设置 › 外观「默认封面」行。
///
/// 选图 → 归一化（`CoverImageCodec`）→ 本地存储（`CustomCoverStore`）→
/// Snackbar 反馈。失败只显示友好文案，不把异常字符串带给用户。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../services/covers/cover_image_codec.dart';
import '../services/covers/custom_cover_store.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import 'app_network_image.dart';

/// 文件选择（测试可注入；返回未归一的原始字节）。
typedef CoverImagePicker = Future<Uint8List?> Function();

/// 图片归一化（测试可注入；默认 [CoverImageCodec.normalize]）。
typedef CoverImageNormalizer = Future<Uint8List> Function(Uint8List bytes);

/// 打开封面选择弹层。
///
/// [trackId] 为空 = 编辑全局默认封面；非空 = 编辑该曲目的自定义封面。
/// [originalCoverUrl] 仅用于「跟随歌曲」时的预览。
Future<void> showCoverPickerSheet(
  BuildContext context, {
  TrackId? trackId,
  String? originalCoverUrl,
  CoverImagePicker? pickImage,
  CoverImageNormalizer? normalize,
}) {
  return M3EBottomSheet.show<void>(
    context,
    builder: (_) => CoverPickerSheet(
      trackId: trackId,
      originalCoverUrl: originalCoverUrl,
      pickImage: pickImage,
      normalize: normalize,
    ),
  );
}

/// 封面选择弹层内容（公开以便独立测试；生产经 [showCoverPickerSheet]）。
class CoverPickerSheet extends StatefulWidget {
  const CoverPickerSheet({
    super.key,
    this.trackId,
    this.originalCoverUrl,
    this.pickImage,
    this.normalize,
  });

  final TrackId? trackId;
  final String? originalCoverUrl;
  final CoverImagePicker? pickImage;
  final CoverImageNormalizer? normalize;

  @override
  State<CoverPickerSheet> createState() => _CoverPickerSheetState();
}

class _CoverPickerSheetState extends State<CoverPickerSheet> {
  bool _busy = false;

  AppLocalizations _l10n(BuildContext context) =>
      AppLocalizations.of(context) ??
      lookupAppLocalizations(const Locale('zh'));

  CustomCoverStore get _store =>
      context.read<CustomCoverStore?>() ?? CustomCoverStore.instance;

  bool get _isDefault => widget.trackId == null;

  String? get _previewUrl {
    if (_isDefault) return _store.defaultCoverUrl;
    return _store.resolveForDisplayById(
      widget.trackId,
      originalUrl: widget.originalCoverUrl,
    );
  }

  bool get _hasCustom => _isDefault
      ? _store.defaultCoverUrl != null
      : _store.trackCoverUrl(widget.trackId!) != null;

  Future<void> _pickImage() async {
    if (_busy) return;
    final l10n = _l10n(context);
    HapticsService.selectionClick();
    setState(() => _busy = true);
    try {
      final picker = widget.pickImage;
      final raw = picker != null
          ? await picker()
          : await _pickImageFromDevice(l10n);
      if (raw == null || raw.isEmpty) return;
      final normalized = await (widget.normalize ?? CoverImageCodec.normalize)(
        raw,
      );
      if (widget.trackId == null) {
        await _store.setDefaultCover(normalized);
      } else {
        await _store.setTrackCover(widget.trackId!, normalized);
      }
      _showMessage(_isDefault ? l10n.coverDefaultUpdated : l10n.coverUpdated);
    } on CoverImageException {
      _showMessage(l10n.coverUnreadable);
    } catch (_) {
      _showMessage(l10n.coverUpdateFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List?> _pickImageFromDevice(AppLocalizations l10n) async {
    final picked = await FilePicker.pickFile(
      type: FileType.image,
      dialogTitle: l10n.coverChooseImage,
    );
    if (picked == null) return null;
    return picked.readAsBytes();
  }

  Future<void> _reset() async {
    if (_busy) return;
    final l10n = _l10n(context);
    HapticsService.selectionClick();
    setState(() => _busy = true);
    try {
      if (widget.trackId == null) {
        await _store.resetDefaultCover();
      } else {
        await _store.resetTrackCover(widget.trackId!);
      }
      _showMessage(_isDefault ? l10n.coverDefaultUpdated : l10n.coverUpdated);
    } catch (_) {
      _showMessage(l10n.coverUpdateFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    context.read<NotificationService?>()?.showSnackBar(message);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final m3e = M3ETheme.of(context);
    final scheme = m3e.colorScheme;
    final title = _isDefault ? l10n.coverDefaultTitle : l10n.coverTitle;
    final subtitle = _isDefault
        ? l10n.coverDefaultSubtitle
        : (_hasCustom ? l10n.coverCustomized : l10n.coverFollowSong);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: m3e.typeScale.titleMedium),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: m3e.typeScale.bodyMedium.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: ValueListenableBuilder<int>(
                valueListenable: _store.revision,
                builder: (context, _, __) => ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AppNetworkImage(
                    key: const Key('coverPickerPreview'),
                    url: _previewUrl,
                    width: 120,
                    height: 120,
                    memCacheWidth:
                        (120 * MediaQuery.of(context).devicePixelRatio).round(),
                    fallbackIconSize: 48,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            M3EButton.filled(
              key: const Key('coverPickerChooseButton'),
              size: M3EButtonSize.md,
              onPressed: _busy ? null : () => unawaited(_pickImage()),
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: M3EProgressIndicator.circular(
                        size: 18,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.image_rounded),
              label: Text(
                _hasCustom ? l10n.coverChangeImage : l10n.coverChooseImage,
              ),
            ),
            if (_hasCustom) ...[
              const SizedBox(height: 8),
              M3EButton.outlined(
                key: const Key('coverPickerResetButton'),
                size: M3EButtonSize.md,
                onPressed: _busy ? null : () => unawaited(_reset()),
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(
                  _isDefault ? l10n.coverResetDefault : l10n.coverResetSong,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
