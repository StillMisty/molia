import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../../providers/app_providers.dart';
import '../../../services/haptics.dart';
import '../../../services/notification_service.dart';
import '../../../utils/color_hex.dart';
import 'settings_tiles_support.dart';

/// 复制行：图标 + 标题/副标题 + M3E 复制按钮；点行或按钮都复制并轻反馈
/// （SnackBar 文案由调用方给，内容语义各页不同）。
///
/// [trailing] 追加在复制按钮之前的附属动作（如地址行的展开 / 详情入口）。
/// 整行不可点时传 [enabled] = false（只读信息行用 `SettingsInfoTile`）。
class SettingsCopyTile extends ConsumerWidget {
  const SettingsCopyTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.copyText,
    required this.copiedMessage,
    this.trailing,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// 复制到剪贴板的内容。
  final String copyText;

  /// 复制成功后的 SnackBar 文案。
  final String copiedMessage;

  final Widget? trailing;
  final bool enabled;

  void _copy(BuildContext context, WidgetRef ref) {
    HapticsService.lightImpact();
    Clipboard.setData(ClipboardData(text: copyText));
    // 统一走全局提示出口：M3ESnackbar 挂在根 Overlay 上，关闭设置弹层不会
    // 把提示一起带走；观感也与全应用一致（局部 ScaffoldMessenger 会换成
    // 另一套 SnackBar）。
    final NotificationService? notifications = ref.read(
      notificationServiceProvider,
    );
    if (notifications != null) {
      notifications.showSuccessSnackBar(copiedMessage);
      return;
    }
    // 独立挂载（单页预览 / 未注入 provider 的测试）的兜底。
    M3ESnackbar.show(context, message: copiedMessage);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SettingsTileRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      enabled: enabled,
      onPressed: enabled ? () => _copy(context, ref) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (trailing != null) ...[
            trailing!,
            const SizedBox(width: kSettingsSmallSpacing),
          ],
          M3EIconButton(
            icon: const Icon(Icons.content_copy_rounded),
            variant: M3EIconButtonVariant.tonal,
            semanticLabel: copiedMessage,
            onPressed: enabled ? () => _copy(context, ref) : null,
          ),
        ],
      ),
    );
  }
}

/// 值行（可编辑/可选）：图标 + 标题/副标题 + 当前值 + 编辑图标。
///
/// 缓存策略等「点开弹层改一个值」的设置项共用。
class SettingsValueTile extends StatelessWidget {
  const SettingsValueTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;

  /// 当前值展示（行尾，次要文本色）。
  final String value;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 值只是当前值提示（如文件名模板）：给标题保留最低可读宽度，其余宽度
        // 归值；仍放不下就省略，360dp 下长模板不再把行尾挤出卡片。
        final maxValueWidth = math.max(72.0, constraints.maxWidth - 244);
        return SettingsTileRow(
          icon: icon,
          title: title,
          subtitle: subtitle ?? '',
          semanticLabel: '$title, $value',
          onPressed: () {
            HapticsService.lightImpact();
            onTap();
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxValueWidth),
                child: Text(
                  value,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: m3e.typeScale.bodyMedium.copyWith(
                    // 当前值是信息文本，不用强调色。
                    color: m3e.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: kSettingsSmallSpacing),
              Icon(
                Icons.edit_rounded,
                size: kSettingsTileActionSize,
                color: m3e.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 颜色值行：色块 + hex 文本 + 编辑图标（点开取色 / 颜色选择面板）。
///
/// hex 在颜色不透明时显示 `#RRGGBB`，带 alpha 时显示 `#AARRGGBB`。
class SettingsColorValueTile extends StatelessWidget {
  const SettingsColorValueTile({
    super.key,
    required this.icon,
    required this.title,
    required this.colorArgb,
    required this.onTap,
  });

  final IconData icon;
  final String title;

  /// 当前颜色（ARGB int；颜色契约禁止页面写 `Color(0x...)` 字面量）。
  final int colorArgb;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m3e = M3ETheme.of(context);
    final hex = colorHexLabel(
      colorArgb,
      withAlpha: (colorArgb >> 24) & 0xFF != 0xFF,
    );
    return SettingsTileRow(
      icon: icon,
      title: title,
      subtitle: '',
      semanticLabel: '$title, $hex',
      onPressed: () {
        HapticsService.lightImpact();
        onTap();
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsColorSwatch(color: Color(colorArgb)),
          const SizedBox(width: kSettingsSmallSpacing),
          Text(
            hex,
            style: m3e.typeScale.bodyMedium.copyWith(
              color: m3e.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: kSettingsSmallSpacing),
          Icon(
            Icons.edit_rounded,
            size: kSettingsTileActionSize,
            color: m3e.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

/// 颜色色块：圆角方块 + 描边（任意颜色都能看清边界，深色主题下尤其重要）。
class SettingsColorSwatch extends StatelessWidget {
  const SettingsColorSwatch({super.key, required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: M3EShapes.radiusSmall,
        border: Border.all(
          color: M3ETheme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }
}
