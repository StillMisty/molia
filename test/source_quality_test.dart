import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/source_script.dart' show qualityDisplayName;
import 'package:molia/domain/models/track.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/sources/source_track.dart'
    show capQualityFor, pickQualityFor;
import 'package:molia/utils/source_quality_label.dart';
import 'package:material_ui/material_ui.dart';

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

  group('可用音质展示', () {
    test('按高到低排序并去重，未知档位排在末尾', () {
      final sorted = sortedQualityOptions(const [
        AudioQuality(type: '320k'),
        AudioQuality(type: 'flac'),
        AudioQuality(type: '64k'),
        AudioQuality(type: '320k', size: '重复条目'),
        AudioQuality(type: '128k'),
      ]);

      expect(sorted.map((quality) => quality.type), [
        'flac',
        '320k',
        '128k',
        '64k',
      ]);
      expect(sorted[1].size, isNull, reason: '重复 type 保留首次出现的条目');
    });

    test('体积统一单位写法与尾零', () {
      expect(formatQualitySize('9.80 MiB'), '9.8 MB');
      expect(formatQualitySize('9.17Mb'), '9.17 MB');
      expect(formatQualitySize('743.35Kb'), '743.35 KB');
      expect(formatQualitySize('2.00GB'), '2 GB');
      expect(formatQualitySize('9.8 MB'), '9.8 MB');
      expect(formatQualitySize('zpMb'), isNull);
      expect(formatQualitySize('0 B'), isNull);
      expect(formatQualitySize(null), isNull);
    });

    test('64K 本地化与通用显示名', () {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      expect(sourceQualityLabel(l10n, '64k'), '64K');
      expect(qualityDisplayName('64k'), '64K');
    });
  });
}
