import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../providers/library_outcome.dart';
import '../services/haptics.dart';
import '../services/library/playlist_folder_prefs.dart';
import '../theme/m3e_context.dart';
import 'add_to_playlist_sheet.dart' show showPlaylistNameDialog;
import 'playlist_folder_dialog.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载弹层而不注册 delegate，
/// 此时回退到简体中文（与收藏页 / 其它弹层同一约定）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 合集条目：收藏 / 播放历史 / 本地歌曲伪合集（哨兵 id）或一个自建列表。
///
/// 合集弹层只消费这一份值：顺序、图标、数量与选中态由调用方解析好，
/// 弹层本身不读 provider，也不认识合集的持久化规则。
class CollectionPickerEntry {
  const CollectionPickerEntry({
    required this.key,
    required this.id,
    required this.name,
    required this.icon,
    required this.trackCount,
    required this.selected,
    this.playlistId,
    this.isSmart = false,
    this.isHeader = false,
    this.folder = '',
    this.isFolderHeader = false,
    this.folderCollapsed = false,
  });

  /// 顺序持久化键：`favorites` / `history` / `downloads` / `playlist:<id>`。
  final String key;

  /// 选择结果：哨兵值或列表 id。
  final int id;

  final String name;
  final IconData icon;
  final int trackCount;

  /// 当前正在浏览的合集（列表选中态）。
  final bool selected;

  /// 非空表示自建列表（可重命名 / 删除）。
  final int? playlistId;

  /// 智能列表（虚拟身份：不可重命名 / 删除 / 拖动）。
  final bool isSmart;

  /// 分组标题行（不可选、不可拖）。
  final bool isHeader;

  /// 所属分组（空串 = 未分组）。
  final String folder;

  /// 分组标题行（带重命名 / 删除动作）。
  final bool isFolderHeader;

  /// 分组当前是否收起（设备本地状态；仅 [isFolderHeader] 有意义）。
  final bool folderCollapsed;

  CollectionPickerEntry copyWithName(String name) => CollectionPickerEntry(
    key: key,
    id: id,
    name: name,
    icon: icon,
    trackCount: trackCount,
    selected: selected,
    playlistId: playlistId,
    isSmart: isSmart,
    isHeader: isHeader,
    folder: folder,
    isFolderHeader: isFolderHeader,
    folderCollapsed: folderCollapsed,
  );
}

/// 合集弹层结果：切换到某合集 / 请求导入收藏。
class CollectionPickerOutcome {
  const CollectionPickerOutcome.select(this.selectedId)
    : importRequested = false;

  const CollectionPickerOutcome.importRequested()
    : selectedId = null,
      importRequested = true;

  final int? selectedId;
  final bool importRequested;
}

/// 合集切换弹层：点行切换；「新建列表」；「导入收藏」；自建列表行支持
/// 重命名/删除；行尾把手拖动排序（落位即持久化）。
///
/// 取消返回 null。弹层只做本地乐观更新与失败提示，真正的写入由调用方
/// 注入的回调完成（页面 / provider 仍是列表数据的唯一来源）。
Future<CollectionPickerOutcome?> showCollectionPicker(
  BuildContext context, {
  required String title,
  required List<CollectionPickerEntry> entries,
  List<CollectionPickerEntry> smartEntries = const [],
  required ValueChanged<List<String>> onOrderChanged,
  required Future<int> Function(String name) onCreate,
  required Future<LibraryMutationOutcome> Function(int playlistId) onDelete,
  required Future<LibraryMutationOutcome> Function(int playlistId, String name)
  onRename,
  Future<LibraryMutationOutcome> Function(String from, String to)?
  onFolderRename,
  Future<LibraryMutationOutcome> Function(String folder)? onFolderDelete,
  PlaylistFolderCollapseController? folderCollapse,
}) {
  return M3EBottomSheet.show<CollectionPickerOutcome>(
    context,
    builder: (_) => _CollectionPickerSheet(
      title: title,
      entries: entries,
      smartEntries: smartEntries,
      onOrderChanged: onOrderChanged,
      onCreate: onCreate,
      onDelete: onDelete,
      onRename: onRename,
      onFolderRename: onFolderRename,
      onFolderDelete: onFolderDelete,
      folderCollapse: folderCollapse,
    ),
  );
}

class _CollectionPickerSheet extends StatefulWidget {
  const _CollectionPickerSheet({
    required this.title,
    required this.entries,
    required this.smartEntries,
    required this.onOrderChanged,
    required this.onDelete,
    required this.onCreate,
    required this.onRename,
    this.onFolderRename,
    this.onFolderDelete,
    this.folderCollapse,
  });

  final String title;
  final List<CollectionPickerEntry> entries;
  final List<CollectionPickerEntry> smartEntries;
  final ValueChanged<List<String>> onOrderChanged;
  final Future<LibraryMutationOutcome> Function(int playlistId) onDelete;
  final Future<int> Function(String name) onCreate;
  final Future<LibraryMutationOutcome> Function(int playlistId, String name)
  onRename;
  final Future<LibraryMutationOutcome> Function(String from, String to)?
  onFolderRename;
  final Future<LibraryMutationOutcome> Function(String folder)? onFolderDelete;
  final PlaylistFolderCollapseController? folderCollapse;

  @override
  State<_CollectionPickerSheet> createState() => _CollectionPickerSheetState();
}

class _CollectionPickerSheetState extends State<_CollectionPickerSheet> {
  late final List<CollectionPickerEntry> _entries = [
    ...widget.entries,
    ...widget.smartEntries,
  ];

  /// 分组收起状态的唯一持有者（注入时与页面 / 侧栏共享）。
  late final PlaylistFolderCollapseController _collapse =
      widget.folderCollapse ??
      PlaylistFolderCollapseController(
        initiallyCollapsed: {
          for (final entry in widget.entries)
            if (entry.isFolderHeader && entry.folderCollapsed) entry.folder,
        },
      );
  late final bool _ownsCollapse = widget.folderCollapse == null;

  @override
  void initState() {
    super.initState();
    _collapse.addListener(_onCollapseChanged);
    if (_ownsCollapse) unawaited(_collapse.load());
  }

  @override
  void dispose() {
    _collapse.removeListener(_onCollapseChanged);
    if (_ownsCollapse) _collapse.dispose();
    super.dispose();
  }

  void _onCollapseChanged() {
    if (mounted) setState(() {});
  }

  List<String> get _existingNames => [
    for (final entry in _entries)
      if (entry.playlistId != null) entry.name,
  ];

  bool get _hasFolders => widget.entries.any((entry) => entry.isFolderHeader);

  /// 普通合集条目数量（其后是智能列表分组，不参与拖动排序）。
  int get _reorderableCount => widget.entries.length;

  /// 收起的分组隐藏组内列表，分组标题本身仍可见（用于展开）。
  List<CollectionPickerEntry> get _visibleEntries {
    if (!_hasFolders) return _entries;
    final result = <CollectionPickerEntry>[];
    String? hiddenFolder;
    for (final entry in _entries) {
      if (entry.isFolderHeader) {
        hiddenFolder = _collapse.isCollapsed(entry.folder)
            ? entry.folder
            : null;
        result.add(entry);
        continue;
      }
      if (hiddenFolder != null && entry.folder == hiddenFolder) continue;
      result.add(entry);
    }
    return result;
  }

  void _onReorder(int oldIndex, int newIndex) {
    if (_hasFolders ||
        oldIndex >= _reorderableCount ||
        newIndex >= _reorderableCount) {
      // 分组存在时不允许跨分组拖动；智能列表 / 分组标题不参与排序：
      // 把视觉上的移动恢复原状。
      setState(() {
        _entries
          ..clear()
          ..addAll([...widget.entries, ...widget.smartEntries]);
      });
      return;
    }
    setState(() {
      final moved = _entries.removeAt(oldIndex);
      _entries.insert(newIndex, moved);
    });
    widget.onOrderChanged([
      for (var i = 0; i < _reorderableCount; i++) _entries[i].key,
    ]);
  }

  void _toggleFolder(String folder) {
    unawaited(_collapse.toggle(folder));
  }

  Future<void> _renameFolder(CollectionPickerEntry header) async {
    final l10n = _l10n(context);
    final name = await showPlaylistFolderNameDialog(
      context,
      initialValue: header.folder,
    );
    if (name == null || !mounted || name == header.folder) return;
    final rename = widget.onFolderRename;
    if (rename == null) return;
    final outcome = await rename(header.folder, name);
    if (!mounted) return;
    if (outcome.isFailure) {
      _showFailure();
      return;
    }
    // 改到已有分组 = 合并：删除旧分组标题，组内列表接到目标分组下。
    final merging = _entries.any(
      (item) => item.isFolderHeader && item.folder == name,
    );
    setState(() {
      _entries.removeWhere(
        (item) =>
            merging && item.isFolderHeader && item.folder == header.folder,
      );
      for (var index = 0; index < _entries.length; index++) {
        final entry = _entries[index];
        if (entry.isFolderHeader && entry.folder == header.folder) {
          _entries[index] = _copyWithFolder(entry, name);
        } else if (!entry.isFolderHeader && entry.folder == header.folder) {
          _entries[index] = _copyWithFolder(entry, name);
        }
      }
    });
    // 重命名后的新名字按展开处理；合并时目标分组也展开。
    unawaited(_collapse.rename(header.folder, name, merged: merging));
    if (mounted) {
      M3ESnackbar.show(context, message: l10n.playlistFolderRenamed);
    }
  }

  Future<void> _deleteFolder(CollectionPickerEntry header) async {
    final l10n = _l10n(context);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.playlistFolderDelete,
        content: Text(l10n.playlistFolderDeleteConfirm(header.folder)),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final remove = widget.onFolderDelete;
    if (remove == null) return;
    final outcome = await remove(header.folder);
    if (!mounted) return;
    if (outcome.isFailure) {
      _showFailure();
      return;
    }
    setState(() {
      _entries.removeWhere(
        (entry) => entry.isFolderHeader && entry.folder == header.folder,
      );
      for (var index = 0; index < _entries.length; index++) {
        final entry = _entries[index];
        if (!entry.isFolderHeader && entry.folder == header.folder) {
          _entries[index] = _copyWithFolder(entry, '');
        }
      }
    });
    unawaited(_collapse.delete(header.folder));
    if (mounted) {
      M3ESnackbar.show(context, message: l10n.playlistFolderDeleted);
    }
  }

  static CollectionPickerEntry _copyWithFolder(
    CollectionPickerEntry entry,
    String folder,
  ) => CollectionPickerEntry(
    key: entry.key,
    id: entry.id,
    name: entry.name,
    icon: entry.icon,
    trackCount: entry.trackCount,
    selected: entry.selected,
    playlistId: entry.playlistId,
    isSmart: entry.isSmart,
    isHeader: entry.isHeader,
    folder: folder,
    isFolderHeader: entry.isFolderHeader,
    folderCollapsed: entry.folderCollapsed,
  );

  void _showFailure() {
    if (!mounted) return;
    M3ESnackbar.show(context, message: _l10n(context).operationFailed);
  }

  Future<void> _createPlaylist() async {
    final l10n = _l10n(context);
    final name = await showPlaylistNameDialog(
      context,
      title: l10n.playlistCreate,
      confirmLabel: l10n.playlistCreateConfirm,
      existingNames: _existingNames,
    );
    if (name == null || !mounted) return;
    final int id;
    try {
      id = await widget.onCreate(name);
    } catch (_) {
      // 新建失败：留在弹层里提示，不切到一个不存在的合集。
      _showFailure();
      return;
    }
    if (!mounted) return;
    // 新建后直接切换到新列表，便于立即添加曲目。
    Navigator.of(context).pop(CollectionPickerOutcome.select(id));
  }

  Future<void> _rename(CollectionPickerEntry entry) async {
    final l10n = _l10n(context);
    final name = await showPlaylistNameDialog(
      context,
      title: l10n.playlistRename,
      confirmLabel: l10n.saveChanges,
      existingNames: _existingNames,
      initialValue: entry.name,
    );
    if (name == null || !mounted || name == entry.name) return;
    final outcome = await widget.onRename(entry.playlistId!, name);
    if (!mounted) return;
    if (outcome.isFailure) {
      // 写失败：本地乐观副本保持旧名，提示后用户可重试。
      _showFailure();
      return;
    }
    setState(() {
      final index = _entries.indexWhere((item) => item.key == entry.key);
      if (index >= 0) _entries[index] = _entries[index].copyWithName(name);
    });
  }

  Future<void> _confirmDelete(
    BuildContext context,
    CollectionPickerEntry entry,
  ) async {
    final l10n = _l10n(context);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.playlistDelete,
        content: Text(l10n.playlistDeleteConfirm(entry.name)),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    HapticsService.lightImpact();
    final outcome = await widget.onDelete(entry.playlistId!);
    if (!mounted) return;
    if (outcome.isFailure) {
      // 写失败：弹层保留该行（本地副本不做乐观删除）。
      _showFailure();
      return;
    }
    setState(() => _entries.removeWhere((item) => item.key == entry.key));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final visible = _visibleEntries;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行：合集名 + 右侧两个小按钮。
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: context.typeScale.titleMedium,
                  ),
                ),
                // 这是两个工具动作（新建 / 导入）。docs/architecture.md §6 的
                // 目标是收成 icon-only 动作组，但当前依赖版本
                // （material_3_expressive 1.1.7）里 M3EButton 仅当 icon 与
                // label 同时非空才渲染内容，icon-only 动作会退化成空白按钮
                // （上游修复需 ≥ 1.1.8，尚未发布）；在依赖升级前保持两颗标准
                // 图标键：可见、可点，纯图标语义走 semanticLabel，key 保留稳定定位。
                M3EIconButton(
                  key: const Key('favoritesCreatePlaylist'),
                  variant: M3EIconButtonVariant.standard,
                  size: M3EIconButtonSize.sm,
                  semanticLabel: l10n.playlistCreate,
                  icon: const Icon(Icons.add_rounded),
                  onPressed: _createPlaylist,
                ),
                M3EIconButton(
                  key: const Key('favoritesImportCollection'),
                  variant: M3EIconButtonVariant.standard,
                  size: M3EIconButtonSize.sm,
                  semanticLabel: l10n.libraryImportFavorites,
                  icon: const Icon(Icons.library_add_rounded),
                  onPressed: () =>
                      Navigator.of(context)
                          .pop(const CollectionPickerOutcome.importRequested()),
                ),
              ],
            ),
          ),
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              onReorderItem: _onReorder,
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final entry = visible[index];
                if (entry.isFolderHeader) {
                  final collapsed = _collapse.isCollapsed(entry.folder);
                  return Padding(
                    key: ValueKey<String>(entry.key),
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: M3ECard(
                            variant: M3ECardVariant.filled,
                            color: Colors.transparent,
                            elevation: 0,
                            borderRadius: BorderRadius.circular(12),
                            padding: EdgeInsets.zero,
                            onPressed: () => _toggleFolder(entry.folder),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    collapsed
                                        ? Icons.chevron_right_rounded
                                        : Icons.expand_more_rounded,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      entry.folder,
                                      style: context.typeScale.labelLarge,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (widget.onFolderRename != null ||
                            widget.onFolderDelete != null)
                          M3EMenu.entries(
                            position: M3EMenuAnchorPosition.bottomEnd,
                            anchorBuilder: (context, open) => M3EIconButton(
                              variant: M3EIconButtonVariant.standard,
                              size: M3EIconButtonSize.sm,
                              icon: const Icon(Icons.more_vert_rounded),
                              semanticLabel: l10n.playlistFolder,
                              onPressed: open,
                            ),
                            onSelected: (value) {
                              if (value == 'rename') {
                                _renameFolder(entry);
                              } else if (value == 'delete') {
                                _deleteFolder(entry);
                              }
                            },
                            entries: [
                              if (widget.onFolderRename != null)
                                M3EMenuEntry(
                                  label: l10n.playlistFolderRename,
                                  value: 'rename',
                                  leading: const Icon(
                                    Icons.edit_rounded,
                                    size: 20,
                                  ),
                                ),
                              if (widget.onFolderDelete != null)
                                M3EMenuEntry(
                                  label: l10n.playlistFolderDelete,
                                  value: 'delete',
                                  isDestructive: true,
                                  leading: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 20,
                                  ),
                                ),
                            ],
                          ),
                      ],
                    ),
                  );
                }
                if (entry.isHeader) {
                  return KeyedSubtree(
                    key: ValueKey<String>(entry.key),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                      child: Text(
                        entry.name,
                        style: context.typeScale.labelMedium.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  );
                }
                return M3EListItem(
                  key: ValueKey<String>(entry.key),
                  leading: Icon(entry.icon),
                  headline: entry.name,
                  // 数量走 M3E 元文本槽（选中态自带配色）；当前合集只靠
                  // selected 高亮（选中容器），不叠对号图标。
                  trailingText: l10n.playlistTrackCount(entry.trackCount),
                  selected: entry.selected,
                  onTap: () =>
                      Navigator.of(context)
                          .pop(CollectionPickerOutcome.select(entry.id)),
                  trailing: entry.isSmart
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (entry.playlistId != null)
                              M3EMenu.entries(
                                position: M3EMenuAnchorPosition.bottomEnd,
                                anchorBuilder: (context, open) => M3EIconButton(
                                  variant: M3EIconButtonVariant.standard,
                                  icon: const Icon(Icons.more_vert_rounded),
                                  semanticLabel: l10n.playlistRename,
                                  onPressed: open,
                                ),
                                onSelected: (value) {
                                  if (value == 'rename') {
                                    _rename(entry);
                                  } else if (value == 'delete') {
                                    _confirmDelete(context, entry);
                                  }
                                },
                                entries: [
                                  M3EMenuEntry(
                                    label: l10n.playlistRename,
                                    value: 'rename',
                                    leading: const Icon(
                                      Icons.edit_rounded,
                                      size: 20,
                                    ),
                                  ),
                                  M3EMenuEntry(
                                    label: l10n.playlistDelete,
                                    value: 'delete',
                                    isDestructive: true,
                                    leading: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 20,
                                    ),
                                  ),
                                ],
                              ),
                            if (!_hasFolders)
                              ReorderableDragStartListener(
                                index: index,
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 8),
                                  child: Icon(Icons.drag_handle_rounded),
                                ),
                              ),
                          ],
                        ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
