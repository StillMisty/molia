import 'package:flutter_test/flutter_test.dart';
import 'package:molia/sources/source_track.dart'
    show capQualityFor, pickQualityFor;

/// 省流音质上限纯函数：与 `pickQualityFor` 的回退链路组合后的行为。
void main() {
  group('capQualityFor', () {
    test('偏好高于上限 → 压到上限', () {
      expect(capQualityFor('flac', '128k'), '128k');
      expect(capQualityFor('flac24bit', '128k'), '128k');
      expect(capQualityFor('320k', '128k'), '128k');
      expect(capQualityFor('flac', '320k'), '320k');
    });

    test('偏好不高于上限 → 保持偏好', () {
      expect(capQualityFor('128k', '128k'), '128k');
      expect(capQualityFor('128k', '320k'), '128k');
      expect(capQualityFor('192k', '320k'), '192k');
      expect(capQualityFor('320k', '320k'), '320k');
    });

    test('非标准偏好 → 直接按上限', () {
      expect(capQualityFor('dolby', '128k'), '128k');
      expect(capQualityFor('', '192k'), '192k');
    });

    test('上限不在音质表内 → 不限制', () {
      expect(capQualityFor('flac', 'unknown'), 'flac');
    });

    test('压上限后仍由 pickQualityFor 回退到曲目可用音质', () {
      final capped = capQualityFor('flac', '128k');
      expect(capped, '128k');
      // 仅有 320k/128k：取 128k。
      expect(pickQualityFor(const ['320k', '128k'], capped), '128k');
      // 仅有更高音质：无法更省，回退到可用无损。
      expect(pickQualityFor(const ['flac'], capped), 'flac');
    });
  });
}
