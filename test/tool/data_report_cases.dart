import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/agent/src/data_report.dart';

void main() {
  test('quantile 与旧 Python 实现同口径（保留小数）', () {
    expect(quantile([80.25, 120.5], 50), 80.25);
    expect(quantile([80.25, 120.5], 95), 120.5);
    expect(quantile([5], 0), 5);
    expect(quantile([1, 2, 3, 4], 100), 4);
  });

  test('resetPerfWindowBounds 固定 1440×900 且保留其它键', () {
    final dir = Directory.systemTemp.createTempSync('molia-prefs-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final prefs = File('${dir.path}/shared_preferences.json')
      ..writeAsStringSync('{"flutter.window_bounds_width":3492,"other":1}');

    resetPerfWindowBounds(prefs.path);

    final data = jsonDecode(prefs.readAsStringSync()) as Map<String, Object?>;
    expect(data['flutter.window_bounds_width'], 1440.0);
    expect(data['flutter.window_bounds_height'], 900.0);
    expect(data['other'], 1);
  });

  test('resetPerfWindowBounds 对缺失 / 坏文件静默跳过', () {
    final dir = Directory.systemTemp.createTempSync('molia-prefs-');
    addTearDown(() => dir.deleteSync(recursive: true));
    resetPerfWindowBounds('${dir.path}/nope.json');

    final broken = File('${dir.path}/broken.json')
      ..writeAsStringSync('not json');
    resetPerfWindowBounds(broken.path);
    expect(broken.readAsStringSync(), 'not json');
  });

  test('renderDataReport 解析 molia.perf 行并分场景 / 分项汇总', () {
    final dir = Directory.systemTemp.createTempSync('molia-data-');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/data.log').writeAsStringSync('''
I/flutter: molia.perf: {"op":"scenario.start","ms":0}
I/flutter: molia.perf: {"op":"search.submit","ms":120.5}
I/flutter: molia.perf: {"op":"search.submit","ms":80.25}
I/flutter: molia.perf: {"op":"scenario.done","ms":523,"scenario":"data"}
''');

    final report = renderDataReport(dir);
    expect(report.hasSamples, isTrue);
    expect(report.sampleCount, 4);
    expect(
      report.markdown,
      contains('| scenario.done | 523 | {"scenario":"data"} |'),
    );
    expect(
      report.markdown,
      contains('| search.submit | 2 | 80.25 | 120.50 | 120.50 |'),
    );
  });

  test('没有样本时给出明确结论', () {
    final dir = Directory.systemTemp.createTempSync('molia-data-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final report = renderDataReport(dir);
    expect(report.hasSamples, isFalse);
    expect(report.markdown, contains('没有采到 `molia.perf` 样本'));
  });
}
