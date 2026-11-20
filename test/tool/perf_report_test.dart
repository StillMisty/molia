import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

  test('每个场景优先取 end 窗口', () {
    File('${directory.path}/frames.jsonl').writeAsStringSync(
      '{"scenario":"a","label":"mid","frames":10}\n'
      '{"scenario":"a","label":"end","frames":20}\n'
      '{"scenario":"b","label":"only","frames":5}\n',
    );

    final summary = renderFrameSummary(loadFrameRows(directory));
    final scenarioTable = summary.split('## 原始窗口').first;
    expect(scenarioTable, contains('| a | end | 20 |'));
    expect(scenarioTable, contains('| b | only | 5 |'));
    expect(scenarioTable, isNot(contains('| a | mid | 10 |')));
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
}
