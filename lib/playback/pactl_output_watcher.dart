/// Linux 默认输出 sink 监听（PulseAudio / PipeWire-pulse，ADR-0036）。
///
/// 只负责「默认 sink 消失」这一件事：`pactl subscribe` 的 `remove` 事件本身
/// 不带名字，先按启动 / server 变化时缓存的 id→name 表判断被移除的是不是当前
/// 默认 sink；表缺失时退回「刷新后旧默认名不在 sink 列表里」的判定。
///
/// 失败一律静默：`pactl` 不存在（精简容器 / Flatpak 沙箱）、没有声音服务器、
/// 服务器重启导致 child 退出，都只是本会话不再提供输出丢失检测，不影响播放。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'pactl_sink_events.dart';
import 'pactl_sink_tracker.dart';

/// 读取 `pactl` 并回调默认 sink 消失事件。
///
/// [onOutputLost] 在默认 sink 消失时调用；重复事件不在这里去抖（暂停幂等，
/// 去抖只会让急停变慢）。
class PactlOutputWatcher {
  PactlOutputWatcher({required this.onOutputLost, this.executable = 'pactl'});

  /// 默认 sink 消失回调。
  final void Function() onOutputLost;

  /// 可执行文件名（测试 / 诊断可换，生产固定 `pactl`）。
  final String executable;

  Process? _process;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  final PactlSinkTracker _tracker = PactlSinkTracker();
  bool _disposed = false;
  bool _loggedFailure = false;

  /// 并发刷新代次：只有最新一次刷新的结果可以覆盖快照。被更新事件取代的
  /// 旧查询直接丢弃，避免慢查询把较新的默认 sink 写回旧值。
  int _refreshGeneration = 0;

  /// 被更新刷新取代 / 合并的「旧默认名消失」通知：不能因为后一次刷新只关心
  /// 快照就把前一次的输出丢失吞掉；下一次成功应用快照时补发。
  bool _notifyOnNextSnapshot = false;

  /// 启动订阅。失败（无 `pactl` / 无服务器）静默返回，调用方继续播放。
  Future<void> start() async {
    if (_disposed) return;
    // 先建立默认 sink 快照：subscribe 之后的第一条 remove 才有名字可比。
    await _refreshSinks(notifyIfDefaultMissing: false);
    if (_disposed) return;
    try {
      final process = await Process.start(executable, const ['subscribe']);
      if (_disposed) {
        process.kill();
        return;
      }
      _process = process;
      _stdout = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine, onError: _onStreamError);
      _stderr = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((_) {}, onError: _onStreamError);
      unawaited(
        process.exitCode.then((_) {
          // 声音服务器重启 / `pactl` 被结束：不重试（重启风暴比暂时失去检测
          // 更糟），本会话后续事件自然停止。
          _process = null;
        }),
      );
    } on ProcessException catch (error) {
      _logFailureOnce(error);
    } catch (error) {
      _logFailureOnce(error);
    }
  }

  /// 停止子进程、关闭管道并忽略晚到行。幂等。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final stdout = _stdout;
    _stdout = null;
    final stderr = _stderr;
    _stderr = null;
    unawaited(stdout?.cancel());
    unawaited(stderr?.cancel());
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      try {
        await process.exitCode.timeout(
          const Duration(milliseconds: 200),
          onTimeout: () => -1,
        );
      } catch (_) {
        // 已经退出 / 无法等待：进程退出即可，不能把播放层销毁卡在这里。
      }
    }
  }

  void _onLine(String line) {
    if (_disposed) return;
    final event = parsePactlEvent(line);
    if (event == null) return;
    final action = _tracker.onEvent(event);
    if (action.emitOutputLost) {
      // 已知默认 sink 被移除：立即上报，刷新只更新快照。
      unawaited(
        _refreshSinks(notifyIfDefaultMissing: action.notifyIfDefaultMissing),
      );
      _emit();
    } else if (action.refresh) {
      unawaited(
        _refreshSinks(notifyIfDefaultMissing: action.notifyIfDefaultMissing),
      );
    }
  }

  Future<void> _refreshSinks({required bool notifyIfDefaultMissing}) async {
    if (_disposed) return;
    final generation = ++_refreshGeneration;
    if (notifyIfDefaultMissing) _notifyOnNextSnapshot = true;

    final idNames = <int, String>{};
    try {
      final list = await Process.run(executable, const [
        'list',
        'short',
        'sinks',
      ]);
      if (list.exitCode != 0) return;
      for (final line in const LineSplitter().convert('${list.stdout}')) {
        final fields = line.split('\t');
        if (fields.length < 2) continue;
        final id = int.tryParse(fields[0].trim());
        final name = fields[1].trim();
        if (id == null || name.isEmpty) continue;
        idNames[id] = name;
      }
    } on ProcessException catch (error) {
      _logFailureOnce(error);
      return;
    } catch (_) {
      return;
    }
    // 旧查询晚到：不覆盖更新的快照；累积的通知由最新查询补发。
    if (_disposed || generation != _refreshGeneration) return;

    final query = await _queryDefaultSink();
    if (_disposed || generation != _refreshGeneration) return;

    final lost = _tracker.applySnapshot(
      PactlSinkSnapshot(
        sinkNamesById: idNames,
        defaultSink: query.name,
        defaultSinkKnown: query.succeeded,
      ),
    );
    final notify = _notifyOnNextSnapshot;
    _notifyOnNextSnapshot = false;
    if (notify && lost) _emit();
  }

  /// `pactl get-default-sink`（PulseAudio 14+ / PipeWire）；旧版本退回解析
  /// `pactl info` 的 `Default Sink:` 行。
  ///
  /// [succeeded] 区分「服务器没有默认 sink」（成功但 name 为 null）与「查询
  /// 失败」：后者必须保留 tracker 里的上一默认值，否则一次瞬时失败就会让本
  /// 会话永久失去输出检测。
  Future<({String? name, bool succeeded})> _queryDefaultSink() async {
    try {
      final direct = await Process.run(executable, const ['get-default-sink']);
      if (direct.exitCode == 0) {
        final name = '${direct.stdout}'.trim();
        return (name: name.isEmpty ? null : name, succeeded: true);
      }
      final info = await Process.run(executable, const ['info']);
      if (info.exitCode != 0) {
        return (name: null, succeeded: false);
      }
      for (final line in const LineSplitter().convert('${info.stdout}')) {
        if (line.startsWith('Default Sink:')) {
          final name = line.substring('Default Sink:'.length).trim();
          return (name: name.isEmpty ? null : name, succeeded: true);
        }
      }
    } on ProcessException catch (error) {
      _logFailureOnce(error);
    } catch (_) {
      // 查询失败不是输出丢失：保持已知默认值，等下一次事件重试。
    }
    return (name: null, succeeded: false);
  }

  void _emit() {
    if (_disposed) return;
    onOutputLost();
  }

  void _onStreamError(Object error) {
    _logFailureOnce(error);
  }

  void _logFailureOnce(Object error) {
    if (_loggedFailure) return;
    _loggedFailure = true;
    // 契约要求静默：只在 fine 级别留一行，用户看不到任何提示。
    debugPrint('[DesktopAudioOutput] pactl 不可用，输出丢失检测停用: $error');
  }
}
