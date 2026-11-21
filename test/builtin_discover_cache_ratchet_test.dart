/// 发现端点「直接 cached」棘轮：迁移到 `runDiscoverCall` 前的只减不增上限。
///
/// 这 22 处是 stage 1 遗留（spec §5 的完整迁移放到 stage 2）：它们保留
/// 各自的缓存 key / 无效判定 / parser，但确实绕过了 `runDiscoverCall`。
/// 新增发现端点必须走 `runDiscoverCall`；迁移一处就把对应数字下调。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const whitelist = <String, int>{
    'lib/sources/builtin/kg_discover.dart': 4,
    'lib/sources/builtin/kw_discover.dart': 4,
    'lib/sources/builtin/mg_discover.dart': 4,
    'lib/sources/builtin/tx_discover.dart': 5,
    'lib/sources/builtin/wy_hot_search.dart': 1,
    'lib/sources/builtin/wy_leaderboard.dart': 1,
    'lib/sources/builtin/wy_songlist.dart': 3,
  };

  test('发现端点直接 http.cached 调用只减不增', () {
    final pattern = RegExp(r'http\.cached\(');
    var total = 0;
    for (final entry in whitelist.entries) {
      final file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: '${entry.key} 不存在');
      final count = pattern.allMatches(file.readAsStringSync()).length;
      total += count;
      expect(
        count,
        lessThanOrEqualTo(entry.value),
        reason:
            '${entry.key} 新增了绕过 runDiscoverCall 的发现端点；'
            '请改用 DiscoverRequestCall / DiscoverAttemptCall',
      );
    }
    expect(total, lessThanOrEqualTo(22), reason: 'stage 2 迁移前总量不得高于 22');
  });
}
