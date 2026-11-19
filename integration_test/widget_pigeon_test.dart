import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:molia/platform/pigeon/widget.g.dart';
import 'package:molia/platform/pigeon/widget_adapter.dart';

/// Widget 域 Pigeon native interop 冒烟（issue #78）。
///
/// ```bash
/// flutter test integration_test/widget_pigeon_test.dart -d <android-device>
/// ```
///
/// 直接调用生成的 HostApi：验证 JNI 注册、参数编码与 Kotlin 实现均可跑通；
/// 没有小组件实例时更新循环为空，同样不应抛异常。不 mock JNI，也不测生成
/// 代码内部；非 Android 直接跳过。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('直接调用 WidgetApi.update 不抛异常', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('widget_pigeon_test skipped: 仅 Android 跑 native interop');
      return;
    }

    final api = WidgetApi.createWithNativeInteropApi();
    await api.update(
      WidgetPayload(
        songName: 'Pigeon 冒烟',
        artistName: 'Molia',
        albumArtUrl: '',
        isPlaying: true,
      ),
    );
  });

  testWidgets('适配器路径（含 channel fallback）不抛异常', (tester) async {
    if (!Platform.isAndroid) {
      debugPrint('widget_pigeon_test skipped: 仅 Android 跑 native interop');
      return;
    }

    await updateAndroidWidget({
      'songName': 'Pigeon 冒烟',
      'artistName': 'Molia',
      'albumArtUrl': '',
      'isPlaying': false,
    });
  });
}
