/// 日志子页动作：有界尾部读取、刷新与目录定位。
///
/// provider 只持有本控制器并转发；日志文件只在用户打开子页或主动刷新时读取。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../services/diagnostics/log_tail_reader.dart';
import '../../services/save_as.dart';
import 'diagnostics_view_models.dart';

class DiagnosticsLogController {
  DiagnosticsLogController({
    required this.state,
    required this.saveAs,
    this.reader,
    DateTime Function()? now,
    this.isDisposed,
  }) : _now = now ?? DateTime.now;

  final ValueNotifier<DiagnosticsLogsState> state;
  final SaveAs saveAs;
  final LogTailReader? reader;
  final DateTime Function() _now;
  final bool Function()? isDisposed;
  bool _reading = false;

  /// 打开日志子页时读取一次；已加载 / 正在加载时不重复读盘。
  Future<void> loadLogs() async {
    final current = state.value;
    if (_reading ||
        current.status == DiagnosticsLogsStatus.ready ||
        current.status == DiagnosticsLogsStatus.unavailable) {
      return;
    }
    await _read();
  }

  /// 用户主动刷新：总是重新读取。
  Future<void> refreshLogs() => _read();

  Future<String?> logDirectoryPath() async {
    try {
      return (await reader?.directory())?.path;
    } catch (_) {
      return null;
    }
  }

  /// 打开日志目录（用另存服务的定位入口）；不可用时返回 false。
  Future<bool> revealLogDirectory() async {
    final path = await logDirectoryPath();
    if (path == null || path.isEmpty) return false;
    try {
      return await saveAs.reveal(path);
    } catch (_) {
      return false;
    }
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    final current = state.value;
    _setState(
      DiagnosticsLogsState(
        status: DiagnosticsLogsStatus.loading,
        logStatus: current.logStatus,
        entries: current.entries,
        loadedAt: current.loadedAt,
      ),
    );
    try {
      final source = reader;
      if (source == null) {
        _setState(
          DiagnosticsLogsState(
            status: DiagnosticsLogsStatus.unavailable,
            logStatus: state.value.logStatus,
          ),
        );
        return;
      }
      final directory = await _directoryOf(source);
      if (directory == null) {
        _setState(
          DiagnosticsLogsState(
            status: DiagnosticsLogsStatus.unavailable,
            logStatus: state.value.logStatus,
          ),
        );
        return;
      }
      final entries = await source.read();
      _setState(
        DiagnosticsLogsState(
          status: DiagnosticsLogsStatus.ready,
          logStatus: state.value.logStatus,
          entries: entries,
          loadedAt: _now(),
        ),
      );
    } catch (_) {
      _setState(
        DiagnosticsLogsState(
          status: DiagnosticsLogsStatus.failed,
          logStatus: state.value.logStatus,
        ),
      );
    } finally {
      _reading = false;
    }
  }

  Future<Directory?> _directoryOf(LogTailReader reader) async {
    try {
      return await reader.directory();
    } catch (_) {
      return null;
    }
  }

  void _setState(DiagnosticsLogsState next) {
    if (isDisposed?.call() ?? false) return;
    state.value = next;
  }
}
