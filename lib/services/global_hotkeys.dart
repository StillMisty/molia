/// 全局热键注册层（系统级，窗口失焦也生效）。
///
/// 职责边界：本层只做「读设置 → 注册 / 注销系统热键」与失败降级；绑定表
/// （动作 ↔ 组合）在 `shortcut_bindings.dart`，开关与持久化在
/// `ShortcutSettings`，命令语义在 `shortcut_actions.dart`。软件内快捷键是
/// 另一套挂载点（`lib/app/desktop/desktop_shortcuts.dart`，只在窗口聚焦时
/// 生效），两组互不感知。
///
/// 平台面：`nativeapi.ShortcutManager`（macOS Carbon `RegisterEventHotKey`、
/// Windows `RegisterHotKey`、Linux X11 / `org.freedesktop.portal.GlobalShortcuts`
/// 桌面门户；Wayland 的绑定由桌面决定）。注册结果逐条回报，本层把失败
/// 原因记进 [GlobalHotkeys.lastError] 供设置页提示；其余平台整体空操作。
///
/// 为什么不用 hotkey_manager：nativeapi 已经是桌面窗口与托盘的直接依赖，
/// `ShortcutManager` 提供门户的异步注册、取消与注册丢失事件，本层只需要
/// 「命令名 ↔ 回调」的薄映射；hotkey_manager 0.3.0 也基于它，再包一层只会
/// 多一个依赖和一套错误码。注册失败原因由 nativeapi 的 errorMessage 直接
/// 透传。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'global_hotkeys_io.dart';
import 'global_hotkeys_types.dart';
import 'shortcut_actions.dart';
import 'shortcut_bindings.dart';
import 'shortcut_settings.dart';
import 'shortcuts.dart';
import 'window/window_chrome.dart';

export 'global_hotkeys_types.dart';

final _logger = Logger('molia.global_hotkeys');

/// 全局热键设置的最小读取面：本层只消费「开关 + 全局绑定表」，不感知
/// 设置存储；生产实现是 `ShortcutSettings.instance`（薄适配），测试注入
/// 假实现。
abstract interface class GlobalHotkeySettings implements Listenable {
  /// 是否启用全局热键（默认关，避免抢占系统热键）。
  bool get globalEnabled;

  /// 当前全局绑定表（覆盖优先，含未覆盖的默认项）。
  ShortcutBindings get globalBindings;
}

/// [GlobalHotkeySettings] 的生产实现：薄适配 `ShortcutSettings` 单例。
class _ShortcutSettingsView implements GlobalHotkeySettings {
  const _ShortcutSettingsView();

  @override
  bool get globalEnabled => ShortcutSettings.instance.globalEnabled;

  @override
  ShortcutBindings get globalBindings =>
      ShortcutSettings.instance.globalBindings;

  @override
  void addListener(VoidCallback listener) =>
      ShortcutSettings.instance.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      ShortcutSettings.instance.removeListener(listener);
}

/// 全局热键注册层（系统级，窗口失焦也生效）。
class GlobalHotkeys {
  GlobalHotkeys._();

  /// 平台面：三桌面平台有 nativeapi 实现；移动端等无实现的平台空操作
  /// （单条注册失败不在这里判定，见 [lastError]）。
  static bool get isSupported =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// 最近一次注册失败的原因（设置页提示用；本轮全部成功为 null）。
  static String? get lastError => _lastError;
  static String? _lastError;

  /// 测试注入：替换平台注册器（默认 nativeapi 实现）。
  @visibleForTesting
  static GlobalHotkeyRegistrar? registrarOverride;

  /// 测试注入：替换设置源（默认 `ShortcutSettings.instance`）。
  @visibleForTesting
  static GlobalHotkeySettings? settingsOverride;

  static GlobalHotkeySettings? _settings;
  static GlobalHotkeyRegistrar? _registrar;
  static ShortcutActions? _actions;
  static bool _attached = false;

  /// 同步串行链：设置通知可能在上一轮注销 / 注册未完成时到达，直接并发会
  /// 交错平台调用；串成链保证「先注销再注册」的轮次不被穿插。
  static Future<void> _syncChain = Future.value();

  /// 注入命令执行器（组合根在 [attach] 前调用）：全局热键回调不依赖
  /// widget 树，无法像软件内挂载点那样从 context 取 provider。
  static void bindActions(ShortcutActions actions) {
    _actions = actions;
  }

  /// 组合根调用一次：读设置、注册当前绑定，并监听设置变化自动重注册。
  ///
  /// 不抛异常：平台注册失败逐条降级（见 [_sync]），设置服务缺失时整体
  /// 空操作——可选能力不能阻断启动（同 docs/pitfalls.md #31 口径）。
  static Future<void> attach() async {
    if (_attached || !isSupported) return;
    _attached = true;
    final settings = settingsOverride ?? const _ShortcutSettingsView();
    _settings = settings;
    _registrar = registrarOverride ?? NativeGlobalHotkeyRegistrar();
    settings.addListener(_onSettingsChanged);
    _scheduleSync();
    await _syncChain;
  }

  /// 设置变更（开关 / 绑定）：重新走一轮「先注销再注册」。
  static void _onSettingsChanged() => _scheduleSync();

  static void _scheduleSync() {
    _syncChain = _syncChain.then((_) => _sync()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      // _sync 内部逐条兜底；这里只防链断（一次异常不能让后续同步停摆）。
      _logger.severe('全局热键同步异常', error, stackTrace);
    });
  }

  /// 幂等同步：先整体注销，再按当前设置注册（开关关闭时只注销）。
  ///
  /// 先清后建是唯一安全的顺序：同一 accelerator 重复注册在系统层会失败或
  /// 留下陈旧回调（nativeapi 对同一 accelerator 只保留一个注册）；注销失败
  /// 则放弃本轮注册——在未知的残留注册上叠加会得到重复或指向旧动作的按键。
  static Future<void> _sync() async {
    final settings = _settings;
    final registrar = _registrar;
    if (settings == null || registrar == null) return;
    try {
      await registrar.unregisterAll();
    } catch (error) {
      _lastError = '注销失败：$error';
      _logger.warning('注销全局热键失败：$error');
      return;
    }
    if (!settings.globalEnabled) {
      _lastError = null;
      return;
    }
    String? lastFailure;
    var registered = 0;
    for (final entry in settings.globalBindings.effective.entries) {
      final combo = entry.value;
      if (entry.key == ShortcutCommand.showMainWindow && !_supportsShowWindow) {
        continue;
      }
      if (!combo.isValidForScope(ShortcutScope.global)) {
        // 无修饰键的全局热键会抢走普通按键：设置页已校验，这里兜底跳过。
        lastFailure = '${combo.label()}：全局热键必须带修饰键';
        _logger.warning('跳过非法全局热键（${combo.label()}）');
        continue;
      }
      try {
        await registrar.register(
          hotKeySpecFor(entry.key, combo),
          () => _dispatch(entry.key),
        );
        registered++;
      } catch (error) {
        lastFailure = '${combo.label()}：$error';
        _logger.warning('注册全局热键失败（${combo.label()}）：$error');
      }
    }
    _lastError = lastFailure;
    if (_lastError == null && registered > 0) {
      _logger.info('已注册 $registered 条全局热键');
    }
  }

  /// 热键按下 → 执行命令。
  ///
  /// 回调来自平台事件通道（即发即忘，没有 await 点）：执行异常不能变成
  /// 未处理的异步错误，这里统一接住并记日志。
  static void _dispatch(ShortcutCommand command) {
    // 设置页正在录制新按键时跳过：系统级热键由 OS 派发，应用侧无法像软件内
    // 快捷键那样「让位」，只能在回调里主动忽略，否则录制 Ctrl+Alt+Space
    // 会顺带触发一次播放/暂停。
    if (ShortcutSettings.instance.isRecordingCombo) return;
    final actions = _actions;
    if (actions == null) {
      _logger.warning('全局热键触发但命令执行器未注入：${command.name}');
      return;
    }
    unawaited(
      actions.execute(command).catchError((Object error) {
        _logger.warning('全局热键命令执行失败（${command.name}）：$error');
      }),
    );
  }

  /// 没有窗口能力的平台（Android / iOS）上「显示主窗口」这条全局热键没有
  /// 意义，注册前跳过（设置页也按同一判定隐藏该行）。
  static bool get _supportsShowWindow => WindowChrome.isSupported;

  /// 等待在途的设置变更同步完成（测试用：通知回调是同步的，实际同步在
  /// [_syncChain] 异步链上）。
  @visibleForTesting
  static Future<void> flushPendingSync() => _syncChain;

  /// 测试收尾：撤下监听、清空注入与静态状态（不触达平台通道——测试注入的
  /// 是假注册器）。
  @visibleForTesting
  static Future<void> detachForTesting() async {
    _settings?.removeListener(_onSettingsChanged);
    await _syncChain;
    _settings = null;
    _registrar = null;
    _actions = null;
    _attached = false;
    _lastError = null;
    _syncChain = Future.value();
    registrarOverride = null;
    settingsOverride = null;
  }
}
