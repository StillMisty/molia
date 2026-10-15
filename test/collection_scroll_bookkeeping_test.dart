/// 合集滚动簿记的纯单测：计时与帧后调度注入假实现、控制器用假对象，
/// 状态机脱离时钟与 widget 树推进（只经 module 的公开接口断言）。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/collection_scroll_bookkeeping.dart';

/// 假调度：计时与帧后回调都攒起来，由测试显式触发。
class _FakeScheduler implements CollectionScrollScheduler {
  VoidCallback? _timerCallback;
  final List<VoidCallback> frames = [];

  /// 已武装的节流间隔（重复武装会被覆盖，用 armedCount 断言次数）。
  Duration? armedDelay;
  int armedCount = 0;

  @override
  bool get isTimerArmed => _timerCallback != null;

  @override
  void armTimer(Duration delay, VoidCallback callback) {
    armedDelay = delay;
    armedCount++;
    _timerCallback = callback;
  }

  @override
  void cancelTimer() => _timerCallback = null;

  @override
  void afterFrame(VoidCallback callback) => frames.add(callback);

  /// 节流计时到点。
  void fireTimer() {
    final callback = _timerCallback;
    _timerCallback = null;
    callback?.call();
  }

  /// 当前帧布局完成（执行并清空排队的帧后回调）。
  void runFrames() {
    final pending = List<VoidCallback>.of(frames);
    frames.clear();
    for (final callback in pending) {
      callback();
    }
  }
}

/// 假滚动控制器：只实现簿记用到的接口（挂载状态 / 偏移 / 范围 / jumpTo）。
class _FakeScrollController extends ScrollController {
  _FakeScrollController({double maxScrollExtent = 1000})
      : _position = _FakeScrollPosition(maxScrollExtent: maxScrollExtent);

  @override
  bool hasClients = true;

  @override
  double offset = 0;

  final List<double> jumps = [];
  final _FakeScrollPosition _position;

  @override
  ScrollPosition get position => _position;

  @override
  void jumpTo(double value) {
    jumps.add(value);
    offset = value;
  }
}

/// 假滚动位置：只提供偏移夹取所需的范围。
class _FakeScrollPosition extends ScrollPosition {
  _FakeScrollPosition({required this.maxScrollExtent})
      : super(
          physics: const ClampingScrollPhysics(),
          context: _FakeScrollContext(),
          keepScrollOffset: false,
        );

  @override
  final double maxScrollExtent;

  @override
  double get minScrollExtent => 0;

  /// 簿记只读范围（不拖拽 / 不动画 / 不吸附）：其余成员不实现。
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 假滚动上下文：ScrollPosition 构造要求非空上下文（本测试不使用它）。
class _FakeScrollContext implements ScrollContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late _FakeScheduler scheduler;
  late _FakeScrollController controller;
  late List<Map<String, double>> persisted;

  CollectionScrollBookkeeping build() => CollectionScrollBookkeeping(
        controllerOf: (_) => controller,
        persist: (offsets) async => persisted.add(offsets),
        scheduler: scheduler,
      );

  setUp(() {
    scheduler = _FakeScheduler();
    controller = _FakeScrollController();
    persisted = [];
  });

  group('保存（节流 + 只写变化）', () {
    test('默认节流 ≤2 次/秒；滚动事件武装一次并到点落盘', () {
      expect(
        CollectionScrollBookkeeping.defaultThrottle,
        const Duration(milliseconds: 500),
      );
      final bookkeeping = build()..activate('favorites');
      controller.offset = 120;

      bookkeeping.saveFromScroll();
      expect(scheduler.armedDelay, const Duration(milliseconds: 500));
      expect(persisted, isEmpty, reason: '节流窗口内不写');

      scheduler.fireTimer();
      expect(persisted, [
        {'favorites': 120},
      ]);
    });

    test('节流窗口内重复滚动不重复计时', () {
      final bookkeeping = build()..activate('favorites');

      bookkeeping.saveFromScroll();
      bookkeeping.saveFromScroll();
      bookkeeping.saveFromScroll();

      expect(scheduler.armedCount, 1);
    });

    test('偏移未变不重复落盘', () {
      final bookkeeping = build()..activate('favorites');
      controller.offset = 120;
      bookkeeping.saveFromScroll();
      scheduler.fireTimer();

      bookkeeping.saveFromScroll();
      scheduler.fireTimer();

      expect(persisted, hasLength(1));
    });

    test('flush 立即落盘（切换合集 / 释放前排空）', () {
      final bookkeeping = build()..activate('playlist:7');
      controller.offset = 42;

      bookkeeping.flush();

      expect(persisted, [
        {'playlist:7': 42},
      ]);
    });

    test('未激活合集 / 列表未挂载：不写', () {
      final bookkeeping = build();
      controller.offset = 42;
      bookkeeping.flush();

      bookkeeping.activate('favorites');
      controller.hasClients = false;
      bookkeeping.flush();

      expect(persisted, isEmpty);
    });

    test('dispose：取消在飞计时并落盘最后一次位置', () {
      final bookkeeping = build()..activate('favorites');
      controller.offset = 88;
      bookkeeping.saveFromScroll();

      bookkeeping.dispose();
      expect(persisted, [
        {'favorites': 88},
      ]);

      // 释放后：计时到点 / 新滚动事件都不再写。
      scheduler.fireTimer();
      controller.offset = 200;
      bookkeeping.saveFromScroll();
      scheduler.fireTimer();
      expect(persisted, hasLength(1));
      expect(scheduler.isTimerArmed, isFalse);
    });
  });

  group('恢复（帧后执行 + 只恢复一次 + 夹取）', () {
    test('内容就绪后帧后 jumpTo 到保存的偏移', () {
      final bookkeeping = build()
        ..restoreOffsets({'favorites': 400})
        ..activate('favorites');

      bookkeeping.scheduleRestore();
      expect(controller.jumps, isEmpty, reason: '帧后执行，布局完成才跳');

      scheduler.runFrames();
      expect(controller.jumps, [400]);
    });

    test('同一合集只恢复一次', () {
      final bookkeeping = build()
        ..restoreOffsets({'favorites': 400})
        ..activate('favorites');
      bookkeeping.scheduleRestore();
      scheduler.runFrames();

      controller.offset = 0;
      bookkeeping.scheduleRestore();
      scheduler.runFrames();

      expect(controller.jumps, hasLength(1));
    });

    test('偏移夹取到可滚动范围', () {
      final bookkeeping = build()
        ..restoreOffsets({'favorites': 5000})
        ..activate('favorites');

      bookkeeping.scheduleRestore();
      scheduler.runFrames();

      expect(controller.jumps, [1000]);
    });

    test('偏移为 0：不跳转（无意义的零位移）', () {
      final bookkeeping = build()
        ..restoreOffsets({'favorites': 0})
        ..activate('favorites');

      bookkeeping.scheduleRestore();
      scheduler.runFrames();

      expect(controller.jumps, isEmpty);
    });

    test('合集已切换：本次作废，按新合集重新调度', () {
      final bookkeeping = build()
        ..restoreOffsets({'favorites': 400, 'history': 60})
        ..activate('favorites');
      bookkeeping.scheduleRestore();

      bookkeeping.activate('history');
      scheduler.runFrames();
      expect(controller.jumps, isEmpty, reason: '旧合集的调度作废');

      bookkeeping.scheduleRestore();
      scheduler.runFrames();
      expect(controller.jumps, [60]);
    });

    test('列表尚未挂载：不标记已恢复，下次调度重试', () {
      final bookkeeping = build()
        ..restoreOffsets({'favorites': 400})
        ..activate('favorites');
      controller.hasClients = false;
      bookkeeping.scheduleRestore();
      scheduler.runFrames();
      expect(controller.jumps, isEmpty);

      controller.hasClients = true;
      bookkeeping.scheduleRestore();
      scheduler.runFrames();
      expect(controller.jumps, [400]);
    });

    test('每帧只调度一次（同一合集重复调度不叠加回调）', () {
      final bookkeeping = build()
        ..restoreOffsets({'favorites': 400})
        ..activate('favorites');

      bookkeeping.scheduleRestore();
      bookkeeping.scheduleRestore();
      bookkeeping.scheduleRestore();
      expect(scheduler.frames, hasLength(1));
    });

    test('释放后帧后回调作废', () {
      final bookkeeping = build()
        ..restoreOffsets({'favorites': 400})
        ..activate('favorites');
      bookkeeping.scheduleRestore();

      bookkeeping.dispose();
      scheduler.runFrames();

      expect(controller.jumps, isEmpty);
    });
  });
}
