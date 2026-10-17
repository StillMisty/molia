import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import 'track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文（正式 App 恒有 delegate）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 宽屏表格列表头：艺术家 / 专辑 / 时长三列，列宽与行内 [TrackRowColumns]
/// 同源（改列宽只改常量一处）。
///
/// 是否渲染由调用方按 `DesktopLayout.tableColumnsAt(内容宽)` 判定（判据唯一
/// 在 desktop_layout.dart）；列表（是否给行传 `columns`）与表头必须共用同一
/// 判定，否则迟早漂移成「有表头没列」或「有列没表头」。
///
/// 与行内列的左缘对齐依赖三段留白，全部在下面按行的实际结构复刻：
/// 行表面内边距 16dp、封面位 44dp + 12dp 间距、标题前间距 12dp、
/// 行尾固定槽宽（`TrackRowColumns.trailingSlotWidth`）。调用方负责与行列表
/// 相同的横向页边距。
class TrackTableHeader extends StatelessWidget {
  const TrackTableHeader({super.key});

  /// 行内封面位（`TrackRow.coverSize` 默认值 44）+ 标题前间距 12。
  static const double _leadingWidth = 44 + 12;

  /// 行表面（[CardListSurface]）默认的内边距：表头自身没有表面，
  /// 靠同样的内边距与行内容对齐。
  static const EdgeInsets _surfacePadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 6,
  );

  /// 表头高度（钉住表头的 sliver 需要预声明 extent）：一行 `labelMedium`
  /// 加上下内边距，随系统文字缩放同步放大（大字号下不裁切）。
  static double extentOf(BuildContext context) {
    final style = M3ETheme.of(context).typeScale.labelMedium;
    final scaledSize =
        MediaQuery.textScalerOf(context).scale(style.fontSize ?? 12);
    // 段落行高按整像素结算：向上取整（容 1e-6 浮点尾差），避免 extent 比
    // 实际高度少零点几像素、钉住时把行尾裁掉。
    final lineHeight =
        (scaledSize * (style.height ?? 1.2) - 1e-6).ceilToDouble();
    return lineHeight + _surfacePadding.vertical;
  }

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
          // 行尾槽宽与行内同源：表头没有动作，但不留出这段宽度，三列会
          // 整体右移、与行内列错位。
          const SizedBox(width: TrackRowColumns.trailingSlotWidth),
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
