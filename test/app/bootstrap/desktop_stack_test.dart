import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/bootstrap/desktop_stack.dart';

void main() {
  test('系统退出请求空闲时先取消并启动落盘，销毁阶段才放行', () async {
    final windowQuit = Completer<void>();
    var committed = false;
    var beforeWindowQuit = false;
    final controller = AppQuitController((onBeforeQuitWindow) async {
      committed = true;
      onBeforeQuitWindow();
      beforeWindowQuit = true;
      await windowQuit.future;
    });

    // 第一次请求：必须取消系统终止，让 quitApp 先落盘。
    expect(controller.handleExitRequest(), AppExitResponse.cancel);
    await pumpEventQueue();
    expect(committed, isTrue);
    expect(beforeWindowQuit, isTrue);

    // 销毁窗口阶段：同类请求放行，不能把退出流程取消掉。
    expect(controller.handleExitRequest(), AppExitResponse.exit);

    windowQuit.complete();
    await pumpEventQueue();
    expect(controller.isActive, isTrue, reason: '销毁动作返回后仍在等待进程退出');
  });

  test('保存中重复请求继续取消，并发 quit 只提交一次', () async {
    final releaseCommit = Completer<void>();
    final windowQuit = Completer<void>();
    var commits = 0;
    final controller = AppQuitController((onBeforeQuitWindow) async {
      commits++;
      await releaseCommit.future;
      onBeforeQuitWindow();
      await windowQuit.future;
    });

    final first = controller.quit();
    final second = controller.quit();
    expect(identical(first, second), isTrue);
    await pumpEventQueue();
    expect(commits, 1);

    expect(controller.handleExitRequest(), AppExitResponse.cancel);
    releaseCommit.complete();
    await pumpEventQueue();
    expect(controller.handleExitRequest(), AppExitResponse.exit);

    windowQuit.complete();
    await first;
    expect(commits, 1);
  });

  test('commitBeforeQuit 在销毁窗口前调用状态切换钩子', () async {
    final order = <String>[];
    await commitBeforeQuit(
      commitSession: () async => order.add('session'),
      shutdownAudio: () async => order.add('audio'),
      flushStatistics: () => order.add('statistics'),
      onBeforeQuitWindow: () => order.add('before-window-quit'),
      quitWindow: () async => order.add('quit-window'),
    );
    expect(order, <String>[
      'session',
      'audio',
      'statistics',
      'before-window-quit',
      'quit-window',
    ]);
  });

  test('提交失败会复位门闩，下一次退出请求可以重试', () async {
    var attempts = 0;
    final controller = AppQuitController((onBeforeQuitWindow) async {
      attempts++;
      onBeforeQuitWindow();
      throw StateError('模拟窗口销毁失败');
    });

    expect(controller.handleExitRequest(), AppExitResponse.cancel);
    await pumpEventQueue();
    expect(attempts, 1);
    expect(controller.isActive, isFalse, reason: '失败后不能把应用锁在退出态');

    expect(controller.handleExitRequest(), AppExitResponse.cancel);
    await pumpEventQueue();
    expect(attempts, 2, reason: '复位后应允许重试');
  });
}
