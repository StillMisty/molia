/// 窗口存在态 → TickerMode 门：最小化 / 托盘隐藏时静音整棵界面的 ticker。
///
/// 为什么单独成组件：壳层在 `TrayDormantGate` 内挂一层即可，测试也能直接
/// 翻转 `AppPresence` 验证「最小化不跑装饰动画」。只静音 ticker，不清缓存、
/// 不卸载树，也不改变播放语义（最小化仍保留页面状态与内存）。
library;

import 'package:flutter/widgets.dart';

import '../services/app_presence.dart';

class AppPresenceTickerMode extends StatelessWidget {
  const AppPresenceTickerMode({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppPresenceState>(
      valueListenable: AppPresence.instance,
      builder: (context, presence, child) => TickerMode(
        enabled: presence == AppPresenceState.visible,
        child: child!,
      ),
      child: child,
    );
  }
}
