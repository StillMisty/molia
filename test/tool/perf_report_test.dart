import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:molia/app/perf/frame_stats.dart';

import '../../tool/agent/src/perf_report.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('molia-perf-');
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  test('读 jsonl 与 logcat 里的 molia.frame 行', () {
    File('${directory.path}/frames.jsonl').writeAsStringSync(
      '{"scenario":"desktop-scroll","label":"end","frames":240}\n'
      '不是 JSON 的行\n',
    );
    File('${directory.path}/frames.log').writeAsStringSync(
      '11-15 10:00:00.000 I/flutter: molia.frame: {"scenario":"startup","label":"end","frames":7}\n'
      '11-15 10:00:01.000 I/flutter: molia.frame: molia.frame: {"scenario":"double","label":"end","frames":1}\n'
      '11-15 10:00:02.000 I/flutter: 无关日志\n',
    );

    final rows = loadFrameRows(directory);
    expect(rows, hasLength(3));
    expect(rows.map((row) => row['scenario']), [
      'desktop-scroll',
      'startup',
      'double',
    ]);
  });

  test('每个场景取样本最多的窗口，同样本数优先 end', () {
    File('${directory.path}/frames.jsonl').writeAsStringSync(
      '{"scenario":"a","label":"mid","frames":10}\n'
      '{"scenario":"a","label":"end","frames":20}\n'
      '{"scenario":"b","label":"only","frames":5}\n'
      '{"scenario":"long","frames":108}\n'
      '{"scenario":"long","label":"end","frames":14}\n',
    );

    final summary = renderFrameSummary(loadFrameRows(directory));
    final scenarioTable = summary.split('## 原始窗口').first;
    expect(scenarioTable, contains('| a | end | 20 |'));
    expect(scenarioTable, contains('| b | only | 5 |'));
    expect(scenarioTable, isNot(contains('| a | mid | 10 |')));
    expect(
      scenarioTable,
      contains('| long |  | 108 |'),
      reason: '长场景被 5s 周期切成两段时，不能拿很短的 end 尾窗代表场景',
    );
  });

  test('没有样本时给出明确结论', () {
    expect(renderFrameSummary(const []), contains('没有采到 `molia.frame` 样本'));
  });

  test('120Hz 口径 jank8 进入汇总列', () {
    expect(frameColumns, contains('jank8'));
    expect(
      renderFrameSummary(const [
        {'scenario': 'a', 'label': 'end', 'jank8': 3},
      ]),
      contains('| 3 |'),
    );
  });

  test('jank8 按 120Hz 帧预算（8.33ms）判定 work', () {
    final window = FrameWindow()
      ..add(buildMs: 6, rasterMs: 3, vsyncMs: 0, totalMs: 9) // work=9 → jank8
      ..add(buildMs: 4, rasterMs: 3, vsyncMs: 0, totalMs: 7); // work=7 → 不 jank

    final stats = window.take()!;
    expect(stats['jank8'], 1);
    expect(stats['jank16'], 0);
    expect(stats['jank33'], 0);
  });

  test('take() 输出 jank8 并清零', () {
    final window = FrameWindow()
      ..add(buildMs: 5, rasterMs: 5, vsyncMs: 0, totalMs: 10);

    expect(window.take()!['jank8'], 1);
    expect(window.take(), isNull);

    window.add(buildMs: 1, rasterMs: 1, vsyncMs: 0, totalMs: 2);
    expect(window.take()!['jank8'], 0);
  });
}
