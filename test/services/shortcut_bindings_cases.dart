import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/shortcut_bindings.dart';
import 'package:molia/services/shortcuts.dart';

/// 快捷键绑定模型：序列化往返、非法输入容错、分组校验与冲突判定。
void main() {
  test('组合编码 / 解析往返（修饰键顺序固定、大小写不敏感）', () {
    const combo = ShortcutCombo(
      key: LogicalKeyboardKey.space,
      ctrl: true,
      alt: true,
    );
    expect(combo.encode(), 'ctrl+alt+space');
    expect(ShortcutCombo.parse('Ctrl+Alt+Space'), combo);
    expect(ShortcutCombo.parse('space'), const ShortcutCombo(
      key: LogicalKeyboardKey.space,
    ));
    expect(ShortcutCombo.parse('ctrl+ctrl+space'), isNull, reason: '主键重复非法');
    expect(ShortcutCombo.parse('ctrl+notakey'), isNull);
    expect(ShortcutCombo.parse(''), isNull);
  });

  test('展示文案：修饰键 + 可读键名', () {
    const combo = ShortcutCombo(
      key: LogicalKeyboardKey.arrowLeft,
      ctrl: true,
    );
    expect(combo.label(), 'Ctrl + ←');
    expect(
      const ShortcutCombo(key: LogicalKeyboardKey.space).label(),
      'Space',
    );
  });

  test('全局分组要求带修饰键（软件内允许单键）', () {
    const single = ShortcutCombo(key: LogicalKeyboardKey.space);
    expect(single.isValidForScope(ShortcutScope.inApp), isTrue);
    expect(single.isValidForScope(ShortcutScope.global), isFalse);
  });

  test('覆盖优先于默认；清覆盖回默认；整组清空', () {
    final bindings = ShortcutBindings(ShortcutScope.inApp, const {});
    expect(
      bindings.comboFor(ShortcutCommand.togglePlayPause)!.key,
      LogicalKeyboardKey.space,
    );

    final custom = bindings.withOverride(
      ShortcutCommand.togglePlayPause,
      const ShortcutCombo(key: LogicalKeyboardKey.keyP, ctrl: true),
    );
    expect(custom.isOverridden(ShortcutCommand.togglePlayPause), isTrue);
    expect(custom.comboFor(ShortcutCommand.togglePlayPause)!.ctrl, isTrue);
    expect(
      custom.withOverride(ShortcutCommand.togglePlayPause, null)
          .isOverridden(ShortcutCommand.togglePlayPause),
      isFalse,
    );
    expect(custom.cleared().isOverridden(ShortcutCommand.togglePlayPause),
        isFalse);
  });

  test('序列化往返：只存覆盖项，坏条目跳过', () {
    final bindings = ShortcutBindings(ShortcutScope.inApp, const {})
        .withOverride(
          ShortcutCommand.toggleMute,
          const ShortcutCombo(key: LogicalKeyboardKey.keyJ),
        );
    final encoded = bindings.encode();
    final decoded = ShortcutBindings.decode(ShortcutScope.inApp, encoded);
    expect(decoded.comboFor(ShortcutCommand.toggleMute)!.key,
        LogicalKeyboardKey.keyJ);

    // 坏条目：未知动作 / 非法组合 / 不属于本分组的动作（全局专用动作）
    final tolerant = ShortcutBindings.decode(
      ShortcutScope.inApp,
      '{"nopeCommand":"ctrl+a","toggleMute":"ctrl+ctrl+a",'
      '"showMainWindow":"ctrl+alt+w","nextTrack":"ctrl+arrowRight"}',
    );
    expect(tolerant.isOverridden(ShortcutCommand.toggleMute), isFalse);
    expect(tolerant.isOverridden(ShortcutCommand.showMainWindow), isFalse);
    expect(tolerant.comboFor(ShortcutCommand.nextTrack)!.ctrl, isTrue);

    // 空串 / null 回退「无覆盖」
    expect(ShortcutBindings.decode(ShortcutScope.global, null).encode(), '');
    expect(ShortcutBindings.decode(ShortcutScope.global, '').encode(), '');
  });

  test('冲突判定：同组内主键 + 修饰键全等即占用（排除正在编辑的动作）', () {
    final bindings = ShortcutBindings(ShortcutScope.inApp, const {});
    final conflict = bindings.conflictWith(
      const ShortcutCombo(key: LogicalKeyboardKey.space),
      exclude: ShortcutCommand.togglePlayPause,
    );
    expect(conflict, isNull, reason: '排除自己后不冲突');
    expect(
      bindings.conflictWith(const ShortcutCombo(key: LogicalKeyboardKey.space)),
      ShortcutCommand.togglePlayPause,
    );
  });
}
