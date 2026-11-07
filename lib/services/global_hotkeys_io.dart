/// 全局热键的 nativeapi 实现（Linux / Windows / macOS 桌面）。
///
/// macOS 走 Carbon `RegisterEventHotKey`、Windows 走 `RegisterHotKey`、
/// Linux 走 X11 或 `org.freedesktop.portal.GlobalShortcuts` 桌面门户；
/// Wayland 的绑定由桌面决定，同意 / 拒绝 / 换键都通过
/// `ShortcutRegistrationFailedEvent` / `ShortcutRegisteredEvent` 回报。
///
/// 用 nativeapi 而不是再引一个热键包：桌面窗口与托盘已经依赖它，
/// `ShortcutManager` 也提供门户的异步注册、取消与注册丢失事件；本仓库只
/// 需要一层很薄的「命令名 ↔ 回调」映射。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:nativeapi/nativeapi.dart';

import 'global_hotkeys_types.dart';

/// [GlobalHotkeyRegistrar] 的生产实现。
class NativeGlobalHotkeyRegistrar implements GlobalHotkeyRegistrar {
  NativeGlobalHotkeyRegistrar() {
    _listenerId = ShortcutManager.instance.addListener(_onEvent);
  }

  final Logger _logger = Logger('molia.global_hotkeys');
  final ShortcutManager _manager = ShortcutManager.instance;

  /// shortcut id → 按下回调（只在注册成功后写入）。
  final Map<int, VoidCallback> _callbacks = {};

  /// shortcut id → 等待系统批准（Wayland 门户）的注册。
  final Map<int, Completer<void>> _pending = {};

  /// 注册过程中提前到达的结果；值为 [_registered] 或错误文案。
  final Map<int, Object> _early = {};
  static const Object _registered = Object();

  late final int _listenerId;
  int _registering = 0;

  @override
  Future<void> register(HotKeySpec spec, VoidCallback onPressed) async {
    final accelerator = acceleratorForHotKeySpec(spec);
    _registering++;
    try {
      final id = _manager.requestRegistration(
        ShortcutOptions(
          accelerator: accelerator,
          description: spec.id,
          scope: ShortcutScope.global,
          enabled: true,
        ),
        // 与旧 system_hotkeys 的 portal id 一致：桌面保存的绑定可以沿用，
        // 升级后不必重新授权一遍。
        spec.id,
      );
      if (id == 0) {
        // 参数非法、平台不支持，或该 accelerator 已在注册 / 待批准中。
        throw StateError('系统未接受该组合（$accelerator）');
      }

      final early = _early.remove(id);
      if (early != null) {
        if (early != _registered) throw StateError(early as String);
      } else if (_manager.getWithId(id) == null) {
        // Wayland 门户：等桌面批准 / 拒绝；完成前不能把回调挂上去。
        final pending = Completer<void>();
        _pending[id] = pending;
        await pending.future;
      }
      _callbacks[id] = onPressed;
    } finally {
      _registering--;
      if (_registering == 0) _early.clear();
    }
  }

  @override
  Future<void> unregisterAll() async {
    _callbacks.clear();
    _early.clear();
    // 先让等待批准的门户请求失败退出，再清理已注册项；否则 _sync 会
    // 一直等在 pending 上，下一轮注册永远开始不了。
    _cancelPending();
    _manager.unregisterAll();
  }

  /// 释放事件监听（生产只在进程退出时随之释放，测试可显式调用）。
  void dispose() {
    if (!_manager.removeListener(_listenerId)) return;
    _callbacks.clear();
    _cancelPending();
    _early.clear();
  }

  void _cancelPending() {
    for (final entry in _pending.entries.toList()) {
      _manager.cancelRegistration(entry.key);
      if (!entry.value.isCompleted) {
        entry.value.completeError(StateError('已注销'));
      }
    }
    _pending.clear();
  }

  void _onEvent(ShortcutEvent event) {
    switch (event) {
      case ShortcutActivatedEvent(:final shortcutId):
        _callbacks[shortcutId]?.call();
      case ShortcutRegisteredEvent(:final shortcutId):
        _complete(shortcutId, null);
      case ShortcutRegistrationFailedEvent(
        :final shortcutId,
        :final errorMessage,
      ):
        _complete(shortcutId, errorMessage ?? '系统未接受该组合');
      case ShortcutUnregisteredEvent(:final shortcutId):
        if (_callbacks.remove(shortcutId) != null) {
          _logger.warning('系统注销了全局热键（id=$shortcutId）');
        }
      case ShortcutReleasedEvent():
        // 全局热键按「按下」触发；释放事件不参与命令派发。
        break;
    }
  }

  void _complete(int id, String? error) {
    final pending = _pending.remove(id);
    if (pending != null) {
      if (error == null) {
        pending.complete();
      } else {
        pending.completeError(StateError(error));
      }
      return;
    }
    // 只在注册调用栈内保留提前结果；注册结束后的迟到事件（取消 / 丢失）
    // 不需要回放给下一次请求（shortcut id 不会复用）。
    if (_registering > 0) _early[id] = error ?? _registered;
  }
}
