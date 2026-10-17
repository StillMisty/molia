/// 全局热键注册层（系统级，窗口失焦也生效）。
///
/// 职责边界：本层只做「读设置 → 注册 / 注销系统热键」与失败降级；绑定表
/// （动作 ↔ 组合）在 `shortcut_bindings.dart`，开关与持久化在
/// `ShortcutSettings`，命令语义在 `shortcut_actions.dart`。软件内快捷键是
/// 另一套挂载点（`lib/app/desktop/desktop_shortcuts.dart`，只在窗口聚焦时
/// 生效），两组互不感知。
///
/// 平台面（`system_hotkeys`）：macOS 走 `RegisterEventHotKey`、Windows 走
/// `RegisterHotKey`、Linux 走 `org.freedesktop.portal.GlobalShortcuts`
/// 桌面门户（**纯 Dart + D-Bus，无原生构建依赖，X11 / Wayland 同样可用**）。
/// 注册结果逐条回报（conflict / unsupported / declined），本层把非成功结果
/// 记进 [GlobalHotkeys.lastError] 供设置页提示；其余平台整体空操作。
///
/// 为什么不用 hotkey_manager：它的 Linux 实现硬链接 keybinder-3.0（构建期
/// 需要 dev 包、运行期需要 .so，缺失直接起不来），且只在 X11 下生效；门户
/// 方案零系统依赖，且在 Wayland 下是唯一正路。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, PhysicalKeyboardKey;
import 'package:system_hotkeys/system_hotkeys.dart';
import 'package:logging/logging.dart';

import 'shortcut_actions.dart';
import 'shortcut_bindings.dart';
import 'shortcut_settings.dart';
import 'shortcuts.dart';

final _logger = Logger('molia.global_hotkeys');

/// 一条系统热键的注册参数（纯数据）：hotkey_manager `HotKey` 的字段映射，
/// 单测只断言它、不触达平台插件。
typedef HotKeySpec = ({
  /// 注册身份（系统侧按它回报按下事件）：用命令名，稳定且可读。
  String id,
  int keyId,
  bool ctrl,
  bool alt,
  bool shift,
  bool meta,
});

/// 组合 → 注册参数（纯映射）。
///
/// `keyId` 是 `LogicalKeyboardKey.keyId`：注册端经
/// `LogicalKeyboardKey.findKeyByKeyId` 还原成键（hotkey_manager 的 `HotKey`
/// 直接接受逻辑键，物理键码由插件内部按平台换算）。
HotKeySpec hotKeySpecFor(ShortcutCommand command, ShortcutCombo combo) => (
      id: command.name,
      keyId: combo.key.keyId,
      ctrl: combo.ctrl,
      alt: combo.alt,
      shift: combo.shift,
      meta: combo.meta,
    );

/// 逻辑键 → 物理键（USB HID usage 口径）：全局热键按**物理位置**注册
/// （布局无关——Dvorak 用户按的仍是同一个键位），`system_hotkeys` 的平台
/// 编码（HID / Windows VK / macOS 虚拟键）也是物理口径。
///
/// 只覆盖可绑定的键集（字母 / 数字 / 方向 / 空格 / 功能键与常见符号）；
/// 映射不到返回 null，注册端据此报错（进 [GlobalHotkeys.lastError]）。
PhysicalKeyboardKey? physicalKeyFor(LogicalKeyboardKey key) {
  final id = key.keyId;
  // 字母：逻辑 id 是 ASCII 小写（0x61..0x7A）→ HID 0x04..0x1D。
  if (id >= 0x61 && id <= 0x7A) {
    return PhysicalKeyboardKey.findKeyByCode(_hidUsage(0x04 + (id - 0x61)));
  }
  // 数字：逻辑 id 是 ASCII（0x30..0x39）→ HID 0x1E..0x27（1 起、0 收尾）。
  if (id >= 0x30 && id <= 0x39) {
    final digit = id - 0x30;
    return PhysicalKeyboardKey.findKeyByCode(
      _hidUsage(digit == 0 ? 0x27 : 0x1E + digit - 1),
    );
  }
  final usage = _physicalUsageByKey[key];
  return usage == null ? null : PhysicalKeyboardKey.findKeyByCode(_hidUsage(usage));
}

/// HID usage → `PhysicalKeyboardKey` 的查找码：Flutter 的
/// `findKeyByCode` 按**完整 id**（USB HID 页前缀 0x0007 + usage）索引，
/// 只传 usage 会查不到（表里的常量都是 `0x0007xxxx`）。
int _hidUsage(int usage) => 0x00070000 | usage;

/// 非字母数字键的 USB HID usage（USB HID Usage Tables §10 Keyboard/Keypad）。
final Map<LogicalKeyboardKey, int> _physicalUsageByKey = {
  LogicalKeyboardKey.space: 0x2C,
  LogicalKeyboardKey.escape: 0x29,
  LogicalKeyboardKey.enter: 0x28,
  LogicalKeyboardKey.arrowRight: 0x4F,
  LogicalKeyboardKey.arrowLeft: 0x50,
  LogicalKeyboardKey.arrowDown: 0x51,
  LogicalKeyboardKey.arrowUp: 0x52,
  LogicalKeyboardKey.f1: 0x3A,
  LogicalKeyboardKey.f2: 0x3B,
  LogicalKeyboardKey.f3: 0x3C,
  LogicalKeyboardKey.f4: 0x3D,
  LogicalKeyboardKey.f5: 0x3E,
  LogicalKeyboardKey.f6: 0x3F,
  LogicalKeyboardKey.f7: 0x40,
  LogicalKeyboardKey.f8: 0x41,
  LogicalKeyboardKey.f9: 0x42,
  LogicalKeyboardKey.f10: 0x43,
  LogicalKeyboardKey.f11: 0x44,
  LogicalKeyboardKey.f12: 0x45,
  LogicalKeyboardKey.minus: 0x2D,
  LogicalKeyboardKey.equal: 0x2E,
  LogicalKeyboardKey.bracketLeft: 0x2F,
  LogicalKeyboardKey.bracketRight: 0x30,
  LogicalKeyboardKey.backslash: 0x31,
  LogicalKeyboardKey.semicolon: 0x33,
  LogicalKeyboardKey.quote: 0x34,
  LogicalKeyboardKey.backquote: 0x35,
  LogicalKeyboardKey.comma: 0x36,
  LogicalKeyboardKey.period: 0x37,
  LogicalKeyboardKey.slash: 0x38,
};

/// 系统热键注册器（seam）：生产实现包 system_hotkeys 的平台调用，
/// 测试注入假实现，避免在单测里触达平台通道。
abstract interface class GlobalHotkeyRegistrar {
  /// 注册一条系统级热键；[onPressed] 在用户按下（不含长按重复）时触发。
  Future<void> register(HotKeySpec spec, VoidCallback onPressed);

  /// 注销本层注册过的全部热键；未注册任何一条时也必须是安全操作。
  Future<void> unregisterAll();
}

/// 全局热键设置的最小读取面：本层只消费「开关 + 全局绑定表」，不感知
/// 设置存储；生产实现是 `ShortcutSettings.instance`（薄适配），测试注入
/// 假实现。
abstract interface class GlobalHotkeySettings implements Listenable {
  /// 是否启用全局热键（默认关，避免抢占系统热键）。
  bool get globalEnabled;

  /// 当前全局绑定表（覆盖优先，含未覆盖的默认项）。
  ShortcutBindings get globalBindings;
}

/// `system_hotkeys` 生产实现：按「命令名 = 注册 id」逐条绑定，按下事件经
/// [SystemHotkeys.events] 流回到本层的回调表（插件不提供逐条回调）。
class _SystemHotkeysRegistrar implements GlobalHotkeyRegistrar {
  _SystemHotkeysRegistrar() {
    _eventSubscription = SystemHotkeys.events.listen((event) {
      _callbacks[event.id]?.call();
    });
  }

  final Map<String, VoidCallback> _callbacks = {};
  StreamSubscription<HotKeyEvent>? _eventSubscription;

  @override
  Future<void> register(HotKeySpec spec, VoidCallback onPressed) async {
    // 全局热键用**物理键**：布局无关（Dvorak 用户按的仍是同一个物理位置），
    // 与 system_hotkeys 的平台编码（USB HID / VK）口径一致。
    final logical = LogicalKeyboardKey.findKeyByKeyId(spec.keyId);
    final physical = logical == null ? null : physicalKeyFor(logical);
    if (physical == null) {
      throw ArgumentError.value(spec.keyId, 'spec.keyId', '未知按键');
    }
    final id = spec.id;
    _callbacks[id] = onPressed;
    final result = await SystemHotkeys.register(
      id,
      HotKey(
        key: physical,
        modifiers: {
          if (spec.ctrl) HotKeyModifier.control,
          if (spec.alt) HotKeyModifier.alt,
          if (spec.shift) HotKeyModifier.shift,
          if (spec.meta) HotKeyModifier.meta,
        },
      ),
      description: id,
    );
    if (result != HotKeyResult.bound) {
      _callbacks.remove(id);
      throw StateError('系统未接受该组合（${result.name}）');
    }
  }

  @override
  Future<void> unregisterAll() async {
    _callbacks.clear();
    await SystemHotkeys.unregisterAll();
  }

  /// 测试收尾 / 进程退出：释放事件订阅（生产只在应用生命周期内存在一次）。
  void dispose() {
    unawaited(_eventSubscription?.cancel());
    _eventSubscription = null;
    _callbacks.clear();
  }
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

  /// 平台面：三桌面平台有 hotkey_manager 实现；移动端等无实现的平台空操作
  /// （Wayland 的失效不在这里判定，见 [lastError]）。
  static bool get isSupported =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// 最近一次注册失败的原因（设置页提示用；本轮全部成功为 null）。
  static String? get lastError => _lastError;
  static String? _lastError;

  /// 测试注入：替换平台注册器（默认 hotkey_manager）。
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
    _registrar = registrarOverride ?? _SystemHotkeysRegistrar();
    settings.addListener(_onSettingsChanged);
    _scheduleSync();
    await _syncChain;
  }

  /// 设置变更（开关 / 绑定）：重新走一轮「先注销再注册」。
  static void _onSettingsChanged() => _scheduleSync();

  static void _scheduleSync() {
    _syncChain = _syncChain.then((_) => _sync()).catchError(
      (Object error, StackTrace stackTrace) {
        // _sync 内部逐条兜底；这里只防链断（一次异常不能让后续同步停摆）。
        _logger.severe('全局热键同步异常', error, stackTrace);
      },
    );
  }

  /// 幂等同步：先整体注销，再按当前设置注册（开关关闭时只注销）。
  ///
  /// 先清后建是唯一安全的顺序：同一组合重复注册在系统层会失败或留下陈旧
  /// 回调（hotkey_manager 的 Dart 侧对同一组合不去重）；注销失败则放弃本轮
  /// 注册——在未知的残留注册上叠加会得到重复或指向旧动作的按键。
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
    _lastError = lastFailure ?? _waylandHint;
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
    unawaited(actions.execute(command).catchError((Object error) {
      _logger.warning('全局热键命令执行失败（${command.name}）：$error');
    }));
  }

  /// 注册结果里的失败提示（Linux 门户不可用时的额外说明）。
  static String? get _waylandHint => null;

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
