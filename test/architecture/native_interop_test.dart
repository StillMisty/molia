import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ADR-0038 原生互操作边界：
/// - 生成绑定与薄适配器只能在 `lib/platform/**`；
/// - 业务层（domain / providers / pages / widgets / app）不得直接 import JNI /
///   FFI / Win32 / POSIX / objective_c 绑定包，也不得直接 import
///   `lib/platform/**`；
/// - 平台层是薄适配器，不得反向依赖 domain / data / services 等业务层；
/// - Apple 走 Swift + Pigeon；`package:objective_c/` 只允许作为上游插件的
///   传递依赖，我们的代码不得直接 import 或使用；
/// - 阶段 0 的现存手写 FFI 登记为只减不增的白名单，阶段 1–2 迁入平台层后
///   逐条删除；新增违规即使不在白名单也必须失败。
const List<String> _nativeImports = [
  'dart:ffi',
  'package:jni/',
  'package:jni_flutter/',
  'package:win32/',
  'package:posix/',
  'package:objective_c/',
];

const String _platformPrefix = 'lib/platform/';

const List<String> _businessLayers = [
  'lib/domain/',
  'lib/providers/',
  'lib/pages/',
  'lib/widgets/',
  'lib/app/',
];

/// 平台层不能反向依赖的业务层前缀（`lib/main.dart` 单独判断）。
const List<String> _businessDependencyPrefixes = [
  'lib/domain/',
  'lib/data/',
  'lib/sources/',
  'lib/playback/',
  'lib/services/',
  'lib/providers/',
  'lib/pages/',
  'lib/widgets/',
  'lib/app/',
];

/// 阶段 0 临时白名单：文件 → 仍然存在的原生 import。
///
/// 只减不增：条目必须对应当前真实的 import；文件迁入 `lib/platform/**` 或
/// 改用端口后，测试会因「陈旧条目」失败并要求删除。
const Map<String, Set<String>> _legacyWhitelist = {
  'lib/services/diagnostics/app_info.dart': {'dart:ffi'},
  'lib/services/memory/app_memory_manager.dart': {'dart:ffi'},
  'lib/services/update/update_installer_io.dart': {'dart:ffi'},
  'lib/services/window/foreground_activation.dart': {'dart:ffi'},
  'lib/services/window/process_liveness.dart': {'dart:ffi'},
};

void main() {
  final files = _libFiles();

  test('原生互操作层目录存在（lib/platform/）', () {
    expect(
      Directory('lib/platform').existsSync(),
      isTrue,
      reason: 'ADR-0038 规定所有生成绑定与薄适配器只放在 lib/platform/。',
    );
  });

  test('业务层（domain / providers / pages / widgets / app）不直接依赖原生互操作', () {
    final offenders = <String>[];
    for (final path in files.where(_isBusinessLayer)) {
      for (final ref in _importsOf(path)) {
        if (_isNativeImport(ref)) {
          offenders.add('$path -> $ref');
          continue;
        }
        if (_resolve(path, ref).startsWith(_platformPrefix)) {
          offenders.add('$path -> $ref（业务层应走端口，不直连平台层）');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '业务层直接拿原生绑定会绕过端口与现有降级语义（ADR-0038）：\n'
          '${offenders.join('\n')}',
    );
  });

  test('lib/platform/** 不反向依赖业务层（薄适配器只做投影）', () {
    final offenders = <String>[];
    for (final path in files.where(
      (path) => path.startsWith(_platformPrefix),
    )) {
      for (final ref in _importsOf(path)) {
        final target = _resolve(path, ref);
        if (target == 'lib/main.dart' ||
            _businessDependencyPrefixes.any(target.startsWith)) {
          offenders.add('$path -> $ref');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '平台层反向依赖业务层会形成环，也会把端口 / 降级规则搬进绑定层'
          '（ADR-0038）；请改为由业务层注入最小参数：\n'
          '${offenders.join('\n')}',
    );
  });

  test('原生互操作 import 只出现在 lib/platform/（阶段 0 白名单只减不增）', () {
    final offenders = <String>[];
    for (final path in files) {
      if (path.startsWith(_platformPrefix)) continue;
      for (final ref in _importsOf(path)) {
        if (!_isNativeImport(ref)) continue;
        if (_legacyWhitelist[path]?.contains(ref) ?? false) continue;
        offenders.add('$path -> $ref');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          '生成绑定 / 手写 FFI 只能放在 lib/platform/（ADR-0038）；'
          '阶段 1 桌面迁移 3 条、阶段 2 ABI 迁移 2 条后白名单清空：\n'
          '${offenders.join('\n')}',
    );
  });

  test('原生互操作白名单只包含仍然存在的问题', () {
    final stale = <String>[];
    _legacyWhitelist.forEach((path, refs) {
      if (!files.contains(path)) {
        stale.add('$path（文件不存在）');
        return;
      }
      final imports = _importsOf(path).toSet();
      for (final ref in refs) {
        if (!imports.contains(ref)) stale.add('$path -> $ref');
      }
    });
    expect(
      stale,
      isEmpty,
      reason:
          '白名单条目已失效（多半已迁入 lib/platform/），请删除：\n'
          '${stale.join('\n')}',
    );
  });
}

bool _isBusinessLayer(String path) =>
    _businessLayers.any((prefix) => path.startsWith(prefix));

bool _isNativeImport(String ref) =>
    _nativeImports.any((prefix) => ref == prefix || ref.startsWith(prefix));

List<String> _libFiles() {
  final dir = Directory('lib');
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => _normalize(file.path))
      .where((path) => path.endsWith('.dart'))
      .toList()
    ..sort();
}

final RegExp _importPattern = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

List<String> _importsOf(String path) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  return _importPattern
      .allMatches(file.readAsStringSync())
      .map((match) => match.group(1)!)
      .toList();
}

/// 相对 import / `package:molia` 统一解析为 `lib/...` 路径；
/// 其余 `dart:` / `package:` 原样返回。
String _resolve(String sourcePath, String ref) {
  const packagePrefix = 'package:molia/';
  if (ref.startsWith('dart:') || ref.startsWith('package:')) {
    if (ref.startsWith(packagePrefix)) {
      return _normalize('lib/${ref.substring(packagePrefix.length)}');
    }
    return ref;
  }
  final slash = sourcePath.lastIndexOf('/');
  final dir = slash < 0 ? '' : sourcePath.substring(0, slash);
  return _normalize('$dir/$ref');
}

String _normalize(String path) {
  final parts = path.replaceAll('\\', '/').split('/');
  final out = <String>[];
  for (final part in parts) {
    if (part == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else if (part != '.' && part.isNotEmpty) {
      out.add(part);
    }
  }
  return out.join('/');
}
