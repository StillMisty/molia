import 'package:material_ui/material_ui.dart';

import 'settings_tiles_support.dart';

/// 只读信息行（无点击、无 chevron）：如「当前播放音质」。
class SettingsInfoTile extends StatelessWidget {
  const SettingsInfoTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.progress,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  /// 只读行尾的附加动作（如下载任务的取消 / 重试按钮）；整行仍不可点。
  final Widget? trailing;

  /// 标题/副标题下方的进度条：只给「正在进行的任务」行用。
  ///
  /// 进度条是第三行，会把行撑高（行高只设下限，见 [SettingsRowContent]）；
  /// 普通信息行不要传，保持 56/72dp 的标准行高。
  final Widget? progress;

  @override
  Widget build(BuildContext context) {
    return SettingsTileRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      progress: progress,
      onPressed: null,
    );
  }
}
