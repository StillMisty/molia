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

  test('退出前提交：统计落盘未完成不销毁窗口', () async {
    final gate = Completer<void>();
    final log = <String>[];

    final quit = commitBeforeQuit(
      commitSession: () async => log.add('session'),
      flushStatistics: () async {
        log.add('stats-start');
        await gate.future;
        log.add('stats-end');
      },
      quitWindow: () async => log.add('quit'),
    );

    await Future<void>.delayed(Duration.zero);
    expect(log, ['session', 'stats-start']);

    gate.complete();
    await quit;
    expect(log, ['session', 'stats-start', 'stats-end', 'quit']);
  });

  test('退出前提交：统计落盘超时有界，随后仍退出', () async {
    final never = Completer<void>();
    final log = <String>[];

    await commitBeforeQuit(
      commitSession: () async => log.add('session'),
      flushStatistics: () {
        log.add('stats');
        return never.future;
      },
      quitWindow: () async => log.add('quit'),
      statisticsTimeout: const Duration(milliseconds: 20),
    );

    expect(log, ['session', 'stats', 'quit']);
  });

  test('退出前提交：顺序为会话 → 音频 → 统计 → quit，会话在途时音频不能先跑', () async {
    final gate = Completer<void>();
    final log = <String>[];

    final quit = commitBeforeQuit(
      commitSession: () async {
        log.add('session-start');
        await gate.future;
        log.add('session-end');
      },
      shutdownAudio: () async {
        log.add('audio-start');
        log.add('audio-end');
      },
      flushStatistics: () => log.add('stats'),
      quitWindow: () async => log.add('quit'),
    );

    // 会话提交在途：音频收尾、统计与销毁窗口都不能先跑（进度还没取完）。
    await Future<void>.delayed(Duration.zero);
    expect(log, ['session-start']);

    gate.complete();
    await quit;
    expect(log, [
      'session-start',
      'session-end',
      'audio-start',
      'audio-end',
      'stats',
      'quit',
    ]);
  });

  test('退出前提交：音频收尾抛异常仍继续统计并退出', () async {
    final log = <String>[];

    await commitBeforeQuit(
      commitSession: () async {
        log.add('session');
      },
      shutdownAudio: () async {
        log.add('audio');
        throw StateError('audio device failed');
      },
      flushStatistics: () => log.add('stats'),
      quitWindow: () async => log.add('quit'),
    );

    expect(log, ['session', 'audio', 'stats', 'quit']);
  });

  test('退出前提交：音频收尾超时有界，随后仍统计并退出', () async {
    final log = <String>[];
    final never = Completer<void>();

    await commitBeforeQuit(
      commitSession: () async {
        log.add('session');
      },
      shutdownAudio: () {
        log.add('audio');
        return never.future;
      },
      flushStatistics: () => log.add('stats'),
      quitWindow: () async => log.add('quit'),
      audioTimeout: const Duration(milliseconds: 20),
    );

    expect(log, ['session', 'audio', 'stats', 'quit']);
  });
}
