import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/audio_cache_platform.dart';

void main() {
  test('边播边缓存：只有 Android / iOS / macOS（桌面不写）', () {
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      expect(platformSupportsAudioCaching(platform: platform), isTrue);
    }
    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.fuchsia,
    ]) {
      expect(platformSupportsAudioCaching(platform: platform), isFalse);
    }
  });
}
