import 'package:flutter/services.dart'
    show LogicalKeyboardKey, PhysicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/global_hotkeys_types.dart';
import 'package:molia/services/shortcut_bindings.dart';
import 'package:molia/services/shortcuts.dart';

/// 全局热键的纯映射：组合 → 注册参数、物理键 → 平台键码 / accelerator。
void main() {
  test('组合 → 注册参数（命令名作为注册身份）', () {
    const combo = ShortcutCombo(
      key: LogicalKeyboardKey.keyP,
      ctrl: true,
      alt: true,
    );
    final spec = hotKeySpecFor(ShortcutCommand.togglePlayPause, combo);
    expect(spec.id, 'togglePlayPause');
    expect(spec.keyId, LogicalKeyboardKey.keyP.keyId);
    expect(spec.ctrl, isTrue);
    expect(spec.alt, isTrue);
    expect(spec.shift, isFalse);
    expect(spec.meta, isFalse);
  });

  test('物理键 → 平台键码：Linux X11 KeySym / Windows VK / macOS Carbon', () {
    expect(
      platformKeyCode(PhysicalKeyboardKey.keyA, operatingSystem: 'linux'),
      0x61,
    );
    expect(
      platformKeyCode(PhysicalKeyboardKey.keyA, operatingSystem: 'windows'),
      0x41,
    );
    expect(
      platformKeyCode(PhysicalKeyboardKey.keyA, operatingSystem: 'macos'),
      0x00,
    );

    expect(
      platformKeyCode(PhysicalKeyboardKey.digit0, operatingSystem: 'linux'),
      0x30,
    );
    expect(
      platformKeyCode(PhysicalKeyboardKey.digit0, operatingSystem: 'windows'),
      0x30,
    );
    expect(
      platformKeyCode(PhysicalKeyboardKey.digit0, operatingSystem: 'macos'),
      0x1D,
    );

    expect(
      platformKeyCode(PhysicalKeyboardKey.f1, operatingSystem: 'linux'),
      0xFFBE,
    );
    expect(
      platformKeyCode(PhysicalKeyboardKey.f1, operatingSystem: 'windows'),
      0x70,
    );
    expect(
      platformKeyCode(PhysicalKeyboardKey.f1, operatingSystem: 'macos'),
      0x7A,
    );

    expect(
      platformKeyCode(PhysicalKeyboardKey.space, operatingSystem: 'linux'),
      0x20,
    );
    expect(
      platformKeyCode(PhysicalKeyboardKey.space, operatingSystem: 'windows'),
      0x20,
    );
    expect(
      platformKeyCode(PhysicalKeyboardKey.space, operatingSystem: 'macos'),
      0x31,
    );
  });

  test('全局热键只接受字母 / 数字 / F1–F12 / 空格', () {
    for (final key in [
      PhysicalKeyboardKey.keyA,
      PhysicalKeyboardKey.digit0,
      PhysicalKeyboardKey.f1,
      PhysicalKeyboardKey.f12,
      PhysicalKeyboardKey.space,
    ]) {
      expect(isSupportedGlobalKey(key), isTrue, reason: key.debugName);
    }
    for (final key in [
      PhysicalKeyboardKey.arrowLeft,
      PhysicalKeyboardKey.semicolon,
      PhysicalKeyboardKey.escape,
    ]) {
      expect(isSupportedGlobalKey(key), isFalse, reason: key.debugName);
    }
  });

  test('accelerator：修饰键顺序固定，主键用 NativeKey 平台键码', () {
    final accelerator = acceleratorForHotKeySpec((
      id: 'togglePlayPause',
      keyId: LogicalKeyboardKey.keyP.keyId,
      ctrl: true,
      alt: true,
      shift: true,
      meta: true,
    ));
    final keyCode = platformKeyCode(PhysicalKeyboardKey.keyP);
    expect(accelerator, 'Ctrl+Alt+Shift+Meta+NativeKey$keyCode');
  });

  test('不支持的键抛 ArgumentError（方向键在设置层已被拦截）', () {
    expect(
      () => acceleratorForHotKeySpec((
        id: 'togglePlayPause',
        keyId: LogicalKeyboardKey.arrowLeft.keyId,
        ctrl: true,
        alt: false,
        shift: false,
        meta: false,
      )),
      throwsArgumentError,
    );
  });
}
