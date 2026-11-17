/// runApp 的根 widget：Provider 树 + 主题壳 + 首次引导标记。
///
/// 只做挂载，不创建子系统；provider 的构造顺序与依赖顺序在
/// `provider_tree.dart` 内（顺序敏感），这里只把组合根产物传进去。
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../app_shell.dart';
import 'app_dependencies.dart';
import 'provider_tree.dart';

/// 组装 runApp 的根 widget。
///
/// [onboardingCompleted] 在 runApp 前读一次：首帧要么是引导、要么是正常壳层，
/// 不会先闪一下首页（读失败按未完成处理）。
Widget buildRootWidget({
  required AppDependencies dependencies,
  required bool onboardingCompleted,
}) {
  final platform = dependencies.platform;
  final core = dependencies.core;
  final features = dependencies.features;
  final aux = dependencies.aux;

  return MultiProvider(
    providers: buildAppProviders(
      catalog: core.catalog,
      local: core.local,
      library: core.library,
      playback: core.playback,
      scrobble: core.scrobble,
      libraryProvider: core.libraryProvider,
      channelSelection: core.channelSelection,
      searchProvider: core.searchProvider,
      desktop: features.desktop,
      ai: features.ai,
      lyrics: features.lyrics,
      display: features.display,
      sync: aux.sync,
      update: aux.update,
      diagnosticsService: platform.diagnostics.service,
      diagnosticsExporter: aux.diagnosticsExporter,
      notifications: platform.notifications,
    ),
    child: MyThemedApp(
      // 用户交互 → 同步调度器续期活跃窗口（最近交互判定）。
      onUserInteraction: aux.sync.provider.notifyInteraction,
      showOnboarding: !onboardingCompleted,
    ),
  );
}
