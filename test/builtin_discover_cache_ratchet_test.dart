/// 发现端点「直接 cached」守卫：迁移完成后固定为 0。
///
/// 扫描 `lib/sources/builtin/` 下全部 Dart 文件（递归），排除传输实现与
/// 发现执行器自身；任何（含新增）文件出现 `.cached(` 都算违规。发现端点
/// 必须走 `discover_runner.dart` 的 `runDiscoverCall`：缓存键 / 重试预算 /
/// 无效判定集中在 `DiscoverCall` 描述符里，平台文件只留 URL / 参数与 parser。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 传输实现与发现执行器本身：`cached` 的定义 / 调度不参与端点扫描。
const excludedFiles = <String>{
  'builtin_transport.dart',
  'discover_runner.dart',
};

/// 统计源码里直接 `.cached(` 调用的次数（任意接收者，含 `http.` / `client.`）。
///
/// 只做词法计数，避免新增文件通过换接收者名绕过守卫；注释里的示例也会被
/// 计入，这正是「不得绕过执行器」想要的保守方向。
int directCacheCallsIn(String source) =>
    RegExp(r'\.cached\(').allMatches(source).length;

void main() {
  test('内置目录全部文件：发现端点 0 处直接 .cached(...)', () {
    final directory = Directory('lib/sources/builtin');
    expect(directory.existsSync(), isTrue);

    final files = directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.replaceAll('\\', '/').endsWith('.dart'))
        .toList();
    expect(files, isNotEmpty);

    for (final file in files) {
      final relativePath = file.path.replaceAll('\\', '/');
      final basename = relativePath.split('/').last;
      if (excludedFiles.contains(basename)) continue;

      final count = directCacheCallsIn(file.readAsStringSync());
      expect(
        count,
        0,
        reason:
            '$relativePath 出现 $count 处直接 .cached(...)；'
            '发现端点请改用 DiscoverRequestCall / DiscoverAttemptCall',
      );
    }
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
