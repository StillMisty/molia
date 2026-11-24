import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 状态层守卫（ADR-0041）：`lib/**` 不再有 `ChangeNotifier` 状态类。
///
/// 状态对象统一是「不可变快照 + 变更信号」：
/// - 由 Riverpod 持有的状态写 `Notifier<State>`；
/// - 启动期 / 页面内部对象实现 `SnapshotSource<State>`（`state` + `changes`，
///   契约在 `lib/utils/snapshot_source.dart`），经 `SnapshotNotifier` 镜像给 UI
///   或由宿主用 `ListenableBuilder(listenable: obj.changes)` 消费。
///
/// 高频通道（播放进度、下载进度、生成进度、歌词逐行、过渡动画）继续用
/// `ValueListenable` / 原生回调，不在这条守卫的范围内。
///
/// 白名单只减不增：这里是迁移收尾阶段的存量清单，清空后不得再新增条目。
const Set<String> _remainingChangeNotifiers = <String>{
  // 收尾批次：本地播放服务正在快照化，完成后必须清空本清单。
  'lib/playback/local_playback_service.dart',
};

void main() {
  final files = _libFiles();

  test('扫描到 lib/** 的 Dart 文件', () {
    expect(files, isNotEmpty);
    expect(files, contains('lib/main.dart'));
  });

  test('lib/** 不再声明 ChangeNotifier 状态类（白名单只减不增）', () {
    final offenders = <String>[];
    final stillMigrating = <String>{};
    for (final path in files) {
      final source = File(path).readAsStringSync();
      if (!_declaresChangeNotifier(source)) continue;
      stillMigrating.add(path);
      if (!_remainingChangeNotifiers.contains(path)) {
        offenders.add(path);
      }
    }
    final stale = _remainingChangeNotifiers.difference(stillMigrating).toList()
      ..sort();

    expect(
      offenders,
      isEmpty,
      reason:
          '新增了 ChangeNotifier 状态类。状态请写成 Notifier<State>，'
          '启动期 / 页面内部对象请实现 SnapshotSource<State> + SnapshotSignal '
          '（契约见 lib/utils/snapshot_source.dart，ADR-0041）：\n'
          '${offenders.join('\n')}',
    );
    expect(
      stale,
      isEmpty,
      reason: '白名单条目已不再声明 ChangeNotifier，请删除：\n${stale.join('\n')}',
    );
  });
}

/// 匹配 `class X extends ChangeNotifier` / `class X extends Y with ChangeNotifier`
/// （允许类头换行；注释里的提及不计）。
bool _declaresChangeNotifier(String source) {
  final withoutComments = source
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');
  return RegExp(
    r'\bclass\s+\w+[^;{]*?\b(?:extends|with)\b[^;{]*?\bChangeNotifier\b',
  ).hasMatch(withoutComments);
}

List<String> _libFiles() {
  final dir = Directory('lib');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => file.path.replaceAll('\\', '/'))
      .where((path) => path.endsWith('.dart'))
      .toList()
    ..sort();
}
