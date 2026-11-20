/// 设置行共享骨架与分组容器（M3E 列表规范）。
///
/// 分组 / 行形状 / 图标底 / 标题排布只在这里演进；各 tile 只补自己的行尾
/// 控件与交互，避免同一页出现不同图标尺寸、行尾间距或禁用透明度。
library;

import 'dart:math' as math;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../responsive.dart';
import '../../card_list_surface.dart';
import '../../m3e_page_route.dart';
import '../../../theme/motion_policy.dart';

/// 设置页统一间距常量。
const double kSettingsPadding = 16.0;
const double kSettingsSectionSpacing = 24.0;
const double kSettingsElementSpacing = 16.0;
const double kSettingsSmallSpacing = 8.0;

/// 设置行统一内边距（标签行 / 复合行同用；行高 token 的计算基准）。
const EdgeInsets kSettingsRowPadding = EdgeInsets.symmetric(
  horizontal: 12,
  vertical: 8,
);

/// 行首图标与标题之间的统一间距。
const double _settingsTileLeadGap = 12.0;

/// 行尾动作图标（chevron / 编辑）的统一尺寸。
const double kSettingsTileActionSize = 20.0;

/// 在设置弹层内部打开子页（不新开弹层）。
///
/// 设置弹层壳（`settings_sheet.dart`）内部有一层 Navigator：这里 push 到
/// 最近一层 Navigator，弹层内使用时即为设置内部导航（返回键先退子页、再关
/// 弹层）；独立挂载（测试等）时等价普通页面 push。
Future<T?> openSettingsSubPage<T>(BuildContext context, Widget page) {
  return Navigator.of(context).push<T>(M3EPageRoute<T>(builder: (_) => page));
}

/// 设置弹层内 dialog 的统一宽度（弹层窄于屏幕，弹窗跟随弹层宽度）。
double settingsDialogWidth(BuildContext context) {
  return math.min(
    MediaQuery.sizeOf(context).width * 0.9,
    context.layoutType(ResponsivePageType.modal).modalWidth,
  );
}

/// 分段行位置：由 [SettingsSectionCard] 按子项下标下发（M3E 列表卡片形状：
/// 内行 4dp / 首末外侧 16dp）。子项自行构造时缺省为 single。
class SettingsRowPosition extends InheritedWidget {
  const SettingsRowPosition({
    super.key,
    required this.position,
    required super.child,
  });

  final M3ECardPosition position;

  static M3ECardPosition of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SettingsRowPosition>()
          ?.position ??
      M3ECardPosition.single;

  @override
  bool updateShouldNotify(SettingsRowPosition oldWidget) =>
      oldWidget.position != position;
}

/// 设置分组：标题 + 分段卡片行（M3E 列表规范：行间 `cardList.gap`）。
///
/// 行表面由各 tile 经 [CardListSurface] 自绘（形状按分组内位置：内行 4dp、
/// 首末外侧 16dp；hover 12dp、press 16dp，形状走 spatial 弹簧）。
/// [footer] 是卡片下方的分组说明（如排序规则、空态引导），由调用方给文案。
class SettingsSectionCard extends StatelessWidget {
  const SettingsSectionCard({
    super.key,
    this.title,
    required this.children,
    this.footer,
  });

  final String? title;
  final List<Widget> children;

  /// 卡片下方的说明文字（[SettingsSectionHint] 或任意组件）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty && footer == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final m3e = M3ETheme.of(context);
    final gap = m3e.listTheme.cardList.gap;
    // 条件行（[SettingsReveal]）隐藏时高度为 0，但仍是树上的一个子项：形状
    // 计算必须只数可见行，否则隐藏的末行会让上一条可见行停留在「内行」
    // 4dp 圆角，卡片底部看起来是断的。
    final visible = [
      for (final child in children)
        child is SettingsReveal ? child.visible : true,
    ];
    final visibleCount = visible.where((show) => show).length;
    var visibleIndex = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, kSettingsSmallSpacing),
            child: Text(
              title!,
              style: m3e.typeScale.titleSmall.copyWith(
                // 分组标题是结构标签，不用强调色（强调色只给交互/选中）。
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        for (var i = 0; i < children.length; i++)
          if (visible[i]) ...[
            if (visibleIndex > 0) SizedBox(height: gap),
            SettingsRowPosition(
              position: calculateCardPosition(visibleIndex++, visibleCount),
              child: children[i],
            ),
          ] else
            // 隐藏的条件行不占行位 / 行距，只保留自身的高度动画（收为 0）。
            children[i],
        if (footer != null) ...[
          const SizedBox(height: kSettingsSmallSpacing),
          footer!,
        ],
      ],
    );
  }
}

/// 分组说明文字：卡片下方的次要文本（排序规则 / 空态引导等）。
class SettingsSectionHint extends StatelessWidget {
  const SettingsSectionHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final theme = Theme.of(context);
    return Text(
      text,
      style: m3e.typeScale.bodySmall.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// 分段卡片行容器（M3E 列表规范：行间 `cardList.gap`，行首末外侧 16dp）。
///
/// 用于「一个分组内多行由同一个 widget 产出」的场景（如一个 Selector 里
/// 的多行）；直接作为 [SettingsSectionCard] 子项的行由分组统一下发行形状。
///
/// 行形状必须在这里逐行下发：外层分组只看到「一个子项」（position=single），
/// 不覆盖的话整组都会按 single 画成四角 16dp，与其它分组的首末 16dp /
/// 内行 4dp 不一致（回归见 settings_choice_row_test）。
class SettingsRows extends StatelessWidget {
  const SettingsRows({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = M3ETheme.of(context).listTheme.cardList.gap;
    // 与 [SettingsSectionCard] 同口径：隐藏的条件行不数进行形状，否则同一
    // 张卡内会出现「上一条可见行内圆角、下一条却按末行画」的错位。
    final visible = [
      for (final child in children)
        child is SettingsReveal ? child.visible : true,
    ];
    final visibleCount = visible.where((show) => show).length;
    var visibleIndex = 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++)
          if (visible[i]) ...[
            if (visibleIndex > 0) SizedBox(height: gap),
            SettingsRowPosition(
              position: calculateCardPosition(visibleIndex++, visibleCount),
              child: children[i],
            ),
          ] else
            children[i],
      ],
    );
  }
}

/// 设置行统一高度（M3E 列表 token）：有副标题取
/// `M3EListItemTheme.twoLineHeight`（72dp）、无取 `minHeight`（56dp）。
///
/// 副标题封顶 2 行（见 [SettingsTileLabel]），行高不再随文案长度在
/// 56–158dp 之间漂移；内容在行内垂直居中（Row 默认 crossAxisAlignment）。
///
/// 这里只管下限：挂了进度条的行（[SettingsInfoTile.progress]）会多一行、
/// 自然超过 token，属预期。
class SettingsRowContent extends StatelessWidget {
  const SettingsRowContent({
    super.key,
    required this.hasSubtitle,
    required this.child,
  });

  final bool hasSubtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final item = M3ETheme.of(context).listTheme.item;
    // 行高 token 含行内边距：这里约束的是内边距之内的内容高度
    // （内容在行内垂直居中，图标 40dp 正好撑满无副标题档）。
    final double token = hasSubtitle ? item.twoLineHeight : item.minHeight;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: token - kSettingsRowPadding.vertical,
      ),
      child: child,
    );
  }
}

/// 设置行公共骨架：图标 + 标题/副标题 + 行尾动作。
///
/// Nav / Switch / Info / Value / ColorValue / Copy 只负责各自的 trailing，
/// 行表面、行高、图标、左右间距与禁用态在这里统一；避免同一页里出现不同
/// 的图标尺寸、行尾间距或禁用透明度。
class SettingsTileRow extends StatelessWidget {
  const SettingsTileRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onPressed,
    this.trailing,
    this.progress,
    this.enabled = true,
    this.isDestructive = false,
    this.subtitleColor,
    this.semanticLabel,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onPressed;
  final Widget? trailing;
  final Widget? progress;
  final bool enabled;
  final bool isDestructive;
  final Color? subtitleColor;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final label =
        semanticLabel ?? (subtitle.isEmpty ? title : '$title, $subtitle');
    return CardListSurface(
      position: SettingsRowPosition.of(context),
      padding: kSettingsRowPadding,
      semanticLabel: label,
      onPressed: enabled ? onPressed : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.45,
        child: SettingsRowContent(
          hasSubtitle: subtitle.isNotEmpty,
          child: Row(
            children: [
              SettingsTileIcon(icon: icon, isDestructive: isDestructive),
              const SizedBox(width: _settingsTileLeadGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SettingsTileLabel(
                      title: title,
                      subtitle: subtitle,
                      isDestructive: isDestructive,
                      subtitleColor: subtitleColor,
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 6),
                      progress!,
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: kSettingsSmallSpacing),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 行首区：图标底 + 标题/副标题（值类型行共用）。
///
/// 内部用 [Expanded] 吃掉剩余宽度把尾部控件推到行尾，因此放在 `Row` 里时
/// 调用方必须再用 `Expanded` 包一层（非 flex 子项拿到的是无界约束）。
///
/// 公开给需要自绘行内容的页面（如音源管理页的状态行）：与内置行共用同一
/// 套图标底 / 排版 / 间距，避免页面各写一份。
class SettingsTileLead extends StatelessWidget {
  const SettingsTileLead({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SettingsTileIcon(icon: icon, isDestructive: false),
        const SizedBox(width: _settingsTileLeadGap),
        Expanded(
          child: SettingsTileLabel(title: title, subtitle: subtitle ?? ''),
        ),
      ],
    );
  }
}

/// 设置行统一图标底：40dp 圆角块（危险操作走 error 容器成对色）。
///
/// [containerColor] / [foregroundColor] 供页面自绘行覆盖成对色（如音源状态行
/// 的成功/错误容器）；缺省走 secondaryContainer 或 errorContainer。
class SettingsTileIcon extends StatelessWidget {
  const SettingsTileIcon({
    super.key,
    required this.icon,
    this.isDestructive = false,
    this.containerColor,
    this.foregroundColor,
  });

  final IconData icon;
  final bool isDestructive;
  final Color? containerColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    // 同目录约定：设置行统一消费 M3ETheme 色板（与 material Theme 的
    // ColorScheme 是两套容器色，混用会出现同屏两种色阶）。
    final scheme = M3ETheme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color:
            containerColor ??
            (isDestructive ? scheme.errorContainer : scheme.secondaryContainer),
        borderRadius: M3EShapes.radiusMedium,
      ),
      child: Icon(
        icon,
        color:
            foregroundColor ??
            (isDestructive
                ? scheme.onErrorContainer
                : scheme.onSecondaryContainer),
      ),
    );
  }
}

/// 条件行展开 / 收起：高度动画（减弱动效时零时长）。
///
/// 用于「开关打开才出现」的从属设置行（自定义色、省流子项、配置表单等）：
/// 直接 `if` 插拔会让卡片高度硬跳一帧，包一层后行出现 / 消失有连续过渡。
/// 隐藏时仍占一个列表槽位（不改变其它行的卡内形状），高度收为 0。
class SettingsReveal extends StatelessWidget {
  const SettingsReveal({super.key, required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: effectDurationOf(context, M3EMotion.short4),
      curve: M3EMotion.emphasizedDecelerate,
      alignment: Alignment.topCenter,
      child: visible ? child : const SizedBox(width: double.infinity),
    );
  }
}

/// 确认弹层里的危险动作按钮：text 形态 + `error` 文字色。
///
/// 破坏性操作（清空统计 / 删除脚本 / 重置绑定 / 清空配置）不放 `filled`
/// 主色：主色是「推荐动作」，这里推荐的是取消。取消用普通 `M3EButton.text`，
/// 危险动作并排在后、视觉上明确是错误色。
Widget settingsDestructiveAction(
  BuildContext context, {
  Key? key,
  required VoidCallback onPressed,
  required String label,
}) {
  final m3e = M3ETheme.of(context);
  return M3EButton.text(
    key: key,
    onPressed: onPressed,
    child: Text(
      label,
      style: m3e.typeScale.labelLarge.copyWith(color: m3e.colorScheme.error),
    ),
  );
}

/// 设置行统一标题/副标题排布（排版走 M3E typeScale，不写死字号字重）。
///
/// 标题 1 行省略 + 副标题 2 行封顶省略：长副标题不再把行撑到 3 行/158dp，
/// 行高由 [SettingsRowContent] 统一（有/无副标题 72/56dp）。
class SettingsTileLabel extends StatelessWidget {
  const SettingsTileLabel({
    super.key,
    required this.title,
    required this.subtitle,
    this.isDestructive = false,
    this.subtitleColor,
  });

  final String title;
  final String subtitle;
  final bool isDestructive;

  /// 副标题颜色覆盖（状态色增强；null = 默认次要文本色）。
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: m3e.typeScale.bodyLarge.copyWith(
            color: isDestructive
                ? m3e.colorScheme.error
                : m3e.colorScheme.onSurface,
          ),
        ),
        if (subtitle.isNotEmpty)
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: m3e.typeScale.bodySmall.copyWith(
              color: subtitleColor ?? m3e.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}
