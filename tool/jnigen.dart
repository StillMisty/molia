/// 生成 Android JNI 绑定（JNIgen，ADR-0038）。
///
/// 用法：`dart run tool/jnigen.dart`
///
/// 生成 JDK 固定 21（JNIgen 官方支持 17–21；它的 ApiSummarizer 构建用的
/// Gradle 9.6 在 JDK 27 上会报 `Unsupported class file major version 71`）。
/// 构建 JDK 仍是 AGENTS.md 的 27。第一次在本机运行前：
///
/// ```bash
/// JAVA_HOME=/usr/lib/jvm/java-21-openjdk dart run tool/jnigen.dart
/// ```
///
/// Kotlin 源不能像 Java 那样被 javac 直接摘要：脚本先让 Gradle 编译
/// `:app:compileReleaseKotlin`，再把编译产物作为 `classPath` 交给 JNIgen 的
/// `asm` 后端。因此本脚本需要仓库的 Android SDK / Gradle 能正常配置（CI 的
/// 生成物 drift 任务暂不跑本脚本，原因见 ADR-0038）。
library;

import 'dart:io';

import 'package:jnigen/jnigen.dart';
import 'package:path/path.dart' as p;

/// 一组 JNIgen 输入。
///
/// [sourceDir] 是 Java / Kotlin 源目录（相对仓库根），[classes] 是要暴露的
/// 完整类名或包名。生成物文件名是 `<name>.g.dart`，必须与目录里的手写适配器
/// 约定一致。
class JnigenInput {
  const JnigenInput({
    required this.name,
    required this.sourceDir,
    required this.classes,
  });

  final String name;
  final String sourceDir;
  final List<String> classes;
}

/// 当前登记的输入。阶段 0 为空；阶段 2 起登记 Android 系统查询互操作对象。
const List<JnigenInput> inputs = <JnigenInput>[
  JnigenInput(
    name: 'system_interop',
    sourceDir: 'android/app/src/main/kotlin',
    classes: ['top.stillmisty.molia.interop.SystemInterop'],
  ),
];

Future<void> main(List<String> args) async {
  if (inputs.isEmpty) {
    stdout.writeln('jnigen: 未配置绑定输入，跳过（ADR-0038）。');
    return;
  }

  final packageRoot = _packageRoot();
  final missing = <String>[];
  for (final input in inputs) {
    if (!Directory.fromUri(_absoluteDir(packageRoot, input.sourceDir))
        .existsSync()) {
      missing.add('${input.name}: 源目录不存在 ${input.sourceDir}');
    }
    if (input.classes.isEmpty) {
      missing.add('${input.name}: classes 为空（至少登记一个包名或完整类名）');
    }
  }
  if (missing.isNotEmpty) {
    stderr.writeln('jnigen: 输入不完整，未生成任何文件：\n  ${missing.join('\n  ')}');
    exitCode = 2;
    return;
  }

  // Kotlin 源需要先编译成 .class（JNIgen 的 asm 后端只读字节码）。一次
  // Gradle 增量编译即可覆盖所有输入，避免每个 input 各跑一遍。
  final classRoots = await _compileAndroidKotlin(packageRoot);

  for (final input in inputs) {
    final output = File.fromUri(
      _absoluteFile(packageRoot, 'lib/platform/android/${input.name}.g.dart'),
    );
    await output.parent.create(recursive: true);

    final classPath = <Uri>[];
    for (final className in input.classes) {
      final root = classRoots[className];
      if (root == null) {
        stderr.writeln(
          'jnigen: 编译产物里找不到 $className；'
          '请确认它位于 ${input.sourceDir} 且是 public 类。',
        );
        exitCode = 2;
        return;
      }
      if (!classPath.contains(root)) classPath.add(root);
    }

    // asm 后端 + classPath：Kotlin 类由 Gradle 编译产物提供，不经过 javac；
    // sourcePath 留空，避免 JNIgen 误把 .kt 当 Java 源。输出路径与输入都走
    // 绝对 URI，不依赖调用时的 CWD。
    final generator = JniGenerator(
      input: Input(
        classes: List<String>.of(input.classes),
        classPath: classPath,
        backend: SummarizerBackend.asm,
      ),
      output: Output(
        dart: DartOutput(
          path: output.absolute.uri,
          structure: OutputStructure.singleFile,
        ),
        preamble:
            '// 生成物：dart run tool/jnigen.dart；勿手改（ADR-0038）。\n'
            '// ignore_for_file: override_on_non_overriding_member\n',
      ),
    );
    await generator.generate();
  }

  stdout.writeln('jnigen: 已生成 ${inputs.length} 个绑定到 lib/platform/android/');
}

/// 编译 app 的 Kotlin 源，返回「完整类名 → 编译输出根目录」。
///
/// Flutter 工程首次配置需要 `flutter build apk --config-only` 生成
/// `android/local.properties` / 插件工程；随后 Gradle 的增量编译通常只需
/// 一两秒。失败时打印可操作提示并以非零码退出，不生成半份绑定。
Future<Map<String, Uri>> _compileAndroidKotlin(Directory packageRoot) async {
  final androidDir = Directory(p.join(packageRoot.path, 'android'));
  if (!androidDir.existsSync()) {
    stderr.writeln('jnigen: 找不到 android/ 工程目录。');
    exit(2);
  }

  final configOnly = await Process.run('flutter', [
    'build',
    'apk',
    '--config-only',
    '--no-pub',
  ], workingDirectory: packageRoot.path);
  if (configOnly.exitCode != 0) {
    stderr.writeln(
      'jnigen: `flutter build apk --config-only` 失败，无法编译 Kotlin 源：\n'
      '${configOnly.stdout}\n${configOnly.stderr}',
    );
    exit(2);
  }

  final gradlew = Platform.isWindows ? 'gradlew.bat' : './gradlew';
  final compile = await Process.run(gradlew, [
    ':app:compileReleaseKotlin',
    '--quiet',
    '--console=plain',
  ], workingDirectory: androidDir.path);
  if (compile.exitCode != 0) {
    stderr.writeln(
      'jnigen: 编译 Kotlin 失败（`:app:compileReleaseKotlin`）：\n'
      '${compile.stdout}\n${compile.stderr}\n'
      '生成 JDK 需为 17–21：JAVA_HOME=/usr/lib/jvm/java-21-openjdk '
      'dart run tool/jnigen.dart',
    );
    exit(2);
  }

  final roots = <String, Uri>{};
  for (final input in inputs) {
    for (final className in input.classes) {
      final found = _findClassFile(packageRoot, className);
      if (found == null) continue;
      roots[className] = _classRootOf(found, className);
    }
  }
  return roots;
}

/// 在 Gradle 构建目录里找 `<className>.class`。
///
/// 只认 `compileReleaseKotlin` 的产物：`build/` 里还有 debug 变体、原生资产
/// 与打包中间物，全局取第一个会拿到旧类。
File? _findClassFile(Directory packageRoot, String className) {
  final suffix = '${className.replaceAll('.', Platform.pathSeparator)}.class';
  final buildDir = Directory(p.join(packageRoot.path, 'build'));
  if (!buildDir.existsSync()) return null;
  final matches = <File>[];
  for (final entity in buildDir.listSync(recursive: true, followLinks: false)) {
    if (entity is File &&
        entity.path.endsWith(suffix) &&
        entity.path.contains(
          '${Platform.pathSeparator}compileReleaseKotlin'
          '${Platform.pathSeparator}',
        )) {
      matches.add(entity);
    }
  }
  if (matches.isEmpty) return null;
  matches.sort((a, b) => a.path.length.compareTo(b.path.length));
  return matches.first;
}

/// 类文件路径反推 classpath 根：去掉包路径部分。
Uri _classRootOf(File classFile, String className) {
  final packageDepth = className.split('.').length - 1;
  var dir = classFile.parent;
  for (var i = 0; i < packageDepth; i++) {
    dir = dir.parent;
  }
  return Uri.directory(dir.absolute.path);
}

/// 仓库根：优先从脚本位置（`tool/` 的上一级）推断，其次要求 CWD 是仓库根。
///
/// `dart run tool/jnigen.dart` 与 `dart run` 的其它调用方式都从仓库根启动；
/// 这里仍显式校验 `pubspec.yaml`，避免在错误目录生成半份绑定。
Directory _packageRoot() {
  final script = Platform.script;
  if (script.isScheme('file')) {
    final scriptDir = File.fromUri(script).parent;
    final candidate = scriptDir.parent;
    if (File(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
      return candidate;
    }
  }
  final cwd = Directory.current;
  if (File(p.join(cwd.path, 'pubspec.yaml')).existsSync()) return cwd;
  stderr.writeln('jnigen: 找不到仓库根（pubspec.yaml）；请在仓库根运行该脚本。');
  exit(2);
}

/// `relative` 相对仓库根解析成绝对目录 URI（带尾部分隔符）。
Uri _absoluteDir(Directory packageRoot, String relative) => Uri.directory(
  File.fromUri(packageRoot.uri.resolve(relative)).absolute.path,
);

/// `relative` 相对仓库根解析成绝对文件 URI。
Uri _absoluteFile(Directory packageRoot, String relative) =>
    File.fromUri(packageRoot.uri.resolve(relative)).absolute.uri;
