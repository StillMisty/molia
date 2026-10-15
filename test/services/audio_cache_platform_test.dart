import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/audio_cache_platform.dart';

void main() {
  test('边播边缓存：只有 Android / iOS / macOS（桌面与 Web 不写）', () {
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
    expect(
      platformSupportsAudioCaching(platform: TargetPlatform.android, isWeb: true),
      isFalse,
    );
  });

  test('后台字节预取：IO 平台都支持（桌面靠它补缓存），Web 不支持', () {
    expect(platformSupportsAudioPrefetch(), isTrue);
    expect(platformSupportsAudioPrefetch(isWeb: true), isFalse);
  });
}
