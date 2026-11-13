/// 列表增强的四个弹层：详情、分享、导出、导入复核。
///
/// 每个弹层只有一层 modal；详情不嵌套封面选择，导出格式只在导出弹层里出现，
/// 分享的图片 / 文本是同一层的两个 section。弹层只做展示与回调，读写由页面
/// / provider 注入。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/models/library.dart';
import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../services/playlist/playlist_import_service.dart';
import '../services/poster/playlist_poster_layout.dart';
import '../services/poster/playlist_poster_renderer.dart';
import '../services/save_as.dart';
import '../theme/m3e_context.dart';
import '../theme/poster_palette.dart';
import '../utils/responsive.dart';
import '../utils/save_as_label.dart';
import 'empty_state.dart';
import 'simple_modal_body.dart';

AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 描述 / 分组不接受控制字符（换行由多行描述自己处理）。
final RegExp _controlCharacters = RegExp(
  r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]',
);

/// 列表详情弹层：名称 / 描述 / 分组一次保存。
Future<bool?> showPlaylistDetailsSheet(
  BuildContext context, {
  required PlaylistInfo playlist,
  required List<String> existingNames,
  required Future<bool> Function(String name, String description, String folder)
  onSave,
}) {
  return ResponsiveNavigation.showSimpleModal<bool>(
    context: context,
    title: _l10n(context).playlistDetails,
    child: PlaylistDetailsSheet(
      playlist: playlist,
      existingNames: existingNames,
      onSave: onSave,
    ),
  );
}

class PlaylistDetailsSheet extends StatefulWidget {
  const PlaylistDetailsSheet({
    super.key,
    required this.playlist,
    required this.existingNames,
    required this.onSave,
  });

  final PlaylistInfo playlist;

  /// 其它列表名称（同名检查；不包含当前列表）。
  final List<String> existingNames;

  /// 保存回调；返回 false 表示写失败（弹层保留输入）。
  final Future<bool> Function(String name, String description, String folder)
  onSave;

  @override
  State<PlaylistDetailsSheet> createState() => _PlaylistDetailsSheetState();
}

class _PlaylistDetailsSheetState extends State<PlaylistDetailsSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.playlist.isFavorites
        ? _l10n(context).favoritesPlaylistName
        : widget.playlist.name,
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.playlist.description,
  );
  late final TextEditingController _folder = TextEditingController(
    text: widget.playlist.folder,
  );
  bool _busy = false;
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _folder.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final l10n = _l10n(context);
    // 收藏行的存储名是保留值，不能被本地化展示名覆盖。
    final name = widget.playlist.isFavorites
        ? widget.playlist.name
        : _name.text.trim();
    if (!widget.playlist.isFavorites) {
      if (name.isEmpty) {
        setState(() => _nameError = l10n.playlistNameRequired);
        return;
      }
      if (name != widget.playlist.name && widget.existingNames.contains(name)) {
        setState(() => _nameError = l10n.playlistNameExists);
        return;
      }
    }
    setState(() {
      _busy = true;
      _nameError = null;
    });
    // 收藏列表不支持分组：即使输入框被隐藏，也不把旧值意外写回。
    final folder = widget.playlist.isFavorites ? '' : _folder.text.trim();
    final ok = await widget.onSave(name, _description.text.trim(), folder);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _busy = false);
    M3ESnackbar.show(context, message: l10n.playlistSaveDetailsFailed);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return SafeArea(
      child: SimpleModalBody(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          if (widget.playlist.isFavorites)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                widget.playlist.isFavorites
                    ? l10n.favoritesPlaylistName
                    : widget.playlist.name,
                style: context.typeScale.titleMedium,
              ),
            )
          else
            M3ETextField(
              key: const Key('playlistDetailsName'),
              controller: _name,
              label: l10n.playlistCreateHint,
              errorText: _nameError,
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
            ),
          const SizedBox(height: 12),
          M3ETextField(
            key: const Key('playlistDetailsDescription'),
            controller: _description,
            label: l10n.playlistDescription,
            placeholder: l10n.playlistDescriptionHint,
            maxLines: 3,
            maxLength: 280,
            inputFormatters: [
              FilteringTextInputFormatter.deny(_controlCharacters),
            ],
          ),
          if (!widget.playlist.isFavorites) ...[
            const SizedBox(height: 12),
            M3ETextField(
              key: const Key('playlistDetailsFolder'),
              controller: _folder,
              label: l10n.playlistFolder,
              placeholder: l10n.playlistFolderHint,
              maxLength: 40,
              inputFormatters: [
                FilteringTextInputFormatter.deny(_controlCharacters),
              ],
            ),
          ],
          const SizedBox(height: 16),
          M3EButton.filled(
            key: const Key('playlistDetailsSave'),
            onPressed: _busy ? null : () => unawaited(_save()),
            child: Text(l10n.saveChanges),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 分享

/// 分享弹层：图片 / 文本两个 section（同一层，不做 tabs）。
Future<void> showPlaylistShareSheet(
  BuildContext context, {
  required PlaylistShareContent content,
  required Future<List<Uint8List?>> Function() loadCovers,
  required PosterPalette palette,
  String? fontFamily,
  List<String>? fontFamilyFallback,
}) {
  return ResponsiveNavigation.showSimpleModal<void>(
    context: context,
    title: _l10n(context).playlistShare,
    child: PlaylistShareSheet(
      content: content,
      loadCovers: loadCovers,
      palette: palette,
      fontFamily: fontFamily,
      fontFamilyFallback: fontFamilyFallback,
    ),
  );
}

class PlaylistShareSheet extends StatefulWidget {
  const PlaylistShareSheet({
    super.key,
    required this.content,
    required this.loadCovers,
    required this.palette,
    this.fontFamily,
    this.fontFamilyFallback,
  });

  final PlaylistShareContent content;

  /// 读取本机封面字节（顺序即马赛克槽位）；不返回任何路径。
  final Future<List<Uint8List?>> Function() loadCovers;

  final PosterPalette palette;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;

  @override
  State<PlaylistShareSheet> createState() => _PlaylistShareSheetState();
}

class _PlaylistShareSheetState extends State<PlaylistShareSheet> {
  Uint8List? _image;
  bool _generating = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.content.tracks.isNotEmpty) unawaited(_generate());
  }

  Future<void> _generate() async {
    if (_generating) return;
    setState(() {
      _generating = true;
      _failed = false;
    });
    final watermark = _l10n(context).appName;
    try {
      final covers = await widget.loadCovers();
      final bytes = await const PlaylistPosterRenderer().render(
        content: widget.content,
        covers: covers,
        palette: widget.palette,
        fontFamily: widget.fontFamily,
        fontFamilyFallback: widget.fontFamilyFallback,
        watermarkText: watermark,
      );
      if (mounted) setState(() => _image = bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  NotificationService? get _notifications =>
      context.read<NotificationService?>();

  void _message(String text) {
    final service = _notifications;
    if (service != null) {
      service.showSnackBar(text);
    } else {
      M3ESnackbar.show(context, message: text);
    }
  }

  Future<void> _shareImage() async {
    final bytes = _image;
    if (bytes == null) return;
    final file = File(
      p.join(
        Directory.systemTemp.path,
        'molia_playlist_${DateTime.now().microsecondsSinceEpoch}.png',
      ),
    );
    try {
      await file.writeAsBytes(bytes, flush: true);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: widget.content.name),
      );
    } catch (_) {
      if (mounted) _message(_l10n(context).playlistShareFailed);
    }
  }

  Future<void> _saveImage() async {
    final bytes = _image;
    final saveAs = context.read<SaveAs?>();
    if (bytes == null || saveAs == null) return;
    final l10n = _l10n(context);
    final result = await saveAs.saveBytes(
      fileName: '${_safeFileName(widget.content.name)}.png',
      bytes: bytes,
      mimeType: 'image/png',
      relativeDir: saveAsPostersDirName,
      dialogTitle: l10n.playlistShareImage,
    );
    if (!mounted) return;
    switch (result) {
      case SaveAsSaved(:final displayPath, :final kind):
        _message(savedLocationMessage(l10n, kind, displayPath));
      case SaveAsCancelled():
        break;
      case SaveAsFailed():
        _message(l10n.playlistShareFailed);
    }
  }

  Future<void> _shareText() async {
    try {
      await SharePlus.instance.share(
        ShareParams(text: widget.content.toShareText()),
      );
    } catch (_) {
      if (mounted) _message(_l10n(context).playlistExportFailed);
    }
  }

  Future<void> _copyText() async {
    await Clipboard.setData(ClipboardData(text: widget.content.toShareText()));
    if (mounted) _message(_l10n(context).playlistShareCopied);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final hasTracks = widget.content.tracks.isNotEmpty;
    return SafeArea(
      child: SimpleModalBody(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          if (!hasTracks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: EmptyState(
                icon: Icons.queue_music_rounded,
                message: l10n.playlistShareEmpty,
              ),
            )
          else ...[
            _SectionTitle(l10n.playlistShareImage),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.playlistShareImageSubtitle,
                style: context.typeScale.bodySmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_generating)
              Row(
                children: [
                  const SizedBox.square(
                    dimension: 18,
                    child: M3EProgressIndicator.circular(
                      size: 18,
                      strokeWidth: 2,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(l10n.playlistShareGenerating),
                ],
              )
            else if (_failed)
              Row(
                children: [
                  Expanded(child: Text(l10n.playlistShareFailed)),
                  M3EButton.text(
                    onPressed: () => unawaited(_generate()),
                    child: Text(l10n.retryButton),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: M3EButton.filled(
                      key: const Key('playlistShareImageAction'),
                      onPressed: _image == null
                          ? null
                          : () => unawaited(_shareImage()),
                      child: Text(l10n.playlistShareImage),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: M3EButton.outlined(
                      key: const Key('playlistShareSaveImage'),
                      onPressed: _image == null
                          ? null
                          : () => unawaited(_saveImage()),
                      child: Text(l10n.playlistShareSaveImage),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 24),
            _SectionTitle(l10n.playlistShareText),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                l10n.playlistShareTextSubtitle,
                style: context.typeScale.bodySmall.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: M3EButton.outlined(
                    key: const Key('playlistShareTextAction'),
                    onPressed: () => unawaited(_shareText()),
                    child: Text(l10n.playlistShareText),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: M3EButton.outlined(
                    onPressed: () => unawaited(_copyText()),
                    child: Text(l10n.playlistShareCopyText),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(text, style: context.typeScale.titleMedium),
    );
  }
}

// ---------------------------------------------------------------------------
// 导出

/// 导出格式。
enum PlaylistExportFormat { m3u8, molia }

/// 导出弹层：M3U8（默认）与 Molia 全保真文件。
Future<PlaylistExportFormat?> showPlaylistExportSheet(
  BuildContext context, {
  bool moliaAvailable = true,
}) {
  return ResponsiveNavigation.showSimpleModal<PlaylistExportFormat>(
    context: context,
    title: _l10n(context).playlistExport,
    child: PlaylistExportSheet(moliaAvailable: moliaAvailable),
  );
}

class PlaylistExportSheet extends StatelessWidget {
  const PlaylistExportSheet({super.key, this.moliaAvailable = true});

  /// 没有同步引擎（组合根未装配）时不提供全保真文件。
  final bool moliaAvailable;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return SafeArea(
      child: SimpleModalBody(
        children: [
          M3EListItem(
            key: const Key('playlistExportM3u8'),
            leading: const Icon(Icons.playlist_play_rounded),
            headline: l10n.playlistExportM3u8,
            supportingText: l10n.playlistExportM3u8Subtitle,
            onTap: () => Navigator.of(context).pop(PlaylistExportFormat.m3u8),
          ),
          if (moliaAvailable)
            M3EListItem(
              key: const Key('playlistExportMolia'),
              leading: const Icon(Icons.inventory_2_rounded),
              headline: l10n.playlistExportMolia,
              supportingText: l10n.playlistExportMoliaSubtitle,
              onTap: () =>
                  Navigator.of(context).pop(PlaylistExportFormat.molia),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 导入复核

/// 导入复核弹层：列出未解析条目并明确「确认后跳过这些」。
Future<bool?> showPlaylistImportReviewSheet(
  BuildContext context, {
  required PlaylistImportPlan plan,
}) {
  return ResponsiveNavigation.showSimpleModal<bool>(
    context: context,
    title: _l10n(context).playlistImportReviewTitle,
    child: PlaylistImportReviewSheet(plan: plan),
  );
}

class PlaylistImportReviewSheet extends StatelessWidget {
  const PlaylistImportReviewSheet({super.key, required this.plan});

  final PlaylistImportPlan plan;

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    return SafeArea(
      child: SimpleModalBody(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          if (!plan.canImport)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: EmptyState(
                icon: Icons.playlist_remove_rounded,
                message: l10n.playlistImportEmpty,
              ),
            )
          else
            Text(
              l10n.playlistImportResolved(plan.resolved.length),
              style: context.typeScale.titleMedium,
            ),
          if (plan.issues.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              l10n.playlistImportUnresolved(plan.unresolvedCount),
              style: context.typeScale.bodyMedium.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (final issue in plan.issues)
              M3EListItem(
                leading: const Icon(Icons.error_outline_rounded),
                headline: issue.displayName,
                supportingText: _issueReason(l10n, issue.reason),
              ),
            const SizedBox(height: 8),
            Text(
              l10n.playlistImportSkipNote(plan.unresolvedCount),
              style: context.typeScale.bodySmall.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: M3EButton.text(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.cancel),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: M3EButton.filled(
                  key: const Key('playlistImportConfirm'),
                  onPressed: plan.canImport
                      ? () => Navigator.of(context).pop(true)
                      : null,
                  child: Text(l10n.playlistImportConfirm(plan.resolved.length)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _issueReason(AppLocalizations l10n, PlaylistImportIssueReason reason) =>
    switch (reason) {
      PlaylistImportIssueReason.localUnavailable =>
        l10n.playlistImportReasonLocalUnavailable,
      PlaylistImportIssueReason.keyUnresolved =>
        l10n.playlistImportReasonKeyUnresolved,
      PlaylistImportIssueReason.onlineUrl => l10n.playlistImportReasonOnlineUrl,
      PlaylistImportIssueReason.malformed => l10n.playlistImportReasonMalformed,
      PlaylistImportIssueReason.noLocation =>
        l10n.playlistImportReasonNoLocation,
    };

String _safeFileName(String value) {
  final trimmed = value.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return trimmed.isEmpty ? 'playlist' : trimmed;
}
