/// 共享封面选择弹层：每曲封面与全局默认封面共用一套交互。
///
/// 入口：
/// - 播放页歌曲信息「歌曲封面」行；
/// - 歌词海报预览页「封面」行；
/// - 设置 › 外观「默认封面」行。
///
/// 选图 → 归一化（`CoverImageCodec`）→ 本地存储（`CustomCoverStore`）→
/// Snackbar 反馈；有真实封面时可直接进 `CoverViewer` 看原图 / 保存原图。
/// 失败只显示友好文案，不把异常字符串带给用户。
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
import '../services/covers/cover_resolution.dart';
import '../services/covers/custom_cover_store.dart';
import '../services/haptics.dart';
import '../services/notification_service.dart';
import '../utils/responsive.dart';
import 'cover_viewer.dart';
import 'track_artwork.dart';

/// 文件选择（测试可注入；返回未归一的原始字节）。
typedef CoverImagePicker = Future<Uint8List?> Function();

/// 图片归一化（测试可注入；默认 [CoverImageCodec.normalize]）。
typedef CoverImageNormalizer = Future<Uint8List> Function(Uint8List bytes);

/// 打开封面选择弹层。
///
/// [trackId] 为空 = 编辑全局默认封面；非空 = 编辑该曲目的自定义封面。
/// [originalCoverUrl] 仅用于「跟随歌曲」时的预览；[fileNameBase] 是
/// 「查看原图 → 保存原图」的文件名基名（缺省用弹层标题）。
Future<void> showCoverPickerSheet(
  BuildContext context, {
  TrackId? trackId,
  String? originalCoverUrl,
  String? fileNameBase,
  CoverImagePicker? pickImage,
  CoverImageNormalizer? normalize,
}) {
  final l10n = AppLocalizations.of(context) ??
      lookupAppLocalizations(const Locale('zh'));
  return ResponsiveNavigation.showSimpleModal<void>(
    context: context,
    title: trackId == null ? l10n.coverDefaultTitle : l10n.coverTitle,
    child: CoverPickerSheet(
      trackId: trackId,
      originalCoverUrl: originalCoverUrl,
      fileNameBase: fileNameBase,
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
    this.fileNameBase,
    this.pickImage,
    this.normalize,
  });

  final TrackId? trackId;
  final String? originalCoverUrl;
  final String? fileNameBase;
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

  CustomCoverStore get _store => coverStoreOf(context);

  CoverResolver get _covers => coverResolverOf(context);

  bool get _isDefault => widget.trackId == null;

  bool get _hasOriginal =>
      !_isDefault && (widget.originalCoverUrl ?? '').isNotEmpty;

  bool get _hasCustom => _isDefault
      ? _covers.defaultCoverUrl != null
      : _covers.realForId(widget.trackId).isCustom;

  /// 「查看原图」地址：默认封面模式看默认图；曲目模式只看真实封面
  /// （自定义 > 原始），没有真实封面时预览里的默认占位不提供原图。
  String? get _viewerCoverUrl => _isDefault
      ? _covers.defaultCoverUrl
      : _covers
          .realForId(widget.trackId, originalUrl: widget.originalCoverUrl)
          .url;

  Future<void> _pickImage() async {
    if (_busy) return;
    final l10n = _l10n(context);
    HapticsService.selectionClick();
    setState(() => _busy = true);
    try {
      final picker = widget.pickImage;
      final raw =
          picker != null ? await picker() : await _pickImageFromDevice(l10n);
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
      _showMessage(
        _isDefault ? l10n.coverDefaultRestored : l10n.coverRestored,
      );
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
    final subtitle = _isDefault
        ? l10n.coverDefaultSubtitle
        : _hasCustom
            ? l10n.coverCustomized
            : (_hasOriginal ? l10n.coverFollowSong : l10n.coverDefaultTitle);
    final viewerUrl = _viewerCoverUrl;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              subtitle,
              style: m3e.typeScale.bodyMedium.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: CoverChangeBuilder(
                builder: (context, _) => TrackArtwork(
                  key: const Key('coverPickerPreview'),
                  // 外层已订阅；默认封面模式没有曲目身份，直接展示默认图。
                  listenForChanges: false,
                  trackId: widget.trackId,
                  originalUrl: widget.originalCoverUrl,
                  width: 120,
                  height: 120,
                  // 方形预览按 cover 裁切；原图查看走 cover_viewer 的 contain。
                  fit: BoxFit.cover,
                  borderRadius: BorderRadius.circular(16),
                  memCacheWidth:
                      (120 * MediaQuery.of(context).devicePixelRatio).round(),
                  fallbackIconSize: 48,
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
            if (viewerUrl != null) ...[
              const SizedBox(height: 8),
              M3EButton.outlined(
                key: const Key('coverPickerViewButton'),
                size: M3EButtonSize.md,
                onPressed: _busy
                    ? null
                    : () => unawaited(
                          showCoverViewer(
                            context,
                            coverUrl: viewerUrl,
                            title: _isDefault
                                ? l10n.coverDefaultTitle
                                : l10n.coverTitle,
                            fileNameBase: widget.fileNameBase ??
                                (_isDefault
                                    ? l10n.coverDefaultTitle
                                    : l10n.coverTitle),
                          ),
                        ),
                icon: const Icon(Icons.zoom_out_map_rounded),
                label: Text(l10n.coverViewOriginal),
              ),
            ],
            if (_hasCustom) ...[
              const SizedBox(height: 8),
              M3EButton.outlined(
                key: const Key('coverPickerResetButton'),
                size: M3EButtonSize.md,
                onPressed: _busy ? null : () => unawaited(_reset()),
                icon: const Icon(Icons.restart_alt_rounded),
                label: Text(
                  _isDefault
                      ? l10n.coverResetDefault
                      : (_hasOriginal
                          ? l10n.coverResetSong
                          : l10n.coverResetToDefault),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
