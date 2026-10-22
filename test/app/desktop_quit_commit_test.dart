/// 退出前提交顺序：会话落盘必须被 await，完成前不销毁窗口。
///
/// 真实 `quitApp` 依赖 window_manager / 托盘插件，测试钉在注入面
/// [commitBeforeQuit] 上；生产接线只多一层 `WindowChrome.quit`。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/bootstrap/desktop_stack.dart';

void main() {
  test('退出前提交：会话没写完不销毁窗口，顺序为 session → stats → quit', () async {
    final gate = Completer<void>();
    final log = <String>[];

    final quit = commitBeforeQuit(
      commitSession: () async {
        log.add('session-start');
        await gate.future;
        log.add('session-end');
      },
      flushStatistics: () => log.add('stats'),
      quitWindow: () async => log.add('quit'),
    );

    // 会话提交在途：统计与销毁窗口都不能先跑。
    await Future<void>.delayed(Duration.zero);
    expect(log, ['session-start']);

    gate.complete();
    await quit;
    expect(log, ['session-start', 'session-end', 'stats', 'quit']);
  });

  test('退出前提交：会话落盘失败仍继续退出（不把用户卡在退出流程）', () async {
    final log = <String>[];

    await commitBeforeQuit(
      commitSession: () async {
        log.add('session');
        throw StateError('write failed');
      },
      flushStatistics: () => log.add('stats'),
      quitWindow: () async => log.add('quit'),
    );

    expect(log, ['session', 'stats', 'quit']);
  });

  test('退出前提交：会话提交超时有界，随后仍统计并退出', () async {
    final log = <String>[];
    final never = Completer<void>();

    await commitBeforeQuit(
      commitSession: () {
        log.add('session');
        return never.future;
      },
      flushStatistics: () => log.add('stats'),
      quitWindow: () async => log.add('quit'),
      sessionTimeout: const Duration(milliseconds: 20),
    );

    expect(log, ['session', 'stats', 'quit']);
  });
}
