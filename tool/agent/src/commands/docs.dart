/// `docs check`：文档引用与工具链一致性（CI / pre-commit 同一套规则）。
library;

import 'dart:io';

import '../context.dart';
import '../docs_check.dart';

Future<void> runDocs(ToolContext context, List<String> args) async {
  if (args.isEmpty || args.first != 'check') {
    stderr.write(_usage);
    exitCode = 2;
    return;
  }
  var docs = false;
  var toolchain = false;
  for (final arg in args.sublist(1)) {
    switch (arg) {
      case '--docs':
        docs = true;
      case '--toolchain':
        toolchain = true;
      default:
        stderr.write(_usage);
        exitCode = 2;
        return;
    }
  }
  final runDocsCheckFlag = docs || !toolchain;
  final runToolchainFlag = toolchain || !docs;

  final DocsCheckResult result;
  try {
    result = runDocsCheck(
      context.repoRoot,
      docs: runDocsCheckFlag,
      toolchain: runToolchainFlag,
    );
  } on StateError catch (error) {
    stderr.writeln('check_docs: ${error.message}');
    exitCode = 1;
    return;
  }

  if (result.ok) {
    stdout.writeln('check_docs: OK');
    return;
  }
  for (final error in result.errors) {
    stderr.writeln('ERROR $error');
  }
  stderr.writeln('\ncheck_docs: ${result.errors.length} 项失败');
  exitCode = 1;
}

const String _usage = '''
用法: dart run tool/agent/cli.dart docs check [--docs|--toolchain]

  --docs        只查文档引用（路径 / 链接 / 章节号 / 孤儿文档 / ADR 编号）
  --toolchain   只查工具链版本与文档复列

不给参数时两组都跑。CI 与 .githooks/pre-commit 调用的就是这条命令。
''';
