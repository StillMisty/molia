import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/haptics.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 震动反馈服务：开关（默认开）与三档触感的唯一入口。
///
/// 平台通道用 mock handler 观测：关闭后必须**一次都不调**，开启时按档位
/// 触发对应 `HapticFeedbackType`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 本应用发出的震动请求（值为 `HapticFeedbackType` 字符串）。
  late List<String> vibrations;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    vibrations = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        vibrations.add(call.arguments as String? ?? '');
      }
      return null;
    });
    // 回到默认开关（静态状态在测试间共享，load 无持久化值即默认开启）。
    await HapticsService.load();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('默认开启：三档触感各触发一次对应平台调用', () async {
    expect(HapticsService.enabled, isTrue);

    HapticsService.lightImpact();
    HapticsService.mediumImpact();
    HapticsService.selectionClick();
    await pumpEventQueue();

    expect(vibrations, [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.mediumImpact',
      'HapticFeedbackType.selectionClick',
    ]);
  });

  test('关闭后：任何一档触感都不触碰平台通道，并写入持久化', () async {
    await HapticsService.setEnabled(false);
    expect(HapticsService.enabled, isFalse);

    HapticsService.lightImpact();
    HapticsService.mediumImpact();
    HapticsService.selectionClick();
    await pumpEventQueue();
    expect(vibrations, isEmpty, reason: '关闭后不应发出任何震动请求');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(HapticsService.keyEnabled), isFalse);
  });

  test('持久化：重启（load）后恢复保存的开关', () async {
    await HapticsService.setEnabled(false);
    await HapticsService.load();

    expect(HapticsService.enabled, isFalse);
    HapticsService.lightImpact();
    await pumpEventQueue();
    expect(vibrations, isEmpty);

    await HapticsService.setEnabled(true);
    await HapticsService.load();
    expect(HapticsService.enabled, isTrue);
  });

  test('无持久化值（首次启动 / 存储不可用）：按默认开启处理', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(HapticsService.keyEnabled);
    await HapticsService.load();

    expect(HapticsService.enabled, HapticsService.defaultEnabled);
    expect(HapticsService.enabled, isTrue);
  });
}
