import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:molia/data/downloads/downloads_publisher_io.dart';
import 'package:molia/platform/pigeon/downloads_publisher_adapter.dart';

/// DownloadsPublisher 域 Pigeon channel 冒烟（issue #80）。
///
/// ```bash
/// flutter test integration_test/downloads_publisher_pigeon_test.dart -d <android-device>
/// ```
///
/// 验证 Pigeon host 在 `MainActivity.configureFlutterEngine` 注册成功、MediaStore
/// 发布 / 删除闭环可跑，以及旧 `top.stillmisty.molia/downloads` 通道仍可用作
/// fallback。非 Android 直接跳过（其它平台下载根目录本身即公共目录）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Pigeon host：publicRoot / publish / remove 闭环', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('downloads_publisher_pigeon_test skipped: 仅 Android');
      return;
    }

    final adapter = PigeonDownloadsPublisherAdapter();
    final root = await adapter.publicRoot();
    expect(root, endsWith('Download/Molia'));
    expect(
      adapter.transportAvailable,
      isTrue,
      reason: 'Pigeon host 未注册时适配器会把 transport 标记为不可用',
    );

    final tempDir = Directory.systemTemp.createTempSync('molia_pigeon_smoke');
    final source = File('${tempDir.path}/pigeon-smoke.mp3')
      ..writeAsBytesSync(const [1, 2, 3]);
    try {
      final uri = await adapter.publish(
        sourcePath: source.path,
        displayName: 'pigeon-smoke.mp3',
        mimeType: 'audio/mpeg',
        relativeDir: 'pigeon_smoke',
      );
      expect(uri, isNotNull);
      expect(uri, startsWith('content://'));
      expect(await adapter.remove(uri!), isTrue);
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  });

  testWidgets('旧 downloads 通道仍可用（fallback 契约）', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('downloads_publisher_pigeon_test skipped: 仅 Android');
      return;
    }

    final legacy = MethodChannelDownloadsPublisher();
    expect(legacy.supported, isTrue);
    expect(await legacy.publicRoot(), endsWith('Download/Molia'));
    // 空参数与旧语义一致：原生校验后返回 false，不抛异常。
    expect(await legacy.remove(''), isFalse);
  });

  testWidgets('工厂默认走 Pigeon 优先组合，publicRoot 可用', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('downloads_publisher_pigeon_test skipped: 仅 Android');
      return;
    }

    final publisher = createDownloadsPublisher();
    expect(publisher.supported, isTrue);
    expect(await publisher.publicRoot(), endsWith('Download/Molia'));
  });
}
