import 'package:material_ui/material_ui.dart';

import '../providers/nav_provider.dart';

/// 壳层导航目的地图标：底栏 / 侧栏 / 设置页预览共用的唯一映射源。
///
/// 按 M3 惯例成对使用「未选中空心、选中实心」：
/// - 空心优先取圆角字形（如 `favorite_border_rounded`）；
/// - 音符 / 资料库没有圆角空心字形，退用 `_outlined` 变体与实心成对；
/// - 空心的 `_outlined` 只应出现在本文件的未选中半对中（架构测试兜底）。
extension ShellDestinationIcons on ShellDestination {
  /// 未选中（inactive）态图标。
  IconData get outlinedIcon => switch (this) {
        ShellDestination.nowPlaying => Icons.music_note_outlined,
        ShellDestination.favorites => Icons.favorite_border_rounded,
        ShellDestination.library => Icons.library_music_outlined,
      };

  /// 选中（active）态图标。
  IconData get filledIcon => switch (this) {
        ShellDestination.nowPlaying => Icons.music_note_rounded,
        ShellDestination.favorites => Icons.favorite_rounded,
        ShellDestination.library => Icons.library_music_rounded,
      };
}
