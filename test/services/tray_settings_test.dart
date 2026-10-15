import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/window/tray_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 托盘行为设置：默认值、持久化与变更通知。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('默认值：关闭时最小化到托盘默认开启', () async {
    final settings = TraySettings();
    await settings.init();
    expect(settings.closeToTray, isTrue);
    expect(TraySettings.defaultCloseToTray, isTrue);
  });

  test('持久化：设置后重新加载仍生效', () async {
    final settings = TraySettings();
    await settings.init();
    await settings.setCloseToTray(false);

    final reloaded = TraySettings();
    await reloaded.init();
    expect(reloaded.closeToTray, isFalse);

    await reloaded.setCloseToTray(true);
    final again = TraySettings();
    await again.init();
    expect(again.closeToTray, isTrue);
  });

  test('值未变化时不重复通知', () async {
    final settings = TraySettings();
    await settings.init();
    var notifications = 0;
    settings.addListener(() => notifications++);

    await settings.setCloseToTray(TraySettings.defaultCloseToTray);
    expect(notifications, 0);

    await settings.setCloseToTray(!TraySettings.defaultCloseToTray);
    expect(notifications, 1);
    settings.dispose();
  });
}
