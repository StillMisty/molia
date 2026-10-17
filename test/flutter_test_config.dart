import 'dart:async';

import 'package:molia/services/app_logging.dart';
import 'package:molia/sources/builtin/builtin_transport.dart';

/// `flutter test` 的全局前置钩子：Flutter 测试框架按目录约定自动加载本文件。
///
/// 为什么需要它：日志装配发生在 `lib/main.dart`，而单测不执行 `main`；
/// 不在这里装配，测试期间的日志会被 `package:logging` 直接丢弃，
/// 用例里「失败时能看到日志」的排障路径就没有了。
/// `integration_test/` 不读本文件，它跑在真实 `main` 上，无需重复装配。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  initAppLogging();
  // 传输层重试退避在测试里跳过：单测断言的是「重试次数与结果」，
  // 真实等待只会拖慢用例（生产仍是默认的指数退避 + 抖动）。
  BuiltinTransport.retryDelayOverride = (_) async {};
  await testMain();
}
