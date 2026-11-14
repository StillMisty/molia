/// 首次引导完成标记：**设备本地**，不登记进设置注册表。
///
/// 同步 / 完整备份按登记表收集键，因此这个标记不会被另一台设备改写：
/// 远端既不能重新触发引导，也不能替用户跳过。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// 键名常量（架构测试核对它不在 `kAllSettingsKeys` 里）。
const String kOnboardingCompletedV1 = 'onboarding_completed_v1';

class OnboardingStore {
  OnboardingStore({SharedPreferences? prefs}) : _prefsOverride = prefs;

  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;

  /// 本次进程已知的完成态（启动读到 true 或用户完成 / 跳过）。
  ///
  /// 不能只用壳层 State 记这件事：托盘休眠会卸载并重建整棵界面
  /// （`TrayDormantGate`），重建时拿到的是启动时读到的 `showOnboarding`，
  /// 引导会每次恢复窗口都重新出现一遍。完成是不可逆的一次性事实，
  /// 提到进程级后，任何壳层重建都按同一份结论判定。
  static bool _completedInSession = false;

  /// 本次进程是否已完成 / 跳过引导（壳层重建时用它兜底）。
  static bool get completedInSession => _completedInSession;

  /// 清掉进程内标记：测试隔离用，生产不要调用。
  @visibleForTesting
  static void resetSessionForTest() => _completedInSession = false;

  Future<SharedPreferences> _prefsStore() async =>
      _prefs ??= _prefsOverride ?? await SharedPreferences.getInstance();

  /// 读取完成标记；读不到 / 存储不可用 = 未完成。
  Future<bool> isCompleted() async {
    try {
      final prefs = await _prefsStore();
      final completed = prefs.getBool(kOnboardingCompletedV1) ?? false;
      if (completed) _completedInSession = true;
      return completed;
    } catch (_) {
      return false;
    }
  }

  /// 写入完成标记（完成或跳过都算）；写盘失败时下次启动会再次出现。
  Future<void> markCompleted() async {
    // 先置位：写盘失败也不在本次进程里重复出现（下次启动才重试）。
    _completedInSession = true;
    try {
      final prefs = await _prefsStore();
      await prefs.setBool(kOnboardingCompletedV1, true);
    } catch (_) {
      // 设备本地标记写不进去不阻断进入应用。
    }
  }
}
