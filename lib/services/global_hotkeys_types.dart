/// 全局热键的平台无关类型与映射。
///
/// 这里只放纯数据 / 纯映射：注册参数、逻辑键 → 物理键、物理键 →
/// nativeapi accelerator。真正的平台调用在 `global_hotkeys_io.dart`
/// （nativeapi 的 `ShortcutManager`），这样单测不需要加载原生库。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, PhysicalKeyboardKey, kMacOsToPhysicalKey;

import 'shortcut_bindings.dart';
import 'shortcuts.dart';

/// 一条系统热键的注册参数（纯数据）。
typedef HotKeySpec = ({
  /// 注册身份（系统侧按它回报按下事件）：用命令名，稳定且可读。
  String id,
  int keyId,
  bool ctrl,
  bool alt,
  bool shift,
  bool meta,
});

/// 系统热键注册器（seam）：生产实现是 `global_hotkeys_io.dart` 的 nativeapi
/// 封装，测试注入假实现，避免在单测里触达平台通道。
abstract interface class GlobalHotkeyRegistrar {
  /// 注册一条系统级热键；[onPressed] 在用户按下（不含长按重复）时触发。
  Future<void> register(HotKeySpec spec, VoidCallback onPressed);

  /// 注销本层注册过的全部热键；未注册任何一条时也必须是安全操作。
  Future<void> unregisterAll();
}

/// 组合 → 注册参数（纯映射）。
///
/// `keyId` 是 `LogicalKeyboardKey.keyId`：注册端经
/// `LogicalKeyboardKey.findKeyByKeyId` 还原成逻辑键，再按
/// [physicalKeyFor] 换算成物理键。
HotKeySpec hotKeySpecFor(ShortcutCommand command, ShortcutCombo combo) => (
  id: command.name,
  keyId: combo.key.keyId,
  ctrl: combo.ctrl,
  alt: combo.alt,
  shift: combo.shift,
  meta: combo.meta,
);

/// 逻辑键 → 物理键（USB HID usage 口径）：全局热键按物理位置注册
/// （布局无关——Dvorak 用户按的仍是同一个键位）。
///
/// 只覆盖可绑定的键集（字母 / 数字 / 方向 / 空格 / 功能键与常见符号）；
/// 映射不到返回 null，注册端据此报错（进 `GlobalHotkeys.lastError`）。
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
  return usage == null
      ? null
      : PhysicalKeyboardKey.findKeyByCode(_hidUsage(usage));
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

/// 全局热键可注册的键：字母 / 数字 / F1–F12 / 空格。
///
/// 这是 macOS RegisterEventHotKey、Windows RegisterHotKey 与 Linux
/// GlobalShortcuts 三套系统 API 的安全交集；其余键在写入设置前拦掉，
/// 避免用户存下一个永远不会生效的绑定。
bool isSupportedGlobalKey(PhysicalKeyboardKey key) =>
    _supportedUsages.contains(key.usbHidUsage);

/// [isSupportedGlobalKey] 的 USB HID usages（keyboard page 0x07）。
final Set<int> _supportedUsages = {
  for (var usage = 0x00070004; usage <= 0x0007001D; usage++) usage, // A–Z
  for (var usage = 0x0007001E; usage <= 0x00070027; usage++) usage, // 1–9、0
  for (var usage = 0x0007003A; usage <= 0x00070045; usage++) usage, // F1–F12
  0x0007002C, // 空格
};

/// 物理键 → 平台键码（nativeapi 的 `NativeKey<N>`）。
///
/// 用平台键码而不是可读字符，是为了保留**物理位置**语义：Dvorak 用户按
/// 同一个物理键时，系统注册的仍是同一个键。macOS 的 Carbon 虚拟键码表来自
/// Flutter 自带的 `keyboard_maps.g.dart`；Windows VK 与 Linux X11 KeySym
/// 的可注册键都是连续段（字母 / 数字 / F1–F12 / 空格），直接算。
///
/// [operatingSystem] 只给测试用；生产省略，取 [Platform.operatingSystem]。
int? platformKeyCode(PhysicalKeyboardKey key, {String? operatingSystem}) {
  return switch (operatingSystem ?? Platform.operatingSystem) {
    'macos' => _reversePhysical(kMacOsToPhysicalKey, key),
    'windows' => _windowsVirtualKey(key),
    'linux' => _linuxKeySym(key),
    _ => null,
  };
}

int? _windowsVirtualKey(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >= 0x00070004 && usage <= 0x0007001D) {
    return 0x41 + usage - 0x00070004; // VK_A..VK_Z
  }
  if (usage >= 0x0007001E && usage <= 0x00070027) {
    return 0x30 + (usage - 0x0007001E + 1) % 10; // VK_0..VK_9
  }
  if (usage >= 0x0007003A && usage <= 0x00070045) {
    return 0x70 + usage - 0x0007003A; // VK_F1..VK_F12
  }
  if (usage == 0x0007002C) return 0x20; // VK_SPACE
  return null;
}

int? _linuxKeySym(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >= 0x00070004 && usage <= 0x0007001D) {
    return 0x61 + usage - 0x00070004; // XK_a..XK_z
  }
  if (usage >= 0x0007001E && usage <= 0x00070026) {
    return 0x31 + usage - 0x0007001E; // '1'..'9'
  }
  if (usage == 0x00070027) return 0x30; // '0'
  if (usage >= 0x0007003A && usage <= 0x00070045) {
    return 0xFFBE + usage - 0x0007003A; // XK_F1..XK_F12
  }
  if (usage == 0x0007002C) return 0x20; // XK_space
  return null;
}

int? _reversePhysical(
  Map<int, PhysicalKeyboardKey> table,
  PhysicalKeyboardKey key,
) {
  for (final entry in table.entries) {
    if (entry.value == key) return entry.key;
  }
  return null;
}

/// 物理键 → nativeapi accelerator 的按键段（`NativeKey<平台键码>`）。
String? _acceleratorKeyName(PhysicalKeyboardKey key) {
  final code = platformKeyCode(key);
  return code == null ? null : 'NativeKey$code';
}

/// 注册参数 → nativeapi accelerator（例如 `Ctrl+Alt+NativeKey112`）。
///
/// 只接受 [isSupportedGlobalKey] 认可的键；其余键抛出 [ArgumentError]，
/// 由调用方决定是跳过还是提示。
String acceleratorForHotKeySpec(HotKeySpec spec) {
  final logical = LogicalKeyboardKey.findKeyByKeyId(spec.keyId);
  final physical = logical == null ? null : physicalKeyFor(logical);
  final key = physical != null && isSupportedGlobalKey(physical)
      ? _acceleratorKeyName(physical)
      : null;
  if (key == null) {
    throw ArgumentError.value(spec.keyId, 'spec.keyId', '未知按键');
  }
  return [
    if (spec.ctrl) 'Ctrl',
    if (spec.alt) 'Alt',
    if (spec.shift) 'Shift',
    if (spec.meta) 'Meta',
    key,
  ].join('+');
}
