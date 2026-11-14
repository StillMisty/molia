/// 托盘休眠门：关闭到托盘后把整棵界面替换成一层主题底色。
///
/// 挂在 `MyThemedApp` 的 MaterialApp 之上：休眠时 MaterialApp / Navigator /
/// 常驻页面整棵卸载（provider、播放与托盘不受影响），恢复时重建——等价一次
/// 「保留播放与托盘的冷启动」；页面滚动位置 / 合集选择等本就有持久化，恢复后
/// 自然回位。
///
/// 单独成组件是为了可测：单测直接挂载本组件翻转存在态，断言子树卸载 / 重建，
/// 不必拉起完整应用壳。
library;

import 'package:flutter/widgets.dart';

import '../services/app_presence.dart';

class TrayDormantGate extends StatelessWidget {
  const TrayDormantGate({
    super.key,
    required this.color,
    required this.childBuilder,
  });

  /// 休眠占位底色：取当前主题 surface——隐藏前还会渲染这一帧，中性色比
  /// 黑 / 白闪一下更不显眼。
  final Color color;

  /// 可见时才构建整棵应用树。
  ///
  /// 不能传 `child`：Widget 实参在调用 build 前就会求值，托盘隐藏期间任何
  /// 上层重建（语言、主题、同步提示）都会把整棵 MaterialApp 配置重新构造
  /// 一遍，即使它不会被挂载。用 builder 后隐藏期间只保留占位。
  final WidgetBuilder childBuilder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppPresenceState>(
      valueListenable: AppPresence.instance,
      builder: (context, presence, _) {
        if (presence == AppPresenceState.trayHidden) {
          return ColoredBox(color: color, child: const SizedBox.expand());
        }
        return childBuilder(context);
      },
    );
  }
}
