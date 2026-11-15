/// 文档引用与工具链一致性检查（`cli.dart docs check` 的 Dart 版，跨端）。
///
/// 两组检查，默认都跑：
///
/// 1. 文档引用：反引号里的仓库路径、Markdown 链接、`§数字` 章节号、孤儿文档、
///    ADR 编号。ADR 是历史决策记录，允许引用当时存在、后来改名/删除的路径。
/// 2. 工具链：`AGENTS.md`「工具链」与 pubspec / Gradle / Android / CI 工作流
///    逐项比对；其它文档与 `molia-*` 技能不得复列当前版本号。
library;

import 'dart:io';

/// 扫描范围：仓库入口文档 + docs/ + 本仓 molia-* 技能。
/// 第三方技能（dart-* / flutter-*）由 skills-lock.json 管理，不在此检查。
const List<String> _rootDocs = ['AGENTS.md', 'README.md', 'GLOSSARY.md'];

const List<String> _pathPrefixes = [
  'lib/',
  'test/',
  'integration_test/',
  'tool/',
  'docs/',
  'android/',
  'ios/',
  'macos/',
  'windows/',
  'linux/',
  'assets/',
  '.github/',
  '.agents/',
];

/// 文中明确提到、但并不存在于本仓的路径（第三方包内路径 / 假设路径 / 反例）。
const Map<String, String> _pathAllowlist = {
  'android/consumer-rules.pro': '第三方包内的文件（文中是复评记录）',
  'android/iOS/macOS': '文字列举，不是路径',
  'assets/fonts/': '文中举例的未来字体目录',
  'ios/Podfile': '文中说明仓库里没有 Podfile',
  'macos/Podfile': '文中说明仓库里没有 Podfile',
  'android/key.properties': '本机签名配置，不入库',
  'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java':
      'Flutter 生成的插件注册文件，不入库',
  'linux/flutter/ephemeral/': 'Flutter 生成的临时目录，不入库（结尾 / 表示整个目录）',
  'lib/arm64-v8a/libmpv.so': 'APK 内路径，不是仓库路径',
  'lib/just_audio_media_kit.dart': '文中假设的 dependency_overrides 文件',
  'lib/media_kit_libs_audio.dart': '文中假设的 dependency_overrides 文件',
  'lib/src/player/native/core/native_library.dart': 'media_kit 上游包内路径',
  'linux/include/quickjs_engine/quickjs_engine_plugin.h': 'quickjs 插件包内路径',
};

/// 带日期的测量快照允许保留当时版本号。
const Map<String, String> _versionAllowlist = {
  'docs/performance-audit.md': '历史体检归档，记录当时环境',
  'docs/media_kit_native_libs.md': '测量快照，记录当时环境',
};

class DocsCheckResult {
  DocsCheckResult(this.errors);

  final List<String> errors;

  bool get ok => errors.isEmpty;
}

/// 跑检查；[docs] / [toolchain] 传 false 表示只跑另一组。
DocsCheckResult runDocsCheck(
  String repoRoot, {
  bool docs = true,
  bool toolchain = true,
}) {
  final errors = <String>[];
  if (docs) {
    final files = _iterDocFiles(repoRoot);
    errors
      ..addAll(_checkPaths(repoRoot, files))
      ..addAll(_checkMarkdownLinks(repoRoot, files))
      ..addAll(_checkSections(repoRoot, files))
      ..addAll(_checkOrphans(repoRoot, files))
      ..addAll(_checkAdrNumbers(repoRoot));
  }
  if (toolchain) {
    errors.addAll(_checkToolchain(repoRoot));
  }
  return DocsCheckResult(errors);
}

List<File> _iterDocFiles(String root) {
  final files = <File>[for (final name in _rootDocs) File(_join(root, name))];
  final docsDir = Directory(_join(root, 'docs'));
  if (docsDir.existsSync()) {
    files.addAll(
      docsDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.md')),
    );
  }
  final skillsDir = Directory(_join(root, '.agents/skills'));
  if (skillsDir.existsSync()) {
    for (final dir in skillsDir.listSync().whereType<Directory>()) {
      final name = _basename(dir.path);
      if (!name.startsWith('molia-')) continue;
      files.addAll(
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.md')),
      );
    }
  }
  final unique = <String, File>{for (final file in files) file.path: file};
  final sorted = unique.values.toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return sorted.where((file) => file.existsSync()).toList();
}

String _join(String root, String relative) =>
    '$root${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

String _basename(String path) => path.split(Platform.pathSeparator).last;

String _relative(String root, File file) {
  final prefix = '$root${Platform.pathSeparator}';
  final path = file.path.startsWith(prefix)
      ? file.path.substring(prefix.length)
      : file.path;
  return path.replaceAll(Platform.pathSeparator, '/');
}

bool _isAdr(String root, File file) =>
    _relative(root, file).startsWith('docs/adr/');

/// 折叠 `.` / `..`（等价于 Python 的 Path.resolve() 的路径部分）。
String _normalize(String path) {
  final absolute = path.startsWith(Platform.pathSeparator);
  final parts = <String>[];
  for (final part in path.split(Platform.pathSeparator)) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!absolute) {
        parts.add('..');
      }
      continue;
    }
    parts.add(part);
  }
  final joined = parts.join(Platform.pathSeparator);
  return absolute ? '${Platform.pathSeparator}$joined' : joined;
}

/// 去掉 ``` 围栏内容，避免把示例里的 [x](y) 当成真链接。
String _stripCodeFences(String text) =>
    text.replaceAll(RegExp(r'```[\s\S]*?```'), '');

bool _allowlisted(String token) {
  if (_pathAllowlist.containsKey(token)) return true;
  return _pathAllowlist.keys.any(
    (allowed) =>
        allowed.endsWith('/') &&
        (token == allowed.substring(0, allowed.length - 1) ||
            token.startsWith(allowed)),
  );
}

List<String> _checkPaths(String root, List<File> files) {
  final errors = <String>[];
  final backtick = RegExp(r'`([^`\n]+)`');
  for (final file in files) {
    if (_isAdr(root, file)) continue; // ADR 允许引用当时存在、后来改名的路径
    final text = file.readAsStringSync();
    for (final match in backtick.allMatches(text)) {
      final raw = (match.group(1) ?? '').trim();
      if (raw.isEmpty) continue;
      var token = raw.split(RegExp(r'\s+')).first.split('::').first;
      token = token.replaceFirst(RegExp(r'[.,;:)\]}，。；：）]+$'), '');
      if (!_pathPrefixes.any(token.startsWith)) continue;
      if (RegExp(r'[*<>{}|$~]').hasMatch(token)) continue;
      if (token.contains('://') || token.contains('...')) continue;
      if (_allowlisted(token)) continue;
      final adrRef = RegExp(r'^docs/adr/(\d{4})$').firstMatch(token);
      if (adrRef != null) {
        final prefix = adrRef.group(1)!;
        final hasMatch = Directory(_join(root, 'docs/adr'))
            .listSync()
            .whereType<File>()
            .any(
              (item) =>
                  _basename(item.path).startsWith('$prefix-') &&
                  item.path.endsWith('.md'),
            );
        if (!hasMatch) errors.add('${_relative(root, file)}: ADR 不存在: $token');
        continue;
      }
      final path = _join(root, token);
      // 与 Python 的 Path.exists() 对齐：目录也算存在（文档里常引用目录名）。
      final ok =
          FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
      if (!ok) errors.add('${_relative(root, file)}: 路径不存在: $token');
    }
  }
  return errors;
}

List<String> _checkMarkdownLinks(String root, List<File> files) {
  final errors = <String>[];
  final linkRe = RegExp(r'\[[^\]]*\]\(([^)\s]+)\)');
  for (final file in files) {
    final text = _stripCodeFences(file.readAsStringSync());
    for (final match in linkRe.allMatches(text)) {
      var target = match.group(1)!;
      if (target.startsWith('http://') ||
          target.startsWith('https://') ||
          target.startsWith('mailto:') ||
          target.startsWith('#') ||
          target.startsWith('/')) {
        continue;
      }
      target = target.split('#').first;
      if (target.isEmpty) continue;
      final resolved = _normalize(
        '${file.parent.path}${Platform.pathSeparator}$target',
      );
      if (!File(resolved).existsSync() && !Directory(resolved).existsSync()) {
        errors.add('${_relative(root, file)}: 链接不存在: $target');
      }
    }
  }
  return errors;
}

Set<String> _headingNumbers(File file) => RegExp(
  r'^#{1,6}\s+(\d+(?:\.\d+)*)',
  multiLine: true,
).allMatches(file.readAsStringSync()).map((match) => match.group(1)!).toSet();

List<String> _checkSections(String root, List<File> files) {
  final errors = <String>[];
  final sectionRe = RegExp(r'§(\d+(?:\.\d+)*)');
  final adrNumberRe = RegExp(r'ADR-(\d{4})');
  final mdInBackticks = RegExp(r'`([^`]+\.md)`');
  for (final file in files) {
    final text = _stripCodeFences(file.readAsStringSync());
    for (final match in sectionRe.allMatches(text)) {
      final ref = match.group(1)!;
      final lineStart = text.lastIndexOf('\n', match.start) + 1;
      final context = text.substring(lineStart, match.start);
      File? target;
      final md = mdInBackticks.firstMatch(context);
      if (md != null) {
        final candidate = File(_join(root, md.group(1)!));
        target = candidate.existsSync()
            ? candidate
            : File(
                '${file.parent.path}${Platform.pathSeparator}${md.group(1)!}',
              );
      } else {
        final adr = adrNumberRe.firstMatch(context);
        if (adr != null) {
          final found =
              Directory(_join(root, 'docs/adr'))
                  .listSync()
                  .whereType<File>()
                  .where(
                    (item) =>
                        _basename(item.path).startsWith('${adr.group(1)}-') &&
                        item.path.endsWith('.md'),
                  )
                  .toList()
                ..sort((a, b) => a.path.compareTo(b.path));
          target = found.isEmpty ? null : found.last;
        } else {
          target = file;
        }
      }
      if (target == null || !target.existsSync()) continue;
      final numbers = _headingNumbers(target);
      if (numbers.isNotEmpty && !numbers.contains(ref)) {
        errors.add(
          '${_relative(root, file)}: 章节不存在: §$ref'
          '（目标 ${_relative(root, target)}）',
        );
      }
    }
  }
  return errors;
}

List<String> _checkOrphans(String root, List<File> files) {
  final errors = <String>[];
  final docsDir = Directory(_join(root, 'docs'));
  final targets =
      docsDir
          .listSync()
          .whereType<File>()
          .where(
            (file) =>
                file.path.endsWith('.md') && !file.path.endsWith('README.md'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in targets) {
    final others = files
        .where((item) => item.path != file.path)
        .map((item) => item.readAsStringSync())
        .join('\n');
    if (!others.contains(_basename(file.path))) {
      errors.add(
        '${_relative(root, file)}: 孤儿文档（没有文档指向它；加进 docs/README.md 或删除）',
      );
    }
  }
  return errors;
}

List<String> _checkAdrNumbers(String root) {
  final errors = <String>[];
  final adrDir = Directory(_join(root, 'docs/adr'));
  final numbers = <int>[];
  final files = adrDir.listSync().whereType<File>().where((file) {
    return RegExp(r'^\d{4}-.*\.md$').hasMatch(_basename(file.path));
  }).toList()..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    numbers.add(int.parse(_basename(file.path).substring(0, 4)));
  }
  final expected = [
    for (var index = 1; index <= numbers.length; index++) index,
  ];
  if (numbers.join(',') != expected.join(',')) {
    errors.add('docs/adr/: ADR 编号应从 0001 起连续且唯一，当前为 $numbers');
  }
  return errors;
}

Map<String, String> _toolchainFromAgents(String root) {
  final text = File(_join(root, 'AGENTS.md')).readAsStringSync();
  final section = text.split('## 工具链')[1].split('\n## ').first;
  final values = <String, String>{};

  void grab(String key, String pattern) {
    final match = RegExp(pattern, multiLine: true).firstMatch(section);
    if (match == null) {
      throw StateError('无法从 AGENTS.md 工具链段解析 $key');
    }
    values[key] = match.group(1)!;
  }

  grab('flutter', r'Flutter\s*/\s*Dart\s+([\d.]+)\s*/');
  grab('dart', r'Flutter\s*/\s*Dart\s+[\d.]+\s*/\s*([\d.]+)');
  grab('jdk', r'JDK\s+(\d+)\+?');
  grab('gradle', r'Gradle\s+([\d.]+)');
  grab('agp', r'AGP\s+([\d.]+)');
  grab('kotlin', r'Kotlin\s+([\d.]+)');
  grab('compile_sdk', r'compileSdk\s+([\d.]+)');
  grab('target_sdk', r'targetSdk\s+([\d.]+)');
  grab('min_sdk', r'minSdk\s+([\d.]+)');
  grab('build_tools', r'build-tools\s+([\d.]+)');
  grab('ndk', r'NDK\s+([\d.]+)');
  grab('android_cli', r'Android CLI\s+([\d.]+)');
  return values;
}

List<String> _checkToolchain(String root) {
  final errors = <String>[];
  final expected = _toolchainFromAgents(root);

  void compare(String label, String? actual, String want, String source) {
    if (actual != want) {
      errors.add('$source: $label = $actual，AGENTS.md 为 $want');
    }
  }

  String readText(String relative) =>
      File(_join(root, relative)).readAsStringSync();

  final pubspec = readText('pubspec.yaml');
  final env = pubspec.split('environment:')[1].split('\n\n').first;
  final sdk = RegExp(
    r'^\s+sdk:\s*[\^>=<]*\s*([\d.]+)',
    multiLine: true,
  ).firstMatch(env);
  final flutter = RegExp(
    r'''^\s+flutter:\s*["']?[>=<^]*\s*([\d.]+)''',
    multiLine: true,
  ).firstMatch(env);
  compare('Dart SDK', sdk?.group(1), expected['dart']!, 'pubspec.yaml');
  compare('Flutter', flutter?.group(1), expected['flutter']!, 'pubspec.yaml');

  final wrapper = readText('android/gradle/wrapper/gradle-wrapper.properties');
  final gradle = RegExp(r'gradle-([\d.]+)-bin\.zip').firstMatch(wrapper);
  compare(
    'Gradle',
    gradle?.group(1),
    expected['gradle']!,
    'android/gradle/wrapper/gradle-wrapper.properties',
  );

  final settings = readText('android/settings.gradle');
  final agp = RegExp(
    r'''com\.android\.application"?\s+version\s+['"]([\d.]+)['"]''',
  ).firstMatch(settings);
  final kotlin = RegExp(
    r'''org\.jetbrains\.kotlin\.android"?\s+version\s+['"]([\d.]+)['"]''',
  ).firstMatch(settings);
  compare('AGP', agp?.group(1), expected['agp']!, 'android/settings.gradle');
  compare(
    'Kotlin',
    kotlin?.group(1),
    expected['kotlin']!,
    'android/settings.gradle',
  );

  final buildGradle = readText('android/app/build.gradle');
  final major = RegExp(
    r'^\s*compileSdk\s*=\s*(\d+)',
    multiLine: true,
  ).firstMatch(buildGradle);
  final minor = RegExp(
    r'^\s*compileSdkMinor\s*=\s*(\d+)',
    multiLine: true,
  ).firstMatch(buildGradle);
  final compileSdk = major != null && minor != null
      ? '${major.group(1)}.${minor.group(1)}'
      : null;
  compare(
    'compileSdk',
    compileSdk,
    expected['compile_sdk']!,
    'android/app/build.gradle',
  );

  final target = RegExp(
    r'^\s*targetSdk\s*=\s*(\d+)',
    multiLine: true,
  ).firstMatch(buildGradle);
  compare(
    'targetSdk',
    target?.group(1),
    expected['target_sdk']!,
    'android/app/build.gradle',
  );

  final minimum = RegExp(
    r'^\s*minSdk\s*=\s*(\d+)',
    multiLine: true,
  ).firstMatch(buildGradle);
  compare(
    'minSdk',
    minimum?.group(1),
    expected['min_sdk']!,
    'android/app/build.gradle',
  );

  final buildTools = RegExp(r'buildToolsVersion\s*=\s*"([\d.]+)"')
      .firstMatch(buildGradle);
  compare(
    'build-tools',
    buildTools?.group(1),
    expected['build_tools']!,
    'android/app/build.gradle',
  );

  final ndk = RegExp(r'ndkVersion\s*=\s*"([\d.]+)"').firstMatch(buildGradle);
  compare('NDK', ndk?.group(1), expected['ndk']!, 'android/app/build.gradle');

  final workflows =
      Directory(_join(root, '.github/workflows'))
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.yml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final workflow in workflows) {
    final text = workflow.readAsStringSync();
    final name = _relative(root, workflow);
    for (final match in RegExp(
      r'''flutter-version:\s*["']?([\d.]+)''',
    ).allMatches(text)) {
      compare('Flutter', match.group(1), expected['flutter']!, name);
    }
    for (final match in RegExp(
      r'''java-version:\s*["']?(\d+)''',
    ).allMatches(text)) {
      compare('JDK', match.group(1), expected['jdk']!, name);
    }
    for (final match in RegExp(
      r'compile_sdk_platform=platforms/android-([\d.]+)',
    ).allMatches(text)) {
      compare('compileSdk', match.group(1), expected['compile_sdk']!, name);
    }
    for (final match in RegExp(
      r'build_tools_version=([\d.]+)',
    ).allMatches(text)) {
      compare('build-tools', match.group(1), expected['build_tools']!, name);
    }
    for (final match in RegExp(
      r'^\s*ndk_version=([\d.]+)',
      multiLine: true,
    ).allMatches(text)) {
      compare('NDK', match.group(1), expected['ndk']!, name);
    }
    for (final match in RegExp(
      r'''^\s*ANDROID_CLI_VERSION:\s*["']?([\d.]+)''',
      multiLine: true,
    ).allMatches(text)) {
      compare('Android CLI', match.group(1), expected['android_cli']!, name);
    }
  }

  // 文档不得复列当前版本；带日期的测量快照与 ADR 除外。
  final versionTokens = <String, String>{
    'Flutter': expected['flutter']!,
    'Dart': expected['dart']!,
    'Gradle': expected['gradle']!,
    'AGP': expected['agp']!,
    'Kotlin': expected['kotlin']!,
    'build-tools': expected['build_tools']!,
    'NDK': expected['ndk']!,
    'Android CLI': expected['android_cli']!,
  };
  for (final file in _iterDocFiles(root)) {
    final name = _relative(root, file);
    if (name == 'AGENTS.md') continue; // 版本来源本身
    if (_isAdr(root, file) || _versionAllowlist.containsKey(name)) continue;
    final text = file.readAsStringSync();
    for (final entry in versionTokens.entries) {
      final pattern = RegExp(
        '(?<![\\w.])${RegExp.escape(entry.value)}(?![\\w.])',
      );
      if (pattern.hasMatch(text)) {
        errors.add(
          '$name: 复列了 ${entry.key} 当前版本 ${entry.value}；'
          '只保留 AGENTS.md「工具链」一处',
        );
      }
    }
    if (RegExp(r'(compileSdk|platforms/android-)\s*=?\s*37\.2')
        .hasMatch(text)) {
      errors.add('$name: 复列了 compileSdk 37.2；只保留 AGENTS.md「工具链」一处');
    }
  }
  return errors;
}
