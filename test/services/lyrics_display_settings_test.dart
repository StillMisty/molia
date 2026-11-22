import 'package:flutter_test/flutter_test.dart';

import 'lyrics_display_settings_cases.dart' as services_lyrics_display_settings;

/// 桌面 / 通知 / 蓝牙歌词输出配置：默认值、JSON 往返与落盘防抖。
///
/// 单独成文件：用例依赖 `setMockInitialValues` 的干净 prefs，与歌词缓存
/// 用例同进程时会被后者的 prefs 实例抢读默认值。
void main() {
  group('lyrics display settings', services_lyrics_display_settings.main);
}
