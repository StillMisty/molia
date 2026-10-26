import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/source.dart';
import 'package:molia/utils/source_label.dart';

SourceDescriptor _entry(String key, String name) => SourceDescriptor(
      key: key,
      displayName: name,
      kind: SourceKind.builtin,
      capabilities: const SourceCapabilities(search: true),
    );

void main() {
  test('命中渠道：展示「名称 (key)」', () {
    expect(
      sourceChannelLabel([_entry('kw', '酷我音乐')], 'kw'),
      '酷我音乐 (kw)',
    );
  });

  test('停用渠道也在列表里（含停用项语义）：仍显示可读名称', () {
    expect(
      sourceChannelLabel([_entry('kg', '酷狗音乐')], 'kg'),
      '酷狗音乐 (kg)',
    );
  });

  test('查不到 / 空 key / 空列表：回退原始 key', () {
    expect(sourceChannelLabel(const [], 'kw'), 'kw');
    expect(sourceChannelLabel([_entry('kg', '酷狗音乐')], 'kw'), 'kw');
    expect(sourceChannelLabel(const [], ''), '');
  });
}
