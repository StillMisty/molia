/// 生成桌面系统绑定（C，FFIgen，ADR-0038）。
///
/// 用法：`dart run tool/ffigen_system.dart`
///
/// 在 `inputs` 里登记 vendored 头文件，脚本产出
/// `lib/platform/<output>.g.dart`（调用方在 `output` 里写 `desktop/...`）。
///
/// Apple 不在此脚本：系统字体、低电量模式统一走 Swift + Pigeon，不生成
/// Objective-C 绑定，也不直接依赖 `package:objective_c`。
///
/// 生成期只依赖 libclang（FFIgen 自带校验）；输入头文件缺失时脚本给出明确
/// 错误并退出，不会静默跳过。
library;

import 'dart:io';

import 'package:ffigen/ffigen.dart';
import 'package:path/path.dart' as p;

/// 一组 FFIgen 输入。
///
/// [header] 是 vendored C 头文件（相对仓库根）；[output] 是 `lib/platform/`
/// 下的相对路径，不含 `.g.dart` 后缀，由调用方写成 `desktop/<name>`。
class FfigenInput {
  const FfigenInput({
    required this.output,
    required this.header,
    this.compilerOptions = const [],
  });

  final String output;
  final String header;
  final List<String> compilerOptions;
}

/// 当前登记的输入：桌面 C（POSIX / allocator）。
///
/// Win32 不在这里生成：直接复用 `package:win32` 6.4 的上游生成绑定，避免
/// 自己维护 Windows 声明（ADR-0038）。
const List<FfigenInput> inputs = <FfigenInput>[
  FfigenInput(
    output: 'desktop/system_ffi',
    header: 'third_party/system_shim/system_shim.h',
  ),
];

Future<void> main(List<String> args) async {
  if (inputs.isEmpty) {
    stdout.writeln(
      'ffigen: 未配置绑定输入，跳过（ADR-0038）。\n'
      '  在 tool/ffigen_system.dart 的 inputs 中登记头文件后重跑。',
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
      output: Output(
        dart: DartOutput(path: output.absolute.uri),
        preamble: '// 生成物：dart run tool/ffigen_system.dart；勿手改（ADR-0038）。\n',
      ),
      // FFIgen 23 的声明默认全部排除，必须用 visitor 显式纳入。libc 的
      // `__errno_location` / `__error` 以 `_` 开头，在 Dart 里是库私有；这里
      // 改名并让生成器写出 `symbol:` 保留真实符号名，适配器才能跨库调用。
      visitors: [
        Visitor(
          func: (node) {
            node.isIncluded = true;
            node.name = _dartFunctionName(node.originalName);
          },
        ),
      ],
    );
    await generator.generate();
  }

  stdout.writeln('ffigen: 已生成 ${inputs.length} 个绑定到 lib/platform/');
}

/// 生成绑定的 Dart 函数名。
///
/// 只有 libc 的两个 errno 入口需要改名（`_` 前缀 = Dart 库私有）；其它函数
/// 保持原名，生成器不会额外写 `symbol:`。
String _dartFunctionName(String originalName) => switch (originalName) {
  '__errno_location' => 'errnoLocation',
  '__error' => 'darwinErrno',
  _ => originalName,
};

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
