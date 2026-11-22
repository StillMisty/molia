import 'package:flutter_test/flutter_test.dart';

import 'publish_ledger_cases.dart' as publish_ledger;

/// 发布台账：编排层与传输层共享的「本轮已发布」记账。
///
/// 单独成文件：用例会初始化 widget binding，若与真实 HTTP 传输用例
/// 同进程会装回 HttpOverrides。
void main() {
  group('publish ledger', publish_ledger.main);
}
