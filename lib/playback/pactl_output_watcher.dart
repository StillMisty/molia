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
  final Map<int, String> _sinkNames = <int, String>{};
  String? _defaultSink;
  bool _disposed = false;
  bool _loggedFailure = false;

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
    switch (event.facility) {
      case 'server':
        // 默认 sink 切换 / 服务器状态变化：刷新快照；若旧默认 sink 已不在
        // 列表里（部分服务器先发 change 再发 remove），按输出丢失处理。
        if (event.kind == PactlEventKind.changed ||
            event.kind == PactlEventKind.added) {
          unawaited(_refreshSinks(notifyIfDefaultMissing: true));
        }
      case 'sink':
        if (event.kind == PactlEventKind.removed) {
          final removedName = event.id == null ? null : _sinkNames[event.id];
          final wasDefault = removedName != null && removedName == _defaultSink;
          // 已知是默认 sink 时只刷新快照（避免同一事件重复上报）；id 不在表里
          // 时才靠「旧默认名已从列表消失」兜底判断。
          unawaited(_refreshSinks(notifyIfDefaultMissing: !wasDefault));
          if (wasDefault) _emit();
        } else if (event.kind == PactlEventKind.added ||
            event.kind == PactlEventKind.changed) {
          // 新增 / 变化只刷新 id→name 与默认值，不暂停：用户可能只是主动
          // 切换输出。
          unawaited(_refreshSinks(notifyIfDefaultMissing: false));
        }
      default:
        // source / sink-input / client / card 等与播放输出无关。
        break;
    }
  }

  Future<void> _refreshSinks({required bool notifyIfDefaultMissing}) async {
    if (_disposed) return;
    final previousDefault = _defaultSink;
    final names = <String>{};
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
        names.add(name);
      }
    } on ProcessException catch (error) {
      _logFailureOnce(error);
      return;
    } catch (_) {
      return;
    }
    if (_disposed) return;
    final currentDefault = await _queryDefaultSink();
    if (_disposed) return;
    _sinkNames
      ..clear()
      ..addAll(idNames);
    _defaultSink = currentDefault;
    final disappeared =
        previousDefault != null &&
        previousDefault.isNotEmpty &&
        !names.contains(previousDefault);
    if (notifyIfDefaultMissing && disappeared) _emit();
  }

  /// `pactl get-default-sink`（PulseAudio 14+ / PipeWire）；旧版本退回解析
  /// `pactl info` 的 `Default Sink:` 行。
  Future<String?> _queryDefaultSink() async {
    try {
      final direct = await Process.run(executable, const ['get-default-sink']);
      if (direct.exitCode == 0) {
        final name = '${direct.stdout}'.trim();
        return name.isEmpty ? null : name;
      }
      final info = await Process.run(executable, const ['info']);
      if (info.exitCode != 0) return null;
      for (final line in const LineSplitter().convert('${info.stdout}')) {
        if (line.startsWith('Default Sink:')) {
          final name = line.substring('Default Sink:'.length).trim();
          return name.isEmpty ? null : name;
        }
      }
    } on ProcessException catch (error) {
      _logFailureOnce(error);
    } catch (_) {
      // 查询失败不是输出丢失：保持已知默认值，等下一次事件重试。
    }
    return null;
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
