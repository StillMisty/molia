/// 首次引导完成标记：**设备本地**，不登记进设置注册表。
///
/// 同步 / 完整备份按登记表收集键，因此这个标记不会被另一台设备改写：
/// 远端既不能重新触发引导，也不能替用户跳过。
library;

import 'package:shared_preferences/shared_preferences.dart';

/// 键名常量（架构测试核对它不在 `kAllSettingsKeys` 里）。
const String kOnboardingCompletedV1 = 'onboarding_completed_v1';

class OnboardingStore {
  OnboardingStore({SharedPreferences? prefs}) : _prefsOverride = prefs;

  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;

  Future<SharedPreferences> _prefsStore() async =>
      _prefs ??= _prefsOverride ?? await SharedPreferences.getInstance();

  /// 读取完成标记；读不到 / 存储不可用 = 未完成。
  Future<bool> isCompleted() async {
    try {
      final prefs = await _prefsStore();
      return prefs.getBool(kOnboardingCompletedV1) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 写入完成标记（完成或跳过都算）；失败时下次启动会再次出现。
  Future<void> markCompleted() async {
    try {
      final prefs = await _prefsStore();
      await prefs.setBool(kOnboardingCompletedV1, true);
    } catch (_) {
      // 设备本地标记写不进去不阻断进入应用。
    }
  }
}
