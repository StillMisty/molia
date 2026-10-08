import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 播放页模式键主体：圆角主色块 + 图标（配合 `_LayeredShell` 错位底片）。
class MyButton extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  final IconData icon;
  final void Function() onPressed;

  const MyButton(
      {super.key,
      required this.width,
      required this.height,
      required this.radius,
      required this.icon,
      required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return M3EButton.text(
      onPressed: onPressed,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Icon(
          icon,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// 小节标题：图标用强调色、文字用正文色（避免整段彩色标题）。
class IconHeader extends StatelessWidget {
  final IconData icon;
  final String text;
  const IconHeader({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: scheme.primary, size: 16),
        const SizedBox(width: 8),
        Flexible(
          // 添加 Flexible 来允许文本在需要时换行或收缩
          child: Text(
            text,
            style: TextStyle(
              color: scheme.onSurface,
              letterSpacing: 2.0,
            ),
          ),
        ),
      ],
    );
  }
}
