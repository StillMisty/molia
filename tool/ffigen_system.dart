/// 生成桌面 / Apple 系统绑定（FFIgen，ADR-0038）。
///
/// 用法：`dart run tool/ffigen_system.dart`
///
/// 阶段 0 只建立流程与边界，不生成业务绑定：`inputs` 为空时脚本打印说明并
/// 正常退出，CI 的生成物 drift 任务因此不会失败。阶段 1 / 3 在 `inputs` 里
/// 登记 vendored 头文件后，脚本会产出 `lib/platform/<output>.g.dart`。
///
/// 阶段 3 的 Apple 生成物会 import `package:objective_c`；生成前必须把它从
/// 传递依赖转为直接依赖（否则触发 `depend_on_referenced_packages`）。
///
/// 生成期只依赖 libclang（FFIgen 自带校验）；输入头文件缺失时脚本给出明确
/// 错误并退出，不会静默跳过。
library;

import 'dart:io';

import 'package:ffigen/ffigen.dart';
import 'package:path/path.dart' as p;

/// 一组 FFIgen 输入。
///
/// [header] 是 vendored 头文件（相对仓库根）；[output] 是 `lib/platform/`
/// 下的相对路径，不含 `.g.dart` 后缀。[objectiveC] 为真时走 Objective-C
/// 绑定（需要 `package:objective_c` 与运行期编译的 `.m`），否则按 C 生成。
class FfigenInput {
  const FfigenInput({
    required this.output,
    required this.header,
    this.objectiveC = false,
    this.compilerOptions = const [],
  });

  final String output;
  final String header;
  final bool objectiveC;
  final List<String> compilerOptions;
}

/// 当前登记的输入。阶段 0 刻意留空。
const List<FfigenInput> inputs = <FfigenInput>[];

Future<void> main(List<String> args) async {
  if (inputs.isEmpty) {
    stdout.writeln(
      'ffigen: 阶段 0 未配置绑定输入，跳过（ADR-0038）。\n'
      '  阶段 1 / 3 在 tool/ffigen_system.dart 的 inputs 中登记头文件后重跑。',
    );
    return;
  }

  final packageRoot = _packageRoot();
  final missing = <String>[
    for (final input in inputs)
      if (!File.fromUri(_absolute(packageRoot, input.header)).existsSync())
        '${input.output}: 头文件不存在 ${input.header}',
  ];
  if (missing.isNotEmpty) {
    stderr.writeln('ffigen: 输入缺失，未生成任何文件：\n  ${missing.join('\n  ')}');
    exitCode = 2;
    return;
  }

  for (final input in inputs) {
    final header = File.fromUri(_absolute(packageRoot, input.header));
    final output = File.fromUri(
      _absolute(packageRoot, 'lib/platform/${input.output}.g.dart'),
    );
    await output.parent.create(recursive: true);

    final generator = FfiGenerator(
      input: Input(
        // 绝对 Uri：不依赖调用时的 CWD。
        entryPoints: [header.absolute.uri],
        compilerOptions: input.compilerOptions.isEmpty
            ? null
            : input.compilerOptions,
      ),
      objectiveC: input.objectiveC ? const ObjectiveC() : null,
      output: Output(
        dart: DartOutput(path: output.absolute.uri),
        preamble: '// 生成物：dart run tool/ffigen_system.dart；勿手改（ADR-0038）。\n',
      ),
    );
    await generator.generate();
  }

  stdout.writeln('ffigen: 已生成 ${inputs.length} 个绑定到 lib/platform/');
}

/// 仓库根：优先从脚本位置（`tool/` 的上一级）推断，其次要求 CWD 是仓库根。
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
  stderr.writeln('ffigen: 找不到仓库根（pubspec.yaml）；请在仓库根运行该脚本。');
  exit(2);
}

/// `relative` 相对仓库根解析成绝对文件 URI。
Uri _absolute(Directory packageRoot, String relative) =>
    File.fromUri(packageRoot.uri.resolve(relative)).absolute.uri;
