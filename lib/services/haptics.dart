/// 触感反馈的唯一入口（全应用「震动反馈」开关的判定处）。
///
/// **为什么单收一层**：设置页要能一键关掉全应用触感（默认开启），而全仓有
/// 六十多处直接调 `HapticFeedback.*`。把「是否开启」的判定收在这里，调用点
/// 只表达「这次交互该有轻触感」，不再各自读设置；关掉后所有入口一起静音。
///
/// **为什么是设备本地键**：振感是设备能力（手机有、桌面本就没有），跟着账号
/// 同步只会在不支持的一端产生「开关开着却不振」的歧义——与省流模式 /
/// 托盘行为同一取舍，因此**不登记** `SettingsRegistry`（不同步、不进备份），
/// 键名只出现在本文件（`test/architecture/settings_keys_test` 只约束登记键）。
///
/// 开关状态是同步判定（点击回调里立即要答案），所以持久化值在启动时读进
/// [enabledNotifier] 常驻内存；读取失败保持默认开启，不阻塞启动。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 震动反馈服务：开关读取 / 持久化与三档触感的统一出口。
class HapticsService {
  HapticsService._();

  /// 持久化键名（设备本地键，不登记同步注册表）。
  static const String keyEnabled = 'haptics_enabled';

  /// 默认开启：关闭是用户的显式选择。
  static const bool defaultEnabled = true;

  /// 当前开关（设置页订阅；写入后立即生效，无需重启）。
  static final ValueNotifier<bool> enabledNotifier =
      ValueNotifier<bool>(defaultEnabled);

  /// 触感是否开启（高频读取，直接走内存值）。
  static bool get enabled => enabledNotifier.value;

  /// 启动时载入已保存开关（应用壳 initState 调用一次）。
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabledNotifier.value = prefs.getBool(keyEnabled) ?? defaultEnabled;
    } catch (_) {
      // 存储不可用（测试 / 平台异常）：保持默认开启，触感照常。
    }
  }

  /// 设置页开关：立即生效并尽力持久化（写入失败只影响下次启动）。
  static Future<void> setEnabled(bool value) async {
    if (enabledNotifier.value == value) return;
    enabledNotifier.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(keyEnabled, value);
    } catch (_) {
      // 同上：本次会话已生效，不打断设置页交互。
    }
  }

  /// 轻触感：点按 / 切换的统一口径（全仓默认档）。
  static void lightImpact() => _fire(HapticFeedback.lightImpact);

  /// 中触感：拖拽提交 / 破坏性操作确认等需要更明确反馈的动作。
  static void mediumImpact() => _fire(HapticFeedback.mediumImpact);

  /// 选择触感：滑过选项 / 步进选择。
  static void selectionClick() => _fire(HapticFeedback.selectionClick);

  /// 三档触感共用同一道闸：关掉开关后不再触碰平台通道。
  static void _fire(VoidCallback haptic) {
    if (!enabledNotifier.value) return;
    haptic();
  }
}
