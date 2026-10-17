/// 快捷键的绑定模型：按键组合的序列化 / 解析 / 展示，以及两组默认绑定表。
///
/// **为什么单独一层**：快捷键分两组语义——**软件内**（`ShortcutScope.inApp`，
/// 只在窗口聚焦时生效，见 `lib/app/desktop/desktop_shortcuts.dart`）与**全局**
/// （`ShortcutScope.global`，系统级热键，窗口失焦也生效，见
/// `lib/services/global_hotkeys.dart`）。两组都要「可开关 + 可自定义」，
/// 于是绑定表必须可序列化（设置同步）且与具体监听实现解耦——本文件只管
/// 「动作 ↔ 按键组合」的数据，不碰 Flutter 焦点树与平台插件。
library;

import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'shortcuts.dart';

/// 快捷键分组：软件内 / 全局。
enum ShortcutScope {
  /// 软件内快捷键：窗口聚焦时生效（Space、←→、Ctrl+F…）。
  inApp,

  /// 全局快捷键：系统级注册，窗口失焦也生效（默认关闭，避免抢占系统热键）。
  global,
}

/// 一条按键组合（主键 + 修饰键），可序列化为设置存储字符串。
///
/// 存储格式：`ctrl+alt+shift+meta+<keyName>`（修饰键固定顺序、小写；
/// `keyName` 用 `LogicalKeyboardKey.keyLabel` 的稳定名，如 `space` /
/// `arrowLeft` / `digit1` / `keyM`）。
class ShortcutCombo {
  const ShortcutCombo({
    required this.key,
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool meta;

  /// 是否带至少一个修饰键：全局热键必须带修饰键（`RegisterHotKey` /
  /// X11 grab 都要靠修饰键避免抢走普通按键），校验见 [isValidForScope]。
  bool get hasModifier => ctrl || shift || alt || meta;

  /// 与一次按键事件是否匹配（主键相等 + 修饰键全等）。
  bool matches(
    LogicalKeyboardKey eventKey, {
    required bool ctrl,
    required bool shift,
    required bool alt,
    required bool meta,
  }) =>
      key == eventKey &&
      this.ctrl == ctrl &&
      this.shift == shift &&
      this.alt == alt &&
      this.meta == meta;

  /// 该组合能否用于某个分组：全局热键要求带修饰键（软件内允许单键，
  /// 如 Space / Esc）。
  bool isValidForScope(ShortcutScope scope) =>
      scope == ShortcutScope.inApp || hasModifier;

  /// 设置存储字符串（见类文档）。
  String encode() {
    final parts = <String>[
      if (ctrl) 'ctrl',
      if (alt) 'alt',
      if (shift) 'shift',
      if (meta) 'meta',
      _canonicalName(key),
    ];
    return parts.join('+');
  }

  /// 展示文案（`Ctrl + Alt + Space`；单键只显示键名）。
  String label() {
    final parts = <String>[
      if (ctrl) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Meta',
      _keyLabel(key),
    ];
    return parts.join(' + ');
  }

  /// 解析存储字符串；无法解析返回 null（调用方回退默认绑定）。
  static ShortcutCombo? parse(String raw) {
    final tokens = raw
        .split('+')
        .map((token) => token.trim().toLowerCase())
        .where((token) => token.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return null;
    var ctrl = false;
    var shift = false;
    var alt = false;
    var meta = false;
    var modifiersSeen = 0;
    String? keyToken;
    for (final token in tokens) {
      switch (token) {
        case 'ctrl' || 'control':
          ctrl = true;
          modifiersSeen++;
        case 'shift':
          shift = true;
          modifiersSeen++;
        case 'alt' || 'option':
          alt = true;
          modifiersSeen++;
        case 'meta' || 'cmd' || 'win' || 'super':
          meta = true;
          modifiersSeen++;
        default:
          // 主键只允许出现一次（`ctrl+ctrl` 之类视为非法）。
          if (keyToken != null) return null;
          keyToken = token;
      }
    }
    // 修饰键不允许重复（`ctrl+ctrl+a` 是坏数据，别悄悄降级成 ctrl+a）。
    final distinctModifiers =
        (ctrl ? 1 : 0) + (shift ? 1 : 0) + (alt ? 1 : 0) + (meta ? 1 : 0);
    if (modifiersSeen != distinctModifiers) return null;
    if (keyToken == null) return null;
    final key = _keyByName[keyToken];
    if (key == null) return null;
    return ShortcutCombo(
      key: key,
      ctrl: ctrl,
      shift: shift,
      alt: alt,
      meta: meta,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ShortcutCombo &&
      other.key == key &&
      other.ctrl == ctrl &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, ctrl, shift, alt, meta);
}

/// 动作 → 组合的绑定表（按分组各一份），可编码为 JSON 存入设置。
class ShortcutBindings {
  ShortcutBindings(this.scope, this._overrides);

  /// 本表所属分组（决定默认表与校验口径）。
  final ShortcutScope scope;

  /// 用户覆盖（只存改动过的动作）；未覆盖的动作取 [defaults]。
  final Map<ShortcutCommand, ShortcutCombo> _overrides;

  /// 软件内默认绑定（用户定稿名单；不含 Ctrl+Q）。
  static const Map<ShortcutCommand, ShortcutCombo> inAppDefaults = {
    ShortcutCommand.togglePlayPause: ShortcutCombo(
      key: LogicalKeyboardKey.space,
    ),
    ShortcutCommand.seekBackward: ShortcutCombo(
      key: LogicalKeyboardKey.arrowLeft,
    ),
    ShortcutCommand.seekForward: ShortcutCombo(
      key: LogicalKeyboardKey.arrowRight,
    ),
    ShortcutCommand.previousTrack: ShortcutCombo(
      key: LogicalKeyboardKey.arrowLeft,
      ctrl: true,
    ),
    ShortcutCommand.nextTrack: ShortcutCombo(
      key: LogicalKeyboardKey.arrowRight,
      ctrl: true,
    ),
    ShortcutCommand.volumeUp: ShortcutCombo(key: LogicalKeyboardKey.arrowUp),
    ShortcutCommand.volumeDown: ShortcutCombo(
      key: LogicalKeyboardKey.arrowDown,
    ),
    ShortcutCommand.toggleMute: ShortcutCombo(key: LogicalKeyboardKey.keyM),
    ShortcutCommand.focusSearch: ShortcutCombo(
      key: LogicalKeyboardKey.keyF,
      ctrl: true,
    ),
    ShortcutCommand.selectDestination1: ShortcutCombo(
      key: LogicalKeyboardKey.digit1,
      ctrl: true,
    ),
    ShortcutCommand.selectDestination2: ShortcutCombo(
      key: LogicalKeyboardKey.digit2,
      ctrl: true,
    ),
    ShortcutCommand.selectDestination3: ShortcutCombo(
      key: LogicalKeyboardKey.digit3,
      ctrl: true,
    ),
    ShortcutCommand.closeQueuePanel: ShortcutCombo(
      key: LogicalKeyboardKey.escape,
    ),
  };

  /// 全局默认绑定（全部 Ctrl+Alt 前缀：全局热键必须带修饰键，且这个前缀
  /// 在三大桌面平台上都极少被系统占用；默认整体关闭，用户开启后才注册）。
  static const Map<ShortcutCommand, ShortcutCombo> globalDefaults = {
    ShortcutCommand.togglePlayPause: ShortcutCombo(
      key: LogicalKeyboardKey.space,
      ctrl: true,
      alt: true,
    ),
    ShortcutCommand.previousTrack: ShortcutCombo(
      key: LogicalKeyboardKey.arrowLeft,
      ctrl: true,
      alt: true,
    ),
    ShortcutCommand.nextTrack: ShortcutCombo(
      key: LogicalKeyboardKey.arrowRight,
      ctrl: true,
      alt: true,
    ),
    ShortcutCommand.volumeUp: ShortcutCombo(
      key: LogicalKeyboardKey.arrowUp,
      ctrl: true,
      alt: true,
    ),
    ShortcutCommand.volumeDown: ShortcutCombo(
      key: LogicalKeyboardKey.arrowDown,
      ctrl: true,
      alt: true,
    ),
    ShortcutCommand.toggleMute: ShortcutCombo(
      key: LogicalKeyboardKey.keyM,
      ctrl: true,
      alt: true,
    ),
    ShortcutCommand.showMainWindow: ShortcutCombo(
      key: LogicalKeyboardKey.keyW,
      ctrl: true,
      alt: true,
    ),
  };

  /// 本分组的默认表。
  static Map<ShortcutCommand, ShortcutCombo> defaultsOf(ShortcutScope scope) =>
      scope == ShortcutScope.inApp ? inAppDefaults : globalDefaults;

  /// 本分组的动作全集（顺序 = 设置页展示顺序）。
  static List<ShortcutCommand> commandsOf(ShortcutScope scope) =>
      defaultsOf(scope).keys.toList(growable: false);

  /// 某动作的当前绑定（覆盖优先，其次默认；动作不属于本分组时返回 null）。
  ShortcutCombo? comboFor(ShortcutCommand command) {
    final override = _overrides[command];
    if (override != null) return override;
    return defaultsOf(scope)[command];
  }

  /// 当前生效的全部绑定（含未覆盖的默认项）。
  Map<ShortcutCommand, ShortcutCombo> get effective => {
        for (final command in commandsOf(scope))
          if (comboFor(command) != null) command: comboFor(command)!,
      };

  /// 该动作是否被用户改过（设置页「恢复默认」按钮的可用性判定）。
  bool isOverridden(ShortcutCommand command) =>
      _overrides.containsKey(command);

  /// 覆盖某动作的绑定；[combo] 为空表示清掉覆盖（回默认）。
  ShortcutBindings withOverride(ShortcutCommand command, ShortcutCombo? combo) {
    final next = Map<ShortcutCommand, ShortcutCombo>.of(_overrides);
    if (combo == null) {
      next.remove(command);
    } else {
      next[command] = combo;
    }
    return ShortcutBindings(scope, next);
  }

  /// 清空全部覆盖（整组恢复默认）。
  ShortcutBindings cleared() => ShortcutBindings(scope, const {});

  /// 与另一次按键事件冲突的动作（同组内主键 + 修饰键全等；用于设置页提示
  /// 「已占用」）。[exclude] 是正在编辑的动作本身。
  ShortcutCommand? conflictWith(
    ShortcutCombo combo, {
    ShortcutCommand? exclude,
  }) {
    for (final entry in effective.entries) {
      if (entry.key == exclude) continue;
      if (entry.value == combo) return entry.key;
    }
    return null;
  }

  /// 序列化为设置存储字符串（JSON：`{"togglePlayPause":"ctrl+space"}`）；
  /// 无覆盖时返回空串（不写无意义的 `{}`）。
  String encode() {
    if (_overrides.isEmpty) return '';
    final entries = <String>[
      for (final entry in _overrides.entries)
        '"${entry.key.name}":"${entry.value.encode()}"',
    ];
    return '{${entries.join(',')}}';
  }

  /// 从设置存储字符串解析；空串 / 损坏内容回退为「无覆盖」。
  static ShortcutBindings decode(ShortcutScope scope, String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return ShortcutBindings(scope, const {});
    }
    final overrides = <ShortcutCommand, ShortcutCombo>{};
    // 轻量解析（不引 dart:convert 的 jsonDecode 是为了容忍手工改坏的存储：
    // 逐条解析、坏条目跳过，而不是整表丢弃）。
    final pattern = RegExp(r'"([A-Za-z0-9_]+)"\s*:\s*"([^"]*)"');
    for (final match in pattern.allMatches(raw)) {
      final command = _commandByName[match.group(1)];
      final combo = ShortcutCombo.parse(match.group(2)!);
      if (command == null || combo == null) continue;
      if (!defaultsOf(scope).containsKey(command)) continue;
      if (!combo.isValidForScope(scope)) continue;
      overrides[command] = combo;
    }
    return ShortcutBindings(scope, overrides);
  }
}

/// `LogicalKeyboardKey` 稳定名 → 键：只收可绑定的键（字母 / 数字 / 方向 /
/// 功能键与常见编辑键），其余按键不参与录制与解析。
///
/// 名字不能直接用 `keyLabel`（空格是 `' '`、方向键是 `''`），改为「字母数字
/// 用 keyLabel，其余走显式表」的规范名，编码与解析共用同一张表。
final Map<String, LogicalKeyboardKey> _keyByName = {
  for (final key in _bindableKeys) _canonicalName(key): key,
};

/// 非字母数字键的显式规范名（空格 / 方向 / 编辑键等）。
final Map<LogicalKeyboardKey, String> _specialKeyNames = {
  LogicalKeyboardKey.space: 'space',
  LogicalKeyboardKey.escape: 'escape',
  LogicalKeyboardKey.enter: 'enter',
  LogicalKeyboardKey.arrowLeft: 'arrowleft',
  LogicalKeyboardKey.arrowRight: 'arrowright',
  LogicalKeyboardKey.arrowUp: 'arrowup',
  LogicalKeyboardKey.arrowDown: 'arrowdown',
  LogicalKeyboardKey.comma: 'comma',
  LogicalKeyboardKey.period: 'period',
  LogicalKeyboardKey.slash: 'slash',
  LogicalKeyboardKey.semicolon: 'semicolon',
  LogicalKeyboardKey.quote: 'quote',
  LogicalKeyboardKey.bracketLeft: 'bracketleft',
  LogicalKeyboardKey.bracketRight: 'bracketright',
  LogicalKeyboardKey.minus: 'minus',
  LogicalKeyboardKey.equal: 'equal',
  LogicalKeyboardKey.backslash: 'backslash',
  LogicalKeyboardKey.backquote: 'backquote',
};

/// 键的规范名（编码 / 解析共用；见 [_keyByName]）。
String _canonicalName(LogicalKeyboardKey key) {
  final special = _specialKeyNames[key];
  if (special != null) return special;
  final label = key.keyLabel.trim().toLowerCase();
  return label.isEmpty ? 'key${key.keyId.toRadixString(16)}' : label;
}

/// 可绑定的键集合（录制时也只接受这些键）。
const List<LogicalKeyboardKey> _bindableKeys = [
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.escape,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
  LogicalKeyboardKey.digit0,
  LogicalKeyboardKey.keyA,
  LogicalKeyboardKey.keyB,
  LogicalKeyboardKey.keyC,
  LogicalKeyboardKey.keyD,
  LogicalKeyboardKey.keyE,
  LogicalKeyboardKey.keyF,
  LogicalKeyboardKey.keyG,
  LogicalKeyboardKey.keyH,
  LogicalKeyboardKey.keyI,
  LogicalKeyboardKey.keyJ,
  LogicalKeyboardKey.keyK,
  LogicalKeyboardKey.keyL,
  LogicalKeyboardKey.keyM,
  LogicalKeyboardKey.keyN,
  LogicalKeyboardKey.keyO,
  LogicalKeyboardKey.keyP,
  LogicalKeyboardKey.keyQ,
  LogicalKeyboardKey.keyR,
  LogicalKeyboardKey.keyS,
  LogicalKeyboardKey.keyT,
  LogicalKeyboardKey.keyU,
  LogicalKeyboardKey.keyV,
  LogicalKeyboardKey.keyW,
  LogicalKeyboardKey.keyX,
  LogicalKeyboardKey.keyY,
  LogicalKeyboardKey.keyZ,
  LogicalKeyboardKey.f1,
  LogicalKeyboardKey.f2,
  LogicalKeyboardKey.f3,
  LogicalKeyboardKey.f4,
  LogicalKeyboardKey.f5,
  LogicalKeyboardKey.f6,
  LogicalKeyboardKey.f7,
  LogicalKeyboardKey.f8,
  LogicalKeyboardKey.f9,
  LogicalKeyboardKey.f10,
  LogicalKeyboardKey.f11,
  LogicalKeyboardKey.f12,
  LogicalKeyboardKey.comma,
  LogicalKeyboardKey.period,
  LogicalKeyboardKey.slash,
  LogicalKeyboardKey.semicolon,
  LogicalKeyboardKey.quote,
  LogicalKeyboardKey.bracketLeft,
  LogicalKeyboardKey.bracketRight,
  LogicalKeyboardKey.minus,
  LogicalKeyboardKey.equal,
  LogicalKeyboardKey.backslash,
  LogicalKeyboardKey.backquote,
];

/// 是否是可绑定的键（录制 UI 用：不可绑定的键不写进组合）。
bool isBindableKey(LogicalKeyboardKey key) => _bindableKeys.contains(key);

/// 动作名 → 动作（存储反序列化用）。
final Map<String, ShortcutCommand> _commandByName = {
  for (final command in ShortcutCommand.values) command.name: command,
};

/// 键的展示名（方向键 / 空格 / Esc 等给中文可读文案，其余用 keyLabel）。
String _keyLabel(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.space) return 'Space';
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.enter) return 'Enter';
  if (key == LogicalKeyboardKey.arrowLeft) return '←';
  if (key == LogicalKeyboardKey.arrowRight) return '→';
  if (key == LogicalKeyboardKey.arrowUp) return '↑';
  if (key == LogicalKeyboardKey.arrowDown) return '↓';
  final label = key.keyLabel;
  return label.isEmpty ? '?' : label;
}
