import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/global_hotkeys.dart';
import 'package:molia/services/shortcut_bindings.dart';
import 'package:molia/services/shortcuts.dart';

/// 全局热键注册层：组合 → 注册参数的纯映射，以及开关 / 设置变更下的
/// 注册、注销调度（注入假注册器，不触达平台通道）。
void main() {
  setUp(() async {
    await GlobalHotkeys.detachForTesting();
  });

  tearDown(() async {
    await GlobalHotkeys.detachForTesting();
  });

  test('组合 → 注册参数：主键与修饰键一一映射，默认表全部可还原', () {
    expect(
      hotKeySpecFor(
        const ShortcutCombo(
          key: LogicalKeyboardKey.space,
          ctrl: true,
          alt: true,
        ),
      ),
      (
        keyId: LogicalKeyboardKey.space.keyId,
        ctrl: true,
        alt: true,
        shift: false,
        meta: false,
      ),
    );

    for (final entry in ShortcutBindings.globalDefaults.entries) {
      final spec = hotKeySpecFor(entry.value);
      expect(
        LogicalKeyboardKey.findKeyByKeyId(spec.keyId),
        entry.value.key,
        reason: '${entry.key.name} 的主键经 keyId 可还原',
      );
      expect(spec.ctrl, entry.value.ctrl, reason: entry.key.name);
      expect(spec.alt, entry.value.alt, reason: entry.key.name);
      expect(spec.shift, entry.value.shift, reason: entry.key.name);
      expect(spec.meta, entry.value.meta, reason: entry.key.name);
    }
  });

  test('开关关闭：只注销、不发注册请求', () async {
    final registrar = _RecordingRegistrar();
    GlobalHotkeys.registrarOverride = registrar;
    GlobalHotkeys.settingsOverride = _FakeSettings(globalEnabled: false);

    await GlobalHotkeys.attach();

    expect(registrar.calls, ['unregisterAll']);
    expect(registrar.registered, isEmpty);
    expect(GlobalHotkeys.lastError, isNull);
  });

  test('设置变化：每轮先注销再按新表注册，同一组合不重复注册', () async {
    final registrar = _RecordingRegistrar();
    final settings = _FakeSettings(globalEnabled: true);
    GlobalHotkeys.registrarOverride = registrar;
    GlobalHotkeys.settingsOverride = settings;

    await GlobalHotkeys.attach();
    final count = ShortcutBindings.globalDefaults.length;
    _expectCleanRound(registrar, count);

    // 改一条绑定并通知：整轮先注销、再按新表注册。
    registrar.reset();
    settings.globalBindings = settings.globalBindings.withOverride(
      ShortcutCommand.showMainWindow,
      const ShortcutCombo(key: LogicalKeyboardKey.keyQ, ctrl: true, alt: true),
    );
    settings.notifyListeners();
    await GlobalHotkeys.flushPendingSync();

    _expectCleanRound(registrar, count);
    final keyIds = registrar.registered.map((spec) => spec.keyId);
    expect(keyIds, contains(LogicalKeyboardKey.keyQ.keyId));
    expect(keyIds, isNot(contains(LogicalKeyboardKey.keyW.keyId)));

    // 关闭开关：只注销，注册请求清空。
    registrar.reset();
    settings.globalEnabled = false;
    settings.notifyListeners();
    await GlobalHotkeys.flushPendingSync();

    expect(registrar.calls, ['unregisterAll']);
    expect(registrar.registered, isEmpty);
  });
}

/// 每轮注册的固定形状：第一条是注销，之后全是注册，且组合不重复。
void _expectCleanRound(_RecordingRegistrar registrar, int count) {
  expect(registrar.calls.first, 'unregisterAll');
  expect(
    registrar.calls.skip(1).every((call) => call.startsWith('register:')),
    isTrue,
    reason: '注销必须发生在全部注册之前',
  );
  expect(registrar.registered, hasLength(count));
  expect(registrar.registered.toSet(), hasLength(count), reason: '同一组合不重复注册');
}

/// 记录调用顺序的假注册器：单测不触达平台通道。
class _RecordingRegistrar implements GlobalHotkeyRegistrar {
  final List<String> calls = [];
  final List<HotKeySpec> registered = [];

  @override
  Future<void> register(HotKeySpec spec, VoidCallback onPressed) async {
    calls.add('register:${spec.keyId}');
    registered.add(spec);
  }

  @override
  Future<void> unregisterAll() async {
    calls.add('unregisterAll');
  }

  void reset() {
    calls.clear();
    registered.clear();
  }
}

/// 内存设置源：可改开关 / 绑定并手动通知。
class _FakeSettings extends ChangeNotifier implements GlobalHotkeySettings {
  _FakeSettings({
    required this.globalEnabled,
    ShortcutBindings? globalBindings,
  }) : globalBindings =
            globalBindings ?? ShortcutBindings(ShortcutScope.global, const {});

  @override
  bool globalEnabled;

  @override
  ShortcutBindings globalBindings;
}
