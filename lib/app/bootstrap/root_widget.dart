/// runApp 的根 widget：Riverpod 容器 + 主题壳 + 首次引导标记。
///
/// 只做挂载，不创建子系统；启动期实例在 `runtime_wiring.dart` 登记，
/// 这里只把组合根产物传进去。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_shell.dart';
import 'app_dependencies.dart';

/// 组装 runApp 的根 widget。
///
/// [onboardingCompleted] 在 runApp 前读一次：首帧要么是引导、要么是正常壳层，
/// 不会先闪一下首页（读失败按未完成处理）。
Widget buildRootWidget({
  required AppDependencies dependencies,
  required bool onboardingCompleted,
}) {
  final aux = dependencies.aux;

  return UncontrolledProviderScope(
    container: dependencies.container,
    child: MyThemedApp(
      // 用户交互 → 同步调度器续期活跃窗口（最近交互判定）。
      onUserInteraction: aux.sync.provider.notifyInteraction,
      showOnboarding: !onboardingCompleted,
    ),
  );
}
