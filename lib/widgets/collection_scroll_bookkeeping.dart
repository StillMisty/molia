import 'dart:async';

import 'package:flutter/widgets.dart';

/// 合集滚动簿记的调度缝：防抖计时 + 帧后回调。
///
/// 生产用真实 [Timer] 与 `WidgetsBinding.addPostFrameCallback`（默认实现）；
/// 测试注入假实现手动推进，簿记状态机因此可脱离时钟与帧单测。
abstract interface class CollectionScrollScheduler {
  /// 是否有未到期的防抖计时。
  bool get isTimerArmed;

  /// 武装一次防抖计时（到点执行 [callback]；重复武装覆盖旧计时）。
  void armTimer(Duration delay, VoidCallback callback);

  /// 取消未到期的防抖计时（无则空操作）。
  void cancelTimer();

  /// 当前帧布局完成后执行一次 [callback]（`addPostFrameCallback` 语义）。
  void afterFrame(VoidCallback callback);
}

/// 合集滚动簿记：按合集键保存 / 恢复列表滚动偏移的唯一实现。
///
/// 从收藏页抽出的状态机（收藏 / 自建列表 / 播放历史 / 本地歌曲共用）：
/// - **保存**：滚动事件防抖落盘（默认 500ms；每次滚动重新计时，用户停手后
///   只写一次；偏移未变不写），切换合集与释放前 `flush` 立即落盘；
/// - **恢复**：内容就绪后按当前合集键调度一次（帧后执行）；合集已切换 /
///   列表尚未挂载则不算恢复，交给下一次调度；同一合集只恢复一次；偏移
///   夹取到可滚动范围。
///
/// 计时与帧后调度经 [CollectionScrollScheduler] 注入，状态机可脱离时钟与
/// 帧做单测；控制器的持有与创建留在调用方（[controllerOf]）。
class CollectionScrollBookkeeping {
  CollectionScrollBookkeeping({
    required this.controllerOf,
    required this.persist,
    CollectionScrollScheduler? scheduler,
    this.debounce = defaultDebounce,
  }) : _scheduler = scheduler ?? _TimerScheduler();

  /// 滚动落盘防抖间隔：每次滚动重新计时，停手一个窗口后才写。
  static const Duration defaultDebounce = Duration(milliseconds: 500);

  /// 合集键 → 该合集的滚动控制器（收藏 / 自建列表共用一个控制器）。
  final ScrollController Function(String collectionKey) controllerOf;

  /// 落盘回调（合集键 → 偏移）；写失败由调用方决定（收藏页静默）。
  final Future<void> Function(Map<String, double> offsets) persist;

  final Duration debounce;
  final CollectionScrollScheduler _scheduler;

  /// 各合集已保存的偏移（合集键 → offset）。
  Map<String, double> _offsets = const {};

  /// 当前 build 对应的合集键（滚动落盘用）。
  String? _activeKey;

  /// 已恢复过偏移的合集键（切换合集时各自只恢复一次）。
  String? _restoredFor;

  /// 已调度但未执行的恢复键（避免每帧重复帧后回调）。
  String? _pendingRestore;

  bool _disposed = false;

  /// 当前活跃合集键；null = 首帧合集尚未落定。
  String? get activeKey => _activeKey;

  /// 当前活跃合集的滚动控制器（首帧前 / 无映射为 null）。
  ScrollController? get activeController {
    final key = _activeKey;
    return key == null ? null : controllerOf(key);
  }

  /// 冷启动注入持久化偏移（只覆盖内存值，不落盘）。
  void restoreOffsets(Map<String, double> offsets) {
    _offsets = Map<String, double>.of(offsets);
  }

  /// 落定当前合集键：保存与恢复都只作用于它（页面在 build 里同步）。
  void activate(String key) => _activeKey = key;

  /// 滚动事件入口：防抖落盘（每次滚动都重新计时，停手后才写）。
  ///
  /// 不用「窗口内忽略」的节流：连续滚动会每 500ms 写一次 prefs，而 prefs
  /// 每次写入都是整文件重写（见 `docs/pitfalls.md` #93）；重新计时让一次
  /// 手势最多只产生一次落盘。
  void saveFromScroll() {
    if (_disposed) return;
    _scheduler.armTimer(debounce, flush);
  }

  /// 内容就绪后调度一次偏移恢复（帧后执行，布局完成才跳转）。
  void scheduleRestore() {
    final key = _activeKey;
    if (_disposed || key == null || key == _restoredFor) return;
    if (key == _pendingRestore) return;
    _pendingRestore = key;
    _scheduler.afterFrame(() {
      // 已被新的调度取代 / 已释放：本次作废。
      if (_disposed || _pendingRestore != key) return;
      _pendingRestore = null;
      // 合集已切换 / 列表尚未挂载：不算恢复，交给下一次 build 重新调度。
      if (_activeKey != key) return;
      final controller = controllerOf(key);
      if (!controller.hasClients) return;
      _restoredFor = key;
      final saved = _offsets[key];
      if (saved == null || saved <= 0) return;
      final position = controller.position;
      controller.jumpTo(
        saved.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  /// 立即落盘当前合集偏移（切换合集 / 释放前；偏移未变不重复写）。
  void flush() {
    if (_disposed) return;
    // 显式 flush（切换合集 / dispose）必须撤掉在飞计时：否则计时到点后会
    // 按新的 activeKey 再写一次，把旧手势的偏移记到用户没滚过的合集上。
    _scheduler.cancelTimer();
    final key = _activeKey;
    if (key == null) return;
    final controller = controllerOf(key);
    if (!controller.hasClients) return;
    final offset = controller.offset;
    if (_offsets[key] == offset) return;
    final next = Map<String, double>.of(_offsets);
    next[key] = offset;
    _offsets = next;
    unawaited(persist(next));
  }

  /// 撤销在飞计时 / 帧后调度，并落盘最后一次滚动位置。
  void dispose() {
    if (_disposed) return;
    _scheduler.cancelTimer();
    flush();
    _disposed = true;
    _pendingRestore = null;
  }
}

/// 默认调度实现：真实 Timer + post-frame 帧回调。
class _TimerScheduler implements CollectionScrollScheduler {
  Timer? _timer;

  @override
  bool get isTimerArmed => _timer?.isActive ?? false;

  @override
  void armTimer(Duration delay, VoidCallback callback) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      callback();
    });
  }

  @override
  void cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void afterFrame(VoidCallback callback) {
    WidgetsBinding.instance.addPostFrameCallback((_) => callback());
  }
}
