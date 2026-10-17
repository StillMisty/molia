import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../utils/responsive.dart';
import 'track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文（正式 App 恒有 delegate）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 宽屏表格列是否生效：桌面平台 + **可用内容宽度** ≥ [TrackRowColumns.minWidth]。
///
/// 列表（是否给行传 `columns`）与表头共用这一处判定——分开写两遍迟早
/// 漂移成「有表头没列」或「有列没表头」。窄窗口 / 移动端保持单列行布局
/// （逐像素不变）。
///
/// 用内容宽度而不是窗口宽度：桌面骨架里侧栏展开（240）与队列面板（360）
/// 会吃掉窗口宽度，同样 1200 的窗口内容区可能只剩 600——按窗口判定会给出
/// 固定列宽的行，直接把行撑溢出。调用方在列表处套 `LayoutBuilder` 传
/// `availableWidth`；不传时回退窗口宽（独立挂载 / 测试）。
bool showTrackTableColumns(BuildContext context, {double? availableWidth}) {
  if (!isDesktopPlatform()) return false;
  final width = availableWidth ?? MediaQuery.sizeOf(context).width;
  return width >= TrackRowColumns.minWidth;
}

/// 宽屏表格列表头：艺术家 / 专辑 / 时长三列，列宽与行内 [TrackRowColumns]
/// 同源（改列宽只改常量一处）。
///
/// 与行内列的左缘对齐依赖三段留白，全部在下面按行的实际结构复刻：
/// 行表面内边距 16dp、封面位 44dp + 12dp 间距、标题前间距 12dp、
/// 行尾动作宽度预留。调用方负责与行列表相同的横向页边距。
class TrackTableHeader extends StatelessWidget {
  const TrackTableHeader({super.key});

  /// 行内封面位（`TrackRow.coverSize` 默认值 44）+ 标题前间距 12。
  static const double _leadingWidth = 44 + 12;

  /// 行尾动作（⋮ 菜单，`TrackActionsMenu` 的 `M3EIconButton` md）宽度预留：
  /// 表头没有动作，但不留出这段宽度，三列会整体右移、与行内列错位。
  static const double _trailingReserve = 56;

  /// 行表面（[CardListSurface]）默认的内边距：表头自身没有表面，
  /// 靠同样的内边距与行内容对齐。
  static const EdgeInsets _surfacePadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 6,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final M3EThemeData m3e = M3ETheme.of(context);
    final TextStyle style = m3e.typeScale.labelMedium.copyWith(
      color: m3e.colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: _surfacePadding,
      child: Row(
        children: [
          const SizedBox(width: _leadingWidth),
          // 标题列：行内由标题文本占住（Expanded），表头留空。
          const Expanded(child: SizedBox.shrink()),
          const SizedBox(width: 12),
          _buildCell(
              l10n.tableColumnArtist, TrackRowColumns.artistWidth, style),
          const SizedBox(width: 12),
          _buildCell(l10n.tableColumnAlbum, TrackRowColumns.albumWidth, style),
          const SizedBox(width: 12),
          _buildCell(
            l10n.tableColumnDuration,
            TrackRowColumns.durationWidth,
            style,
          ),
          const SizedBox(width: 12),
          const SizedBox(width: _trailingReserve),
        ],
      ),
    );
  }

  /// 表头单元格：列宽与行内单元格一致（固定宽 + 单行省略）。
  Widget _buildCell(String label, double width, TextStyle style) {
    return SizedBox(
      width: width,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: style,
      ),
    );
  }
}
