import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/shortcuts.dart';

/// 桌面全局快捷键映射表：命中口径（含修饰键）与让位口径。
void main() {
  test('无修饰键：播放 / 进度 / 音量 / 静音 / Esc 命中', () {
    expect(
      shortcutFor(LogicalKeyboardKey.space),
      ShortcutCommand.togglePlayPause,
    );
    expect(
      shortcutFor(LogicalKeyboardKey.arrowLeft),
      ShortcutCommand.seekBackward,
    );
    expect(
      shortcutFor(LogicalKeyboardKey.arrowRight),
      ShortcutCommand.seekForward,
    );
    expect(shortcutFor(LogicalKeyboardKey.arrowUp), ShortcutCommand.volumeUp);
    expect(
      shortcutFor(LogicalKeyboardKey.arrowDown),
      ShortcutCommand.volumeDown,
    );
    expect(shortcutFor(LogicalKeyboardKey.keyM), ShortcutCommand.toggleMute);
    expect(
      shortcutFor(LogicalKeyboardKey.escape),
      ShortcutCommand.closeQueuePanel,
    );
  });

  test('Ctrl：切歌 / 聚焦搜索 / 切目的地命中', () {
    expect(
      shortcutFor(LogicalKeyboardKey.arrowLeft, ctrl: true),
      ShortcutCommand.previousTrack,
    );
    expect(
      shortcutFor(LogicalKeyboardKey.arrowRight, ctrl: true),
      ShortcutCommand.nextTrack,
    );
    expect(
      shortcutFor(LogicalKeyboardKey.keyF, ctrl: true),
      ShortcutCommand.focusSearch,
    );
    expect(
      shortcutFor(LogicalKeyboardKey.digit1, ctrl: true),
      ShortcutCommand.selectDestination1,
    );
    expect(
      shortcutFor(LogicalKeyboardKey.digit2, ctrl: true),
      ShortcutCommand.selectDestination2,
    );
    expect(
      shortcutFor(LogicalKeyboardKey.digit3, ctrl: true),
      ShortcutCommand.selectDestination3,
    );
  });

  test('Shift / Alt / Meta 参与一律不命中（让位系统与文本编辑）', () {
    expect(shortcutFor(LogicalKeyboardKey.space, shift: true), isNull);
    expect(shortcutFor(LogicalKeyboardKey.arrowLeft, alt: true), isNull);
    expect(shortcutFor(LogicalKeyboardKey.keyF, meta: true), isNull);
    expect(
      shortcutFor(LogicalKeyboardKey.digit1, ctrl: true, shift: true),
      isNull,
    );
    expect(
      shortcutFor(LogicalKeyboardKey.arrowRight, ctrl: true, alt: true),
      isNull,
    );
  });

  test('未列入名单的键不命中', () {
    expect(shortcutFor(LogicalKeyboardKey.keyQ), isNull);
    expect(shortcutFor(LogicalKeyboardKey.keyQ, ctrl: true), isNull);
    expect(shortcutFor(LogicalKeyboardKey.enter), isNull);
    expect(shortcutFor(LogicalKeyboardKey.digit4, ctrl: true), isNull);
    // Ctrl 下的方向键只认左右：上下不参与切歌 / 音量。
    expect(shortcutFor(LogicalKeyboardKey.arrowUp, ctrl: true), isNull);
    expect(shortcutFor(LogicalKeyboardKey.arrowDown, ctrl: true), isNull);
  });
}
