/// 诊断栈：文件日志 sink + 最近失败缓冲（组合根在 catalog / playback 之前
/// 构造；构造无 I/O、无 await）。
///
/// 健康检查器依赖目录服务，catalog 建好后由组合根 `attachHealth` 挂上；
/// 导出器依赖设置 / 渠道 / 数据库 / 更新栈，最后在 runApp 前组装。
library;

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../data/files/app_data_directory.dart';
import '../../services/diagnostics/diagnostics_service.dart';
import '../../services/diagnostics/failure_ring_buffer.dart';
import '../../services/diagnostics/log_file_sink.dart';

typedef DiagnosticsStack = ({
  DiagnosticsService service,
  FailureRingBuffer failures,
  RotatingFileLogSink logSink,
});

/// 构造诊断核心并挂上 `package:logging` 的文件监听。
///
/// 控制台 handler 不变；文件 sink 失败只影响落盘，不影响启动 / 播放。
DiagnosticsStack buildDiagnosticsStack() {
  final failures = FailureRingBuffer();
  final sink = RotatingFileLogSink(
    directory: () async {
      final data = await appDataDirectory();
      return Directory(p.join(data.path, 'logs'));
    },
  );
  sink.attach(Logger.root.onRecord);
  final service = DiagnosticsService(failures: failures, logSink: sink);
  return (service: service, failures: failures, logSink: sink);
}
