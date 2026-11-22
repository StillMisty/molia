/// 资料库读侧纯策略：历史顺序 / 收藏计数的表驱动单测。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/library_read_model.dart';
import 'package:molia/domain/models/library.dart';

void main() {
  PlayHistoryEntry entry(String songId, {int playedAt = 0}) => PlayHistoryEntry(
    sourceKey: 'wy',
    songId: songId,
    title: 'Song $songId',
    playedAt: playedAt,
  );

  List<String> ids(List<PlayHistoryEntry> entries) => [
    for (final item in entries) item.songId,
  ];

  group('LibraryHistoryOrder.keyOf', () {
    test('与仓库唯一键一致', () {
      expect(LibraryHistoryOrder.keyOf(entry('1')), 'wy:1');
    });
  });

  group('LibraryHistoryOrder.merge（整表重载稳定合并）', () {
    final cases =
        <
          ({
            String name,
            List<String> current,
            List<String> fresh,
            List<String> expected,
          })
        >[
          (
            name: '空缓存：直接采用仓库顺序',
            current: [],
            fresh: ['3', '2', '1'],
            expected: ['3', '2', '1'],
          ),
          (
            name: '已有条目保持当前相对顺序，内容取最新',
            current: ['1', '2', '3'],
            fresh: ['3', '2', '1'],
            expected: ['1', '2', '3'],
          ),
          (
            name: '全新条目按新到旧插到最前',
            current: ['2', '1'],
            fresh: ['5', '4', '2', '1'],
            expected: ['5', '4', '2', '1'],
          ),
          (
            name: '当前有、仓库已没有的条目被丢弃',
            current: ['3', '2', '1'],
            fresh: ['2', '1'],
            expected: ['2', '1'],
          ),
          (name: '空仓库：当前缓存全部失效', current: ['2', '1'], fresh: [], expected: []),
        ];

    for (final item in cases) {
      test(item.name, () {
        final current = [for (final id in item.current) entry(id)];
        final fresh = [for (final id in item.fresh) entry(id, playedAt: 100)];
        final merged = LibraryHistoryOrder.merge(
          current: current,
          fresh: fresh,
        );
        expect(ids(merged), item.expected);
        // 命中的条目必须是 fresh 的那一份（内容最新）。
        final freshById = {for (final row in fresh) row.songId: row};
        for (final row in merged) {
          expect(identical(row, freshById[row.songId]), isTrue);
        }
      });
    }

    test('全新条目内部保持 fresh 顺序（fresh 已是最近优先）', () {
      final merged = LibraryHistoryOrder.merge(
        current: [entry('9', playedAt: 1)],
        fresh: [entry('8', playedAt: 30), entry('9', playedAt: 1)],
      );
      expect(ids(merged), ['8', '9']);
    });
  });

  group('LibraryHistoryOrder.applyEntry（单条补丁）', () {
    final cases =
        <
          ({
            String name,
            List<String> current,
            String incoming,
            int limit,
            List<String> expected,
          })
        >[
          (
            name: '新条目插到最前',
            current: ['2', '1'],
            incoming: '3',
            limit: 500,
            expected: ['3', '2', '1'],
          ),
          (
            name: '已有条目原位替换（不置顶）',
            current: ['3', '2', '1'],
            incoming: '1',
            limit: 500,
            expected: ['3', '2', '1'],
          ),
          (
            name: '超出上限裁掉尾部',
            current: ['3', '2', '1'],
            incoming: '4',
            limit: 3,
            expected: ['4', '3', '2'],
          ),
          (
            name: '已有条目替换后仍按上限裁剪',
            current: ['3', '2', '1'],
            incoming: '2',
            limit: 2,
            expected: ['3', '2'],
          ),
        ];

    for (final item in cases) {
      test(item.name, () {
        final current = [for (final id in item.current) entry(id, playedAt: 1)];
        final incoming = entry(item.incoming, playedAt: 2);
        final next = LibraryHistoryOrder.applyEntry(
          current,
          incoming,
          limit: item.limit,
        );
        expect(ids(next), item.expected);
        if (item.expected.contains(item.incoming)) {
          expect(
            identical(
              next.firstWhere((row) => row.songId == item.incoming),
              incoming,
            ),
            isTrue,
            reason: '补丁必须使用写入事件携带的最新内容',
          );
        }
      });
    }
  });

  group('LibraryHistoryOrder.resortByRecency', () {
    test('按 playedAt 倒序', () {
      final sorted = LibraryHistoryOrder.resortByRecency([
        entry('1', playedAt: 10),
        entry('2', playedAt: 30),
        entry('3', playedAt: 20),
      ]);
      expect(ids(sorted), ['2', '3', '1']);
    });

    test('时间相同的条目保持当前下标顺序（不读 rowid）', () {
      final sorted = LibraryHistoryOrder.resortByRecency([
        entry('1', playedAt: 10),
        entry('2', playedAt: 20),
        entry('3', playedAt: 20),
        entry('4', playedAt: 10),
      ]);
      expect(ids(sorted), ['2', '3', '1', '4']);
    });

    test('已按最近播放排序时元素身份不变', () {
      final input = [entry('2', playedAt: 20), entry('1', playedAt: 10)];
      final sorted = LibraryHistoryOrder.resortByRecency(input);
      expect(identical(sorted[0], input[0]), isTrue);
      expect(identical(sorted[1], input[1]), isTrue);
    });
  });
}
