import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// docs/architecture.md §2.1 分层硬规则：扫描 `lib/**` 的 import/export，
/// 防止回退（新增违规必须修复或评审后加入白名单）。
///
/// 规则：
/// - R1 `lib/domain/**` 禁止 Flutter/provider 与 providers/data/sources/playback/main/UI；
/// - R2 `lib/data/**`、`lib/sources/**`、`lib/playback/**` 禁止 providers/pages/widgets/main；
/// - R3 `lib/providers/**` 禁止 import `lib/main.dart`；
/// - R4 `lib/main.dart` 是唯一 composition root：不被任何其他 lib 文件 import；
/// - R5 `lib/widgets/**`、`lib/pages/**` 禁止 import sources/playback。
///
/// 白名单（阶段迁移豁免，只减不增）：Wave 7 已清空——违规必须修复，
/// 不再接受新豁免；机制与「陈旧条目失败」检查保留，防止条目复活掩盖违规。
const Map<String, Set<String>> _whitelist = {};

const List<String> _domainForbidden = [
  'package:flutter/',
  'package:provider/',
  'lib/providers/',
  'lib/data/',
  'lib/sources/',
  'lib/playback/',
  'lib/main.dart',
  'lib/pages/',
  'lib/widgets/',
];

const List<String> _dataForbidden = [
  'lib/providers/',
  'lib/pages/',
  'lib/widgets/',
  'lib/main.dart',
];

void main() {
  final files = _libFiles();

  test('扫描到 lib/** 的 Dart 文件', () {
    expect(files, isNotEmpty);
    expect(files, contains('lib/main.dart'));
  });

  test('§2.1 分层规则：无未豁免违规', () {
    final violations = <String>[];
    for (final path in files) {
      for (final ref in _importsOf(path)) {
        if (_isWhitelisted(path, ref)) continue;
        final rule = _violatedRule(path, ref);
        if (rule != null) {
          violations.add('[$rule] $path -> $ref');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '分层违规（修复，或评审后加入 _whitelist）：\n${violations.join('\n')}',
    );
  });

  test('main.dart 是唯一 composition root（不被其他 lib 文件 import）', () {
    final offenders = <String>[];
    for (final path in files) {
      if (path == 'lib/main.dart') continue;
      for (final ref in _importsOf(path)) {
        if (_resolve(path, ref) == 'lib/main.dart') {
          offenders.add('$path -> $ref');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('domain 层保持纯 Dart（R1）', () {
    final offenders = <String>[];
    for (final path in files.where((path) => path.startsWith('lib/domain/'))) {
      for (final ref in _importsOf(path)) {
        if (_violatedRule(path, ref) == 'R1(domain)') {
          offenders.add('$path -> $ref');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('白名单只包含确有其事的豁免（防止陈旧条目掩盖新违规）', () {
    final stale = <String>[];
    _whitelist.forEach((path, refs) {
      if (!files.contains(path)) {
        stale.add('$path（文件不存在）');
        return;
      }
      final imports = _importsOf(path).toSet();
      for (final ref in refs) {
        if (!imports.contains(ref)) stale.add('$path -> $ref');
      }
    });
    expect(stale, isEmpty, reason: '白名单条目已失效，请同步删除：\n${stale.join('\n')}');
  });
}

// ---------------------------------------------------------------------------
// 扫描实现
// ---------------------------------------------------------------------------

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

final RegExp _importPattern =
    RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''', multiLine: true);

List<String> _importsOf(String path) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  return _importPattern
      .allMatches(file.readAsStringSync())
      .map((match) => match.group(1)!)
      .toList();
}

bool _isWhitelisted(String path, String ref) =>
    _whitelist[path]?.contains(ref) ?? false;

String? _violatedRule(String path, String ref) {
  final target = _resolve(path, ref);

  if (path.startsWith('lib/domain/') &&
      _matchesAny(ref, target, _domainForbidden)) {
    return 'R1(domain)';
  }
  if ((path.startsWith('lib/data/') ||
          path.startsWith('lib/sources/') ||
          path.startsWith('lib/playback/')) &&
      _matchesAny(ref, target, _dataForbidden)) {
    return 'R2(data/sources/playback)';
  }
  if (path.startsWith('lib/providers/') && target == 'lib/main.dart') {
    return 'R3(providers→main)';
  }
  if (path != 'lib/main.dart' && target == 'lib/main.dart') {
    return 'R4(import main.dart)';
  }
  if ((path.startsWith('lib/widgets/') || path.startsWith('lib/pages/')) &&
      (target.startsWith('lib/sources/') ||
          target.startsWith('lib/playback/'))) {
    return 'R5(ui→sources/playback)';
  }
  return null;
}

bool _matchesAny(String ref, String target, List<String> prefixes) {
  for (final prefix in prefixes) {
    if (ref.startsWith(prefix) || target.startsWith(prefix)) return true;
  }
  return false;
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
