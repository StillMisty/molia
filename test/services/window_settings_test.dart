import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/window_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 窗口行为设置：默认值、持久化与变更通知（设备本地键，不登记同步注册表）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // 静态 notifier 在测试间共享：每例回到默认值再开跑。
    await WindowSettings.setRememberBounds(
        WindowSettings.defaultRememberBounds);
    await WindowSettings.load();
  });

  test('默认值：记住窗口位置与大小默认开启', () async {
    expect(WindowSettings.rememberBounds, isTrue);
    expect(WindowSettings.defaultRememberBounds, isTrue);
  });

  test('持久化：关闭后写入存储，重新 load 仍生效', () async {
    await WindowSettings.setRememberBounds(false);
    expect(WindowSettings.rememberBounds, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(WindowSettings.keyRememberBounds), isFalse);

    // 模拟重启：内存值先回到默认（不写存储），load 应从存储恢复关闭态。
    WindowSettings.rememberBoundsNotifier.value =
        WindowSettings.defaultRememberBounds;
    await WindowSettings.load();
    expect(WindowSettings.rememberBounds, isFalse);
  });

  test('值未变化时不重复通知', () async {
    var notifications = 0;
    void listener() => notifications++;
    WindowSettings.rememberBoundsNotifier.addListener(listener);
    addTearDown(
      () => WindowSettings.rememberBoundsNotifier.removeListener(listener),
    );

    await WindowSettings.setRememberBounds(
        WindowSettings.defaultRememberBounds);
    expect(notifications, 0);

    await WindowSettings.setRememberBounds(
        !WindowSettings.defaultRememberBounds);
    expect(notifications, 1);
  });

  test('无持久化值（首次启动 / 存储不可用）：按默认开启处理', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(WindowSettings.keyRememberBounds);
    await WindowSettings.load();
    expect(WindowSettings.rememberBounds, WindowSettings.defaultRememberBounds);
  });
}
