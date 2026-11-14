/// 列表增强的四个弹层：详情、分享、导出、导入复核。
///
/// 每个弹层只有一层 modal；详情不嵌套封面选择，导出格式只在导出弹层里出现，
/// 分享的图片 / 文本是同一层的两个 section。弹层只做展示与回调，读写由页面
/// / provider 注入。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/library.dart';
import '../domain/models/playlist_folders.dart';
import '../l10n/app_localizations.dart';
import '../services/playlist/playlist_import_service.dart';
import '../services/poster/playlist_poster_layout.dart';
import '../services/poster/playlist_poster_renderer.dart';
import '../theme/m3e_context.dart';
import '../theme/poster_palette.dart';
import '../utils/file_name.dart';
import '../utils/responsive.dart';
import 'empty_state.dart';
import 'poster_share_sheet.dart';
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
  String? _folderError;

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
    // 收藏列表不支持分组：即使输入框被隐藏，也不把旧值意外写回。
    var folder = '';
    if (!widget.playlist.isFavorites) {
      final check = checkPlaylistFolderName(_folder.text);
      if (!check.isValid) {
        setState(() {
          _folderError = switch (check.issue!) {
            PlaylistFolderNameIssue.tooLong => l10n.playlistFolderNameTooLong,
            PlaylistFolderNameIssue.controlCharacters =>
              l10n.playlistFolderNameInvalid,
          };
        });
        return;
      }
      folder = check.normalized;
    }
    setState(() {
      _busy = true;
      _nameError = null;
      _folderError = null;
    });
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
              errorText: _folderError,
              onChanged: (_) {
                if (_folderError != null) setState(() => _folderError = null);
              },
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

// 分享

/// 列表分享弹层：与听歌统计 / 年度报告共用统一结构。
///
/// 预览海报在弹层内生成；主操作只有分享，保存图片与复制文本是次要输出。
Future<void> showPlaylistShareSheet(
  BuildContext context, {
  required PlaylistShareContent content,
  required Future<List<Uint8List?>> Function() loadCovers,
  required PosterPalette palette,
  String? fontFamily,
  List<String>? fontFamilyFallback,
  PosterFileShare? shareFile,
}) {
  final l10n = _l10n(context);
  return showPosterShareSheet(
    context,
    title: l10n.playlistShare,
    renderPoster: () async {
      if (content.tracks.isEmpty) return null;
      final covers = await loadCovers();
      return const PlaylistPosterRenderer().render(
        content: content,
        covers: covers,
        palette: palette,
        fontFamily: fontFamily,
        fontFamilyFallback: fontFamilyFallback,
        watermarkText: l10n.appName,
      );
    },
    shareText: content.name,
    fileName: '${sanitizeFileName(content.name, fallback: 'playlist')}.png',
    saveDialogTitle: l10n.shareSaveImage,
    emptyMessage: l10n.playlistShareEmpty,
    copyText: content.tracks.isEmpty ? null : content.toShareText(),
    shareFile: shareFile,
  );
}

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
          M3EListItem(
            key: const Key('playlistExportMolia'),
            leading: const Icon(Icons.inventory_2_rounded),
            headline: l10n.playlistExportMolia,
            supportingText: moliaAvailable
                ? l10n.playlistExportMoliaSubtitle
                : l10n.playlistExportMoliaUnavailable,
            enabled: moliaAvailable,
            onTap: moliaAvailable
                ? () => Navigator.of(context).pop(PlaylistExportFormat.molia)
                : null,
          ),
        ],
      ),
    );
  }
}

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
