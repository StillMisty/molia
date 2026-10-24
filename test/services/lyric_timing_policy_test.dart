import 'package:flutter_test/flutter_test.dart';
import 'package:molia/models/lyric_line.dart';
import 'package:molia/services/lyrics_display/lyric_timing_policy.dart';
import 'package:molia/services/lyrics_display/lyrics_display_settings.dart';

/// 歌词时间策略：页内 200ms 提前量、输出偏移、扩展行与未同步策略只此一份。
void main() {
  const lines = [
    LyricLine(Duration(seconds: 60), 'sixty'),
    LyricLine(Duration(seconds: 65), 'sixty-five'),
  ];

  group('页内策略', () {
    test('200ms 提前量：64.799s 仍是上一行，64.800s 切到下一行', () {
      const policy = LyricTimingPolicy.page;
      expect(
        policy.lineIndexAt(
          lines,
          const Duration(milliseconds: 64799),
          isSynced: true,
        ),
        0,
      );
      expect(
        policy.lineIndexAt(
          lines,
          const Duration(milliseconds: 64800),
          isSynced: true,
        ),
        1,
      );
    });

    test('提前量与逐字插值共用同一常量', () {
      expect(kLyricDisplayLead, const Duration(milliseconds: 200));
      expect(LyricTimingPolicy.page.lead, kLyricDisplayLead);
      expect(
        LyricTimingPolicy.page.effectivePosition(const Duration(seconds: 60)),
        const Duration(seconds: 60) + kLyricDisplayLead,
      );
    });

    test('未同步歌词不点亮任何行（页内不显示歌名）', () {
      expect(
        LyricTimingPolicy.page.lineIndexAt(
          lines,
          const Duration(seconds: 120),
          isSynced: false,
        ),
        -1,
      );
    });
  });

  group('输出侧策略', () {
    test('只应用用户偏移，不叠加页内提前量', () {
      const output = LyricTimingPolicy.output(
        offsetMs: 0,
        unsyncedBehavior: UnsyncedBehavior.title,
      );
      // 64.9s：页内策略已提前到下一行，输出侧仍停在上一行。
      expect(
        output.lineIndexAt(
          lines,
          const Duration(milliseconds: 64900),
          isSynced: true,
        ),
        0,
      );
      expect(
        LyricTimingPolicy.page.lineIndexAt(
          lines,
          const Duration(milliseconds: 64900),
          isSynced: true,
        ),
        1,
      );
    });

    test('正值偏移让歌词提前显示', () {
      const output = LyricTimingPolicy.output(
        offsetMs: 1000,
        unsyncedBehavior: UnsyncedBehavior.title,
      );
      expect(
        output.lineIndexAt(
          lines,
          const Duration(milliseconds: 64100),
          isSynced: true,
        ),
        1,
      );
    });

    test('未同步策略：歌名 / 隐藏无当前行，首行取第 0 行', () {
      int indexOf(UnsyncedBehavior behavior) => LyricTimingPolicy.output(
            offsetMs: 0,
            unsyncedBehavior: behavior,
          ).lineIndexAt(
            lines,
            const Duration(seconds: 1),
            isSynced: false,
          );

      expect(indexOf(UnsyncedBehavior.title), -1);
      expect(indexOf(UnsyncedBehavior.hide), -1);
      expect(indexOf(UnsyncedBehavior.firstLine), 0);
    });
  });

  test('扩展行：翻译在前、罗马音在后，空文本不占位', () {
    const policy = LyricTimingPolicy.page;
    const translations = ['', '译'];
    const romas = ['roma', ''];
    expect(
      policy.extendedLinesAt(
        0,
        translations,
        romas,
        translationEnabled: true,
        romaEnabled: true,
      ),
      ['roma'],
    );
    expect(
      policy.extendedLinesAt(
        1,
        translations,
        romas,
        translationEnabled: true,
        romaEnabled: true,
      ),
      ['译'],
    );
    expect(
      policy.extendedLinesAt(
        1,
        translations,
        romas,
        translationEnabled: false,
        romaEnabled: false,
      ),
      isEmpty,
    );
  });

  test('空歌词没有当前行', () {
    expect(
      LyricTimingPolicy.page.lineIndexAt(
        const [],
        const Duration(seconds: 1),
        isSynced: true,
      ),
      -1,
    );
  });
}
