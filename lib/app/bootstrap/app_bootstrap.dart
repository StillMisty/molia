/// 组合根入口：只按顺序调用各阶段，不在本文件持有子系统细节。
///
/// 阶段顺序即启动顺序（见 docs/architecture.md §1）：
/// 平台装配 → 核心栈 → 功能栈 → 尾部栈（含观察者 / 同步 / 更新 / 生命周期）
/// → 读引导标记 → runApp → 首帧回调。所有 `molia.startup` 阶段名保持不变，
/// 便于启动回归对比。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/onboarding_store.dart';
import '../../services/window/window_chrome.dart';
import '../perf/data_path_scenario.dart';
import '../perf/frame_stats.dart';
import 'app_dependencies.dart';
import 'build_aux_stacks.dart';
import 'build_core_stacks.dart';
import 'build_feature_stacks.dart';
import 'platform_bootstrap.dart';
import 'post_frame_init.dart';
import 'root_widget.dart';
import 'runtime_providers.dart';
import 'startup_trace.dart';

/// 启动 Molia：平台装配 → 各栈按序构建 → runApp → 首帧收尾。
Future<void> runMoliaApp() async {
  final platform = await bootstrapPlatform();
  final core = await buildCoreStacks(platform: platform);
  // Riverpod 容器在功能栈之前创建：主题 / 导航等状态 provider 由容器持有，
  // 组合根只注入启动阶段产出的基础依赖；功能栈通过容器读取同一实例。
  final container = ProviderContainer(
    overrides: [
      settingsRegistryProvider.overrideWithValue(core.catalog.settings),
    ],
  );
  final features = await buildFeatureStacks(
    platform: platform,
    core: core,
    container: container,
  );
  final aux = await buildAuxStacks(
    platform: platform,
    core: core,
    features: features,
  );
  final dependencies = AppDependencies(
    platform: platform,
    core: core,
    features: features,
    aux: aux,
    container: container,
  );

  // 首次引导标记：在 runApp 前读一次，首帧要么是引导、要么是正常壳层，
  // 不会先闪一下首页。读失败按「未完成」处理。
  final onboardingCompleted = await OnboardingStore().isCompleted();
  runApp(
    buildRootWidget(
      dependencies: dependencies,
      onboardingCompleted: onboardingCompleted,
    ),
  );

  // 首帧：先亮窗口（内容已画好，用户不再盯空白窗），再做启动尾巴
  // （托盘落地 + 更新准备/自动检查 + 同步启动 + 音源初始化）。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    platform.revealFallback.cancel();
    markStartupStep('首帧', platform.startup);
    FrameStats.instance.reportNow('first-frame');
    unawaited(WindowChrome.show());
    initAfterFirstFrame(
      catalog: core.catalog,
      local: core.local,
      library: core.library,
      scrobble: core.scrobble,
      desktop: features.desktop,
      ai: features.ai,
      update: aux.update,
      sync: aux.sync,
    );
    // 数据链路体检（仅 MOLIA_PERF_SCENARIO_DATA=true 的专用构建；正常包
    // 在编译期折叠为一次 return）。
    unawaited(
      runDataPathScenario(
        catalog: core.catalog,
        playback: core.playback,
        lyrics: features.lyrics,
      ),
    );
  });
}
