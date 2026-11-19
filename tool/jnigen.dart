/// 生成 Android JNI 绑定（JNIgen，ADR-0038）。
///
/// 用法：`dart run tool/jnigen.dart`
///
/// 阶段 0 只建立流程与边界，不生成业务绑定：`inputs` 为空时脚本打印说明并
/// 正常退出，CI 的生成物 drift 任务因此不会失败。阶段 3 在 `inputs` 里登记
/// Java / Kotlin 源目录后，脚本会产出 `lib/platform/android/<name>.g.dart`。
///
/// 生成用 JDK 21（JNIgen 官方支持 17–21），构建仍用 AGENTS.md 的构建 JDK；
/// 两者是不同阶段，不要为了生成升级整个仓库。
library;

import 'dart:io';

import 'package:jnigen/jnigen.dart';

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

/// 当前登记的输入。阶段 0 刻意留空。
const List<JnigenInput> inputs = <JnigenInput>[];

Future<void> main(List<String> args) async {
  if (inputs.isEmpty) {
    stdout.writeln(
      'jnigen: 阶段 0 未配置绑定输入，跳过（ADR-0038）。\n'
      '  阶段 3 在 tool/jnigen.dart 的 inputs 中登记 Java / Kotlin 源目录与类名后重跑。',
    );
    return;
  }

  final missing = <String>[];
  for (final input in inputs) {
    if (!Directory(input.sourceDir).existsSync()) {
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

  final outputDir = Directory('lib/platform/android');
  await outputDir.create(recursive: true);

  for (final input in inputs) {
    final generator = JniGenerator(
      input: Input(
        sourcePath: [Uri.directory(input.sourceDir)],
        classes: List<String>.of(input.classes),
      ),
      output: Output(
        dart: DartOutput(
          path: Uri.file('${outputDir.path}/${input.name}.g.dart'),
          structure: OutputStructure.singleFile,
        ),
        preamble: '// 生成物：dart run tool/jnigen.dart；勿手改（ADR-0038）。\n',
      ),
    );
    await generator.generate();
  }

  stdout.writeln('jnigen: 已生成 ${inputs.length} 个绑定到 ${outputDir.path}/');
}
