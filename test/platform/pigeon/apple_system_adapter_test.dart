import 'package:flutter_test/flutter_test.dart';
import 'package:molia/platform/pigeon/apple_system.g.dart';
import 'package:molia/platform/pigeon/apple_system_adapter.dart';

/// Apple Pigeon 适配器契约：字体枚举与失败降级（ADR-0038 阶段 3）。
void main() {
  test('字体族原样返回，失败 / 非 Apple 平台回退空列表', () async {
    final adapter = AppleSystemAdapter(
      supported: true,
      host: _FakeHost(families: const ['PingFang SC', 'Helvetica']),
    );
    expect(await adapter.listFontFamilies(), ['PingFang SC', 'Helvetica']);

    final failing = AppleSystemAdapter(
      supported: true,
      host: _FakeHost(error: StateError('boom')),
    );
    expect(await failing.listFontFamilies(), isEmpty);

    final unsupported = AppleSystemAdapter(
      supported: false,
      host: _FakeHost(families: const ['ignored']),
    );
    expect(await unsupported.listFontFamilies(), isEmpty);
    expect(await unsupported.readBatterySnapshot(), isNull);
  });
}

class _FakeHost extends AppleSystemHost {
  _FakeHost({this.families = const [], this.error});

  final List<String> families;
  final Object? error;

  @override
  Future<List<String>> listFontFamilies() async {
    final error = this.error;
    if (error != null) throw error;
    return families;
  }
}
