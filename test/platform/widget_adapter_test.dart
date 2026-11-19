import 'package:flutter_test/flutter_test.dart';
import 'package:molia/platform/pigeon/widget_adapter.dart';

/// 小组件 payload → Pigeon [WidgetPayload] 的纯映射（issue #78）。
///
/// 不启动 JNI：只验证类型投影与缺失字段的降级；native 调用本身由 Android
/// 集成测试 / release 冒烟覆盖。
void main() {
  group('widgetPayloadFromMap', () {
    test('播放快照字段原样投影', () {
      final payload = widgetPayloadFromMap({
        'songName': '歌名',
        'artistName': '歌手',
        'albumArtUrl': 'https://img.example/a.jpg',
        'isPlaying': true,
      });

      expect(payload.songName, '歌名');
      expect(payload.artistName, '歌手');
      expect(payload.albumArtUrl, 'https://img.example/a.jpg');
      expect(payload.isPlaying, isTrue);
    });

    test('缺失或类型不符时给空串 / false，不用本地化文案', () {
      final payload = widgetPayloadFromMap({
        'songName': null,
        'artistName': 42,
        'isPlaying': 'yes',
      });

      expect(payload.songName, '');
      expect(payload.artistName, '');
      expect(payload.albumArtUrl, '');
      expect(payload.isPlaying, isFalse);
    });

    test('省流模式传空封面时保持空串', () {
      final payload = widgetPayloadFromMap({
        'songName': '歌名',
        'artistName': '',
        'albumArtUrl': '',
        'isPlaying': false,
      });

      expect(payload.albumArtUrl, '');
      expect(payload.isPlaying, isFalse);
    });
  });
}
