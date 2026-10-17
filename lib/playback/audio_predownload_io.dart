import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../data/http/app_dio.dart';
import '../services/cache_service.dart';
import 'audio_predownload_task.dart';

/// 共享 Dio：预取请求每个任务一个 `CancelToken` 取消，避免每任务新建 /
/// 关闭客户端（`dio.close(force: true)` 取消会让下一条预取重建连接池与
/// TLS 会话）。
Dio? _sharedDio;
Dio _dio() => _sharedDio ??= createAppDio();

/// 启动预取；目标已缓存时返回 null。
AudioPredownloadTask? startAudioPredownload({
  required Uri uri,
  required String targetPath,
}) {
  // 已有完整缓存文件：边播边缓存会直接命中，无需重复下载。
  if (File(targetPath).existsSync()) return null;

  // 半成品用独立后缀：just_audio 的 LockCachingAudioSource 使用
  // `audioCachePartSuffix`，两边不能共用同一路径（取消清理会误删对方正在写的文件）。
  final partFile = File('$targetPath$audioCachePredownloadSuffix');
  final dio = _dio();
  final cancelToken = CancelToken();
  final completer = Completer<void>();
  var cancelled = false;

  Future<void> run() async {
    IOSink? sink;
    try {
      final response = await dio.requestUri<dynamic>(
        uri,
        cancelToken: cancelToken,
        options: Options(method: 'GET', responseType: ResponseType.stream),
      );
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw HttpException('HTTP $status');
      }
      await partFile.parent.create(recursive: true);
      sink = partFile.openWrite();
      await for (final chunk in streamBody(response).stream) {
        if (cancelled) break;
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (cancelled) {
        await _deleteQuietly(partFile);
      } else {
        // 原子落位：播放侧只认最终文件名，不会读到半成品。
        await partFile.rename(targetPath);
      }
    } catch (_) {
      // 失败/取消静默：清理半成品，真正播放时正常取链流播。
      try {
        await sink?.close();
      } catch (_) {}
      await _deleteQuietly(partFile);
    } finally {
      if (!completer.isCompleted) completer.complete();
    }
  }

  unawaited(run());
  return AudioPredownloadTask(
    done: completer.future,
    onCancel: () {
      cancelled = true;
      cancelToken.cancel();
    },
  );
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
