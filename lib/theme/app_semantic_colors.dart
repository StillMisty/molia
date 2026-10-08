import 'package:material_ui/material_ui.dart';

/// 状态语义色扩展：ColorScheme 只定义 primary/secondary/tertiary/error
/// 四族，成功/警告等状态此前散落为硬编码颜色（`Colors.green`、
/// 随意的 `tertiaryContainer`），既不随亮度适配也无法统一。
///
/// 这里用 M3 的方式从固定种子派生 success/warning 的前景 + 容器四件套，
/// 注册到全局 ThemeData.extensions（见 `app_theme.dart`）；只继承当前
/// ColorScheme 的亮度，**不受封面取色/莫奈影响**——状态语义必须稳定。
///
/// 用法：`AppSemanticColors.of(context).success`（宿主未注册扩展时回退
/// 即时派生，保证局部 Theme/测试可用）。
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
  });

  /// 按当前方案亮度派生（色调固定）：容器/前景成对生成，对比度有保证。
  factory AppSemanticColors.fromScheme(ColorScheme scheme) {
    final success = ColorScheme.fromSeed(
      seedColor: _successSeed,
      brightness: scheme.brightness,
    );
    final warning = ColorScheme.fromSeed(
      seedColor: _warningSeed,
      brightness: scheme.brightness,
    );
    return AppSemanticColors(
      success: success.primary,
      onSuccess: success.onPrimary,
      successContainer: success.primaryContainer,
      onSuccessContainer: success.onPrimaryContainer,
      warning: warning.primary,
      onWarning: warning.onPrimary,
      warningContainer: warning.primaryContainer,
      onWarningContainer: warning.onPrimaryContainer,
    );
  }

  /// 读取全局语义色；未注册扩展时（局部 Theme/测试）即时派生。
  static AppSemanticColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppSemanticColors>() ??
        AppSemanticColors.fromScheme(theme.colorScheme);
  }

  static const Color _successSeed = Color(0xFF2E7D32); // green 800
  static const Color _warningSeed = Color(0xFFB26A00); // amber 850

  /// 成功态前景（图标/文字）。
  final Color success;

  /// 成功态前景的配对色（实心背景上使用）。
  final Color onSuccess;

  /// 成功态容器背景（提示条/状态块）。
  final Color successContainer;

  /// 成功态容器上的前景。
  final Color onSuccessContainer;

  /// 警告态前景（图标/文字）。
  final Color warning;

  /// 警告态前景的配对色。
  final Color onWarning;

  /// 警告态容器背景（提醒条/数量超限徽标）。
  final Color warningContainer;

  /// 警告态容器上的前景。
  final Color onWarningContainer;

  @override
  AppSemanticColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
  }) {
    return AppSemanticColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
    );
  }

  @override
  AppSemanticColors lerp(AppSemanticColors? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer: Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer:
          Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer: Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer:
          Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
    );
  }
}
