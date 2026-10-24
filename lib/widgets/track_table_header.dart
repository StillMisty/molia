import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import 'track_row.dart';

/// AppLocalizations 查找：测试等场景可能直接挂载本组件而不注册 delegate，
/// 此时回退到简体中文（正式 App 恒有 delegate）。
AppLocalizations _l10n(BuildContext context) =>
    AppLocalizations.of(context) ?? lookupAppLocalizations(const Locale('zh'));

/// 宽屏表格列表头：艺术家 / 专辑 /（播放时间）/ 时长列，列宽与列构成走
/// 行内同一份 [TrackRowColumnSpec]（改列宽只改规范一处）。
///
/// 是否渲染由调用方按 `DesktopLayout.tableColumns` 判定（判据唯一在
/// desktop_layout.dart）；列表（是否给行传 `columns`）与表头必须共用同一
/// 判定、同一 spec，否则迟早漂移成「有表头没列」或「有列没表头」。
///
/// 与行内列的左缘对齐依赖行内网格的几段留白，全部按行的实际结构复刻：
/// 行表面内边距（`M3EListItemTheme.horizontalPadding`）、封面位
/// （[TrackRow.defaultCoverSize] + 列表 token 的槽间距）、列间距（同一
/// 槽间距 token）、行尾固定槽宽（`TrackRowColumnSpec.trailingSlotWidth`）。
/// 调用方负责与行列表相同的横向页边距。
class TrackTableHeader extends StatelessWidget {
  const TrackTableHeader({
    super.key,
    this.spec = TrackRowColumnSpec.standard,
  });

  /// 列宽 / 列构成：与行内 [TrackRowSurface.tableSpec] 传同一份（行与表头必须
  /// 用同一个 spec —— 表头只看规范，不看单行内容）。
  final TrackRowColumnSpec spec;

  /// 表头纵向内边距（上下各 6dp）：钉住表头的 sliver 预声明 extent 也要
  /// 算进去，见 [extentOf]。
  static const double _verticalPadding = 6;

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
    return lineHeight + _verticalPadding * 2;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n(context);
    final M3EThemeData m3e = M3ETheme.of(context);
    // 行内网格的 token 口径：表面内边距与列间距（与 TrackRow 同一批值）。
    final M3EListItemTheme itemTheme = m3e.listTheme.item;
    final double gap = itemTheme.gap;
    final TextStyle style = m3e.typeScale.labelMedium.copyWith(
      color: m3e.colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: itemTheme.horizontalPadding,
        vertical: _verticalPadding,
      ),
      child: Row(
        children: [
          // 行内封面位 + 标题前间距：表头自身没有封面，但要让出同一段宽度。
          SizedBox(width: TrackRow.defaultCoverSize + gap),
          // 标题列：行内由标题文本占住（Expanded），表头留空。
          const Expanded(child: SizedBox.shrink()),
          SizedBox(width: gap),
          _buildCell(l10n.tableColumnArtist, spec.artistWidth, style),
          SizedBox(width: gap),
          _buildCell(l10n.tableColumnAlbum, spec.albumWidth, style),
          if (spec.hasTimeColumn) ...[
            SizedBox(width: gap),
            _buildCell(l10n.tableColumnPlayedAt, spec.timeWidth, style),
          ],
          SizedBox(width: gap),
          _buildCell(l10n.tableColumnDuration, spec.durationWidth, style),
          SizedBox(width: gap),
          // 行尾槽宽与行内同源：表头没有动作，但不留出这段宽度，列会整体
          // 右移、与行内列错位。
          const SizedBox(width: TrackRowColumnSpec.trailingSlotWidth),
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
