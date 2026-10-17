/// 快捷键设置：软件内 / 全局两组的开关与绑定覆盖（跟人走，经设置注册表读写）。
///
/// 绑定模型（动作 ↔ 组合、默认表、序列化 / 校验）在 `shortcut_bindings.dart`；
/// 本服务把模型接到设置存储上，并作为运行时唯一状态源：
/// - 软件内快捷键处理器（`lib/app/desktop/desktop_shortcuts.dart`）按
///   [inAppBindings] 查表执行；
/// - 系统级全局热键（`lib/services/global_hotkeys.dart`）订阅 [globalEnabled] /
///   [globalBindings] 完成注册与注销；
/// - 设置页（`lib/pages/shortcut_settings_page.dart`）读写并订阅变更。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:system_hotkeys/system_hotkeys.dart' show HotKey;

import '../data/settings/settings_key.dart';
import '../data/settings/settings_keys.dart';
import '../data/settings/settings_registry.dart';
import 'global_hotkeys.dart';
import 'shortcut_bindings.dart';
import 'shortcuts.dart';

/// 两组快捷键的开关与绑定覆盖；单例，变更通知驱动 UI 与监听方。
class ShortcutSettings extends ChangeNotifier {
  ShortcutSettings._();

  /// 全局单例：UI、软件内处理器与系统级热键注册共享同一状态源。
  static final ShortcutSettings instance = ShortcutSettings._();

  /// 设置注册表（组合根启动时注入；reload 由组合根代绑，同语言 / 品牌名）。
  ///
  /// 可为 null（测试 / 独立挂载）：此时状态只留在内存，不落盘。
  static SettingsRegistry? _settings;

  /// 注入注册表并触发一次异步载入（组合根不必 await：读取完成后
  /// [notifyListeners] 驱动 UI 与监听方）。
  static void attachSettings(SettingsRegistry settings) {
    _settings = settings;
    unawaited(load());
  }

  // 默认值与登记键默认值一致（见 settings_keys.dart）：软件内开、全局关。
  bool _inAppEnabled = true;
  bool _globalEnabled = false;
  ShortcutBindings _inAppBindings =
      ShortcutBindings(ShortcutScope.inApp, const {});
  ShortcutBindings _globalBindings =
      ShortcutBindings(ShortcutScope.global, const {});

  /// 组合键录制态的持有者（设置页录制行）；null = 未在录制。
  Object? _recordingOwner;

  bool get inAppEnabled => _inAppEnabled;
  bool get globalEnabled => _globalEnabled;
  ShortcutBindings get inAppBindings => _inAppBindings;
  ShortcutBindings get globalBindings => _globalBindings;

  /// 是否正在录制组合键：软件内快捷键处理器据此整体让位——处理器在焦点分发
  /// 之前收到按键，不让位的话录制 Space / ←→ 会先触发播放命令。
  ///
  /// 系统级全局热键的回调（`lib/services/global_hotkeys.dart`）同样应跳过
  /// 执行：热键由系统派发，处理器让位管不到它。
  ///
  /// 不 notifyListeners：处理器每次按键直接读实时值，没有 UI 依赖它重建。
  bool get isRecordingCombo => _recordingOwner != null;

  /// 进入录制态；[owner] 是录制行自身，用于多行互斥。
  void beginRecordingCombo(Object owner) => _recordingOwner = owner;

  /// 退出录制态；只有持有者能清——焦点转移时旧录制行晚于新录制行收到回调，
  /// 不加持有者校验会把新录制行的标志误清掉。
  void endRecordingCombo(Object owner) {
    if (identical(_recordingOwner, owner)) _recordingOwner = null;
  }

  /// 读四个登记键；读取失败 / 未接线保持当前值。
  static Future<void> load() async {
    final settings = _settings;
    if (settings == null) return;
    final self = instance;
    try {
      final inAppEnabled = await settings.read(kShortcutsEnabled);
      final globalEnabled = await settings.read(kGlobalShortcutsEnabled);
      final inAppRaw = await settings.read(kShortcutBindings);
      final globalRaw = await settings.read(kGlobalShortcutBindings);
      self._inAppEnabled = inAppEnabled;
      self._globalEnabled = globalEnabled;
      self._inAppBindings =
          ShortcutBindings.decode(ShortcutScope.inApp, inAppRaw);
      self._globalBindings =
          ShortcutBindings.decode(ShortcutScope.global, globalRaw);
      self.notifyListeners();
    } catch (_) {
      // 存储不可用时按默认跑（读取本身已兜底，这里只防意外）。
    }
  }

  /// 同步应用远端设置后的重载（组合根 `bindReload` 的钩子）。
  static Future<void> reload() => load();

  /// 软件内快捷键总开关（默认开）。
  Future<void> setInAppEnabled(bool value) async {
    if (_inAppEnabled == value) return;
    _inAppEnabled = value;
    notifyListeners();
    await _write(kShortcutsEnabled, value);
  }

  /// 全局快捷键总开关（默认关）；系统级注册由全局热键服务订阅本变更完成。
  Future<void> setGlobalEnabled(bool value) async {
    if (_globalEnabled == value) return;
    _globalEnabled = value;
    notifyListeners();
    await _write(kGlobalShortcutsEnabled, value);
  }

  /// 覆盖某动作的绑定（[combo] 为 null = 回默认）。
  ///
  /// 校验：动作必须属于该分组；全局组合必须带修饰键（系统级注册要求）；
  /// 同组内不得与其它动作重复（含未覆盖的默认项）。校验失败返回 false
  /// 且不写入。
  Future<bool> setBinding(
    ShortcutScope scope,
    ShortcutCommand command,
    ShortcutCombo? combo,
  ) async {
    final defaults = ShortcutBindings.defaultsOf(scope);
    if (!defaults.containsKey(command)) return false;
    final bindings = _bindingsOf(scope);
    if (combo != null) {
      if (!combo.isValidForScope(scope)) return false;
      if (!isComboSupported(scope, combo)) return false;
      if (bindings.conflictWith(combo, exclude: command) != null) return false;
    }
    // 录到与默认相同的组合等于没有自定义：清掉覆盖，避免「回默认」按钮
    // 在值等于默认时仍然亮着。
    final override = combo == defaults[command] ? null : combo;
    _setBindings(scope, bindings.withOverride(command, override));
    notifyListeners();
    await _persist(scope);
    return true;
  }

  /// 该组合在系统级是否可注册（仅全局分组有意义）。
  ///
  /// `system_hotkeys` 只接受字母 / 数字 / F1–F12 / 空格（macOS 与 Windows 的
  /// 系统 API 限制）；其余键（方向键、标点）注册必返回 `unsupported`，
  /// 在写入前拦掉，避免用户存下一个永远不会生效的绑定。
  static bool isComboSupported(ShortcutScope scope, ShortcutCombo combo) {
    if (scope != ShortcutScope.global) return true;
    final physical = physicalKeyFor(combo.key);
    return physical != null && HotKey.isSupportedKey(physical);
  }

  /// 整组恢复默认（清空全部覆盖）。
  Future<void> resetScope(ShortcutScope scope) async {
    final bindings = _bindingsOf(scope);
    // 全默认：无改动可做，也不写空串（不制造无意义的存储写入）。
    if (!ShortcutBindings.commandsOf(scope).any(bindings.isOverridden)) return;
    _setBindings(scope, bindings.cleared());
    notifyListeners();
    await _persist(scope);
  }

  ShortcutBindings _bindingsOf(ShortcutScope scope) =>
      scope == ShortcutScope.inApp ? _inAppBindings : _globalBindings;

  void _setBindings(ShortcutScope scope, ShortcutBindings bindings) {
    if (scope == ShortcutScope.inApp) {
      _inAppBindings = bindings;
    } else {
      _globalBindings = bindings;
    }
  }

  /// 覆盖表落盘（空覆盖编码为空串，读回即「全默认」）。
  Future<void> _persist(ShortcutScope scope) => scope == ShortcutScope.inApp
      ? _write(kShortcutBindings, _inAppBindings.encode())
      : _write(kGlobalShortcutBindings, _globalBindings.encode());

  /// 写登记键；失败只影响下次启动的持久化，本次会话已生效（与品牌名同口径）。
  Future<void> _write<T extends Object?>(SettingsKey<T> key, T value) async {
    final settings = _settings;
    if (settings == null) return;
    try {
      await settings.write(key, value);
    } catch (_) {}
  }
}
