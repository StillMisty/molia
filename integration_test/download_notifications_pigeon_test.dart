import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:molia/data/downloads/download_notifications_io.dart';
import 'package:molia/data/downloads/download_notifications_types.dart';
import 'package:molia/platform/pigeon/download_notifications_adapter.dart';

/// DownloadNotifications 域 Pigeon channel 冒烟（issue #82）。
///
/// ```bash
/// flutter test integration_test/download_notifications_pigeon_test.dart -d <android-device>
/// ```
///
/// 验证 Pigeon host 在 `MainActivity.configureFlutterEngine` 注册成功、
/// start / update / stop 调用不抛；未授予通知权限时原生 no-op 也走同一条
/// 正常返回路径。旧 `top.stillmisty.molia/download_notifications` 通道保留为
/// fallback，同样不应抛异常。非 Android 直接跳过。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Pigeon host：start / update / stop 不抛', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('download_notifications_pigeon_test skipped: 仅 Android');
      return;
    }

    final adapter = PigeonDownloadNotificationsAdapter();
    expect(adapter.supported, isTrue);

    // 未知总大小 → 确定进度；max 0 → 回到不确定进度。
    await adapter.start(
      id: 'pigeon-smoke:downloads',
      title: 'Pigeon Smoke',
      subtitle: '集成测试',
      index: 1,
      total: 1,
      progress: 0,
    );
    expect(
      adapter.transportAvailable,
      isTrue,
      reason: 'Pigeon host 未注册时适配器会把 transport 标记为不可用',
    );
    await adapter.update(
      id: 'pigeon-smoke:downloads',
      progress: 512,
      max: 1024,
    );
    await adapter.update(id: 'pigeon-smoke:downloads', progress: 0, max: 0);
    await adapter.stop('pigeon-smoke:downloads');
  });

  testWidgets('旧 download_notifications 通道仍可用（fallback 契约）', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('download_notifications_pigeon_test skipped: 仅 Android');
      return;
    }

    final legacy = MethodChannelDownloadNotifications(supported: true);
    expect(legacy.supported, isTrue);
    await legacy.start(
      id: 'legacy-smoke:update',
      title: 'Molia',
      subtitle: '1.0.0',
      channel: DownloadNotificationChannel.update,
    );
    await legacy.update(id: 'legacy-smoke:update', progress: 1, max: 2);
    await legacy.stop('legacy-smoke:update');
  });

  testWidgets('工厂默认走 Pigeon 优先组合，start / stop 能收尾', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('download_notifications_pigeon_test skipped: 仅 Android');
      return;
    }

    final notifications = createDownloadNotifications();
    expect(notifications.supported, isTrue);
    await notifications.start(id: 'factory-smoke', title: 'Pigeon Smoke');
    await notifications.update(id: 'factory-smoke', progress: 1, max: 2);
    await notifications.stop('factory-smoke');
  });
}
