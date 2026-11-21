/// 发现端点「直接 cached」棘轮：迁移到 `runDiscoverCall` 前的只减不增上限。
///
/// 扫描 `lib/sources/builtin/` 下全部 Dart 文件（递归），排除传输实现与
/// 发现执行器自身；任何未登记的（含新增）文件出现 `.cached(` 都算违规。
/// 这 22 处是 stage 1 遗留（spec §5 的完整迁移放到 stage 2）：它们保留
/// 各自的缓存 key / 无效判定 / parser，但确实绕过了 `runDiscoverCall`。
/// 新增发现端点必须走 `runDiscoverCall`；迁移一处就把对应数字下调。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 允许直接调用 `.cached(...)` 的文件与上限（相对仓库根目录）。
const whitelist = <String, int>{
  'lib/sources/builtin/kg_discover.dart': 4,
  'lib/sources/builtin/kw_discover.dart': 4,
  'lib/sources/builtin/mg_discover.dart': 4,
  'lib/sources/builtin/tx_discover.dart': 5,
  'lib/sources/builtin/wy_hot_search.dart': 1,
  'lib/sources/builtin/wy_leaderboard.dart': 1,
  'lib/sources/builtin/wy_songlist.dart': 3,
};

/// 传输实现与发现执行器本身：`cached` 的定义 / 调度不参与端点扫描。
const excludedFiles = <String>{
  'builtin_transport.dart',
  'discover_runner.dart',
};

/// 统计源码里直接 `.cached(` 调用的次数（任意接收者，含 `http.` / `client.`）。
///
/// 只做词法计数，避免新增文件通过换接收者名绕过棘轮；注释里的示例也可能
/// 被计入，这正是「只减不增」门槛想要的保守方向。
int directCacheCallsIn(String source) =>
    RegExp(r'\.cached\(').allMatches(source).length;

void main() {
  test('内置目录全部文件：未登记文件 0 次，登记文件不超上限，总量 ≤ 22', () {
    final directory = Directory('lib/sources/builtin');
    expect(directory.existsSync(), isTrue);

    final files = directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.replaceAll('\\', '/').endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);

    var total = 0;
    for (final file in files) {
      final relativePath = file.path.replaceAll('\\', '/');
      final basename = relativePath.split('/').last;
      if (excludedFiles.contains(basename)) continue;

      final count = directCacheCallsIn(file.readAsStringSync());
      final allowed = whitelist[relativePath] ?? 0;
      total += count;
      expect(
        count,
        lessThanOrEqualTo(allowed),
        reason:
            '$relativePath 出现 $count 处直接 .cached(...)（上限 $allowed）；'
            '发现端点请改用 DiscoverRequestCall / DiscoverAttemptCall',
      );
    }

    // 白名单不能指向已删除 / 改名的文件，否则新文件会从扫描里漏掉。
    for (final path in whitelist.keys) {
      expect(File(path).existsSync(), isTrue, reason: '白名单文件不存在: $path');
    }

    expect(
      total,
      lessThanOrEqualTo(22),
      reason: 'stage 2 迁移前总量不得高于 22（当前应随迁移下降）',
    );
  });

  test('扫描器：合成源码中的 .cached( 被识别，干净源码不误报', () {
    expect(directCacheCallsIn("http.cached('k', () => fetch())"), 1);
    expect(directCacheCallsIn("client.cached('k', create)"), 1);
    expect(
      directCacheCallsIn("a.cached('x', f); b.cached('y', g);"),
      2,
      reason: '任意接收者都要计入',
    );
    expect(
      directCacheCallsIn('runDiscoverCall(DiscoverRequestCall(key: k), t)'),
      0,
    );
  });
}
