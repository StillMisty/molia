/// 顶栏窗口按钮（仅 Linux / Windows 桌面构建）：最小化 / 最大化-还原 / 关闭。
///
/// 隐藏原生标题栏后由它承担系统按钮职责；移动骨架与桌面骨架的顶栏共用同一
/// 组件（桌面骨架在 `lib/app/desktop/desktop_shell.dart` 使用），因此独立成
/// 文件而不是留在某一侧壳层里。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/app_localizations.dart';
import '../../services/window/window_chrome.dart';
import '../../widgets/icon_swap.dart';

/// 三键窗口控制组：最小化 / 最大化-还原 / 关闭。
///
/// 图标随 [WindowChrome.maximized] 切换（最大化时显示「还原」）。
///
/// 三键与旁边应用按钮**同规格**（M3E `sm` 档：24 图标 / 40 视觉格 /
/// 48 触控目标），不做桌面风格的紧凑化——顶部一排按钮观感统一优先；
/// 与应用操作之间用一段短竖线分界，右侧贴窗口角，保留「窗口控制」的
/// 识别度。关闭键遵循桌面习惯：hover / 按下时底色转 `errorContainer`、
/// 字形转 `onErrorContainer`（危险色只在这里出现，不影响其它按钮）。
///
/// 字形选型：最小化用 [Icons.remove_rounded]（居中横线）而不是
/// [Icons.minimize_rounded]——后者是 Material 的「下沉横线」设计，
/// 笔画中心比同排的方形 / 叉低 6/24，看上去像没对齐。
class WindowControls extends StatelessWidget {
  const WindowControls({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 与左侧应用操作分界的短竖线（上下各留 10dp，长度约 36dp）。
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: M3EDivider(
            axis: M3EDividerAxis.vertical,
            indent: 10,
            endIndent: 10,
          ),
        ),
        M3EIconButton(
          variant: M3EIconButtonVariant.standard,
          semanticLabel: l10n.windowMinimize,
          icon: const Icon(Icons.remove_rounded),
          onPressed: WindowChrome.minimize,
        ),
        ValueListenableBuilder<bool>(
          valueListenable: WindowChrome.maximized,
          builder: (context, maximized, _) => M3EIconButton(
            variant: M3EIconButtonVariant.standard,
            semanticLabel: maximized ? l10n.windowRestore : l10n.windowMaximize,
            icon: IconSwap<bool>(
              value: maximized,
              builder: (context, maximized) => Icon(
                maximized
                    ? Icons.filter_none_rounded
                    : Icons.crop_square_rounded,
                // 20 而不是 24：Material 的方形/双方形字形更实（16dp 笔画），
                // 与 24 档的叉（12dp）并排时显得重；20 档≈13dp 与叉对齐。
                size: 20,
              ),
            ),
            onPressed: WindowChrome.toggleMaximize,
          ),
        ),
        const WindowCloseButton(),
      ],
    );
  }
}

/// 关闭键：hover / 按下走危险色（桌面习惯：关闭是破坏性操作）。
///
/// 底色用 `M3EIconButtonDecoration.overlayColor` 覆盖 M3E 的中性 state
/// layer，字形色由外层 [MouseRegion] 的 hover 状态给出（decoration 的
/// `foregroundColor` 只在 disabled/selected 上解析，不带 hover）。
class WindowCloseButton extends StatefulWidget {
  const WindowCloseButton({super.key});

  @override
  State<WindowCloseButton> createState() => _WindowCloseButtonState();
}

class _WindowCloseButtonState extends State<WindowCloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scheme = M3ETheme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: M3EIconButton(
        variant: M3EIconButtonVariant.standard,
        semanticLabel: l10n.windowClose,
        decoration: _hovered
            ? M3EIconButtonDecoration(
                overlayColor: WidgetStatePropertyAll<Color?>(
                  scheme.errorContainer,
                ),
              )
            : null,
        icon: Icon(
          Icons.close_rounded,
          color: _hovered ? scheme.onErrorContainer : null,
        ),
        onPressed: WindowChrome.close,
      ),
    );
  }
}
