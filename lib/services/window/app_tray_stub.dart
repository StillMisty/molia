import 'tray_menu_labels.dart';

/// Web / 移动端 / macOS：无托盘。
///
/// 除 [isSupported] 恒为 false 外全部是空操作：UI 可无条件调用
/// （设置页据此隐藏入口），不会触碰任何原生符号（`dart:ffi` 在 Web 上不存在）。
class AppTray {
  AppTray._();

  static bool get isSupported => false;

  /// 本平台不存在「托盘依赖桌面面板」的问题（仅 Linux 桌面需要提示）。
  static bool get isLinuxDesktop => false;

  static void init({
    required TrayMenuLabels labels,
    required void Function() onShowWindow,
    required void Function() onTogglePlay,
    required void Function() onPrevious,
    required void Function() onNext,
    required void Function() onToggleFavorite,
    required void Function() onQuit,
  }) {}

  static void setLabels(TrayMenuLabels labels) {}

  static void setPlaybackState({
    required bool hasTrack,
    required bool isPlaying,
  }) {}

  static void setFavorite(bool isFavorite) {}

  static void setTooltip(String tooltip) {}

  static void dispose() {}

  static bool get debugIsActive => false;

  /// 本平台没有托盘，也就没有宿主（关闭策略在 stub 平台不生效）。
  static Future<bool> detectHost() async => false;
}
