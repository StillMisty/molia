/// 报告出口动作：复制 / 保存 / 分享、临时文件写入与清理。
///
/// provider 只持有本控制器并转发页面动作；控制器不读 service、不 import 页面。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/diagnostics/diagnostics_bundle.dart';
import '../../services/diagnostics/diagnostics_export.dart';
import '../../services/save_as.dart';
import 'diagnostics_view_models.dart';

typedef DiagnosticsCopyText = Future<void> Function(String text);
typedef DiagnosticsShareFile = Future<void> Function(String path);

/// 分享前的临时文件写入（默认写系统临时目录）；测试可注入内存实现。
typedef DiagnosticsTempFileWriter = Future<String> Function(
  String fileName,
  Uint8List bytes,
);

class DiagnosticsReportController {
  DiagnosticsReportController({
    required this.builder,
    required this.saveAs,
    required this.state,
    this.copyText,
    this.shareFile,
    this.tempDirectory,
    this.writeTempFile,
    this.deleteTempFile,
    this.isDisposed,
  });

  final DiagnosticsBundleBuilder builder;
  final SaveAs saveAs;
  final ValueNotifier<DiagnosticsReportState> state;
  final DiagnosticsCopyText? copyText;
  final DiagnosticsShareFile? shareFile;
  final Future<Directory> Function()? tempDirectory;
  final DiagnosticsTempFileWriter? writeTempFile;
  final Future<void> Function(String path)? deleteTempFile;

  /// provider 释放后异步动作不再写已释放的 notifier。
  final bool Function()? isDisposed;

  Future<String> buildText({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) => builder.buildText(
    screenWidth: screenWidth,
    screenHeight: screenHeight,
    devicePixelRatio: devicePixelRatio,
    maxBytes: maxBytes,
  );

  Future<Uint8List> buildBytes({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
    int maxBytes = defaultDiagnosticsBundleMaxBytes,
  }) => builder.buildBytes(
    screenWidth: screenWidth,
    screenHeight: screenHeight,
    devicePixelRatio: devicePixelRatio,
    maxBytes: maxBytes,
  );

  /// 复制报告：独立小上限（128 KB），只含结论、问题组与日志末尾。
  Future<bool> copyReport({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async {
    if (state.value.busy) return false;
    _setStage(DiagnosticsReportStage.preparing);
    try {
      final text = await buildText(
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        devicePixelRatio: devicePixelRatio,
        maxBytes: diagnosticsCopyMaxBytes,
      );
      return await copyPlainText(text);
    } catch (_) {
      return false;
    } finally {
      _setStage(DiagnosticsReportStage.idle);
    }
  }

  /// 普通文本复制（检查 / 问题详情、日志结果共用同一注入通道）。
  Future<bool> copyPlainText(String text) async {
    try {
      final copy = copyText;
      if (copy != null) {
        await copy(text);
      } else {
        await Clipboard.setData(ClipboardData(text: text));
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 保存完整诊断文件（20 MB 上限沿用导出器）。
  Future<SaveAsResult> saveReport({
    String? dialogTitle,
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async {
    if (state.value.busy) return const SaveAsFailed();
    _setStage(DiagnosticsReportStage.saving);
    try {
      final bytes = await buildBytes(
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        devicePixelRatio: devicePixelRatio,
      );
      return await _saveBytes(bytes, dialogTitle: dialogTitle);
    } catch (error) {
      return SaveAsFailed(error);
    } finally {
      _setStage(DiagnosticsReportStage.idle);
    }
  }

  /// 分享报告：写临时文件后走系统分享；平台不支持文件分享时退化为保存。
  Future<DiagnosticsShareResult> shareReport({
    double? screenWidth,
    double? screenHeight,
    double? devicePixelRatio,
  }) async {
    if (state.value.busy) {
      return const DiagnosticsShareResult(DiagnosticsShareOutcome.failed);
    }
    _setStage(DiagnosticsReportStage.preparing);
    String? tempPath;
    try {
      final bytes = await buildBytes(
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        devicePixelRatio: devicePixelRatio,
      );
      _setStage(DiagnosticsReportStage.sharing);
      final fileName = builder.suggestedFileName();
      tempPath =
          await writeTempFile?.call(fileName, bytes) ??
          await _writeDefaultTempFile(fileName, bytes);
      try {
        final share = shareFile;
        if (share != null) {
          await share(tempPath);
        } else {
          await SharePlus.instance.share(ShareParams(files: [XFile(tempPath)]));
        }
        return const DiagnosticsShareResult(DiagnosticsShareOutcome.shared);
      } catch (_) {
        final saved = await _saveBytes(bytes, dialogTitle: null);
        return DiagnosticsShareResult(
          DiagnosticsShareOutcome.savedFallback,
          saved: saved,
        );
      }
    } catch (_) {
      return const DiagnosticsShareResult(DiagnosticsShareOutcome.failed);
    } finally {
      if (tempPath != null) await deleteTempFileAt(tempPath);
      _setStage(DiagnosticsReportStage.idle);
    }
  }

  Future<String> _writeDefaultTempFile(String fileName, Uint8List bytes) async {
    final directory = await (tempDirectory?.call() ?? getTemporaryDirectory());
    final file = File(p.join(directory.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> deleteTempFileAt(String path) async {
    try {
      final delete = deleteTempFile;
      if (delete != null) {
        await delete(path);
        return;
      }
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 清理是 best-effort：分享已完成，临时文件残留不阻塞用户。
    }
  }

  Future<SaveAsResult> _saveBytes(
    Uint8List bytes, {
    String? dialogTitle,
  }) async {
    try {
      return await saveAs.saveBytes(
        fileName: builder.suggestedFileName(),
        bytes: bytes,
        mimeType: 'text/plain',
        relativeDir: saveAsExportsDirName,
        dialogTitle: dialogTitle,
      );
    } catch (error) {
      return SaveAsFailed(error);
    }
  }

  void _setStage(DiagnosticsReportStage stage) {
    if (isDisposed?.call() ?? false) return;
    if (state.value.stage == stage) return;
    state.value = DiagnosticsReportState(stage: stage);
  }
}
