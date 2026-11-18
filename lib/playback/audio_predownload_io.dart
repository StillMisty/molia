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

/// 正在被预取写入的最终缓存路径。
///
/// 同一路径同时只允许一个预取 writer：取消是异步的（CancelToken + 流循环
/// 里才看到标志），紧接着为同一曲目再起一份会在同一个 `.predl` 上双写，
/// 先结束的一方还会把另一方正在写的半成品删掉。
final Set<String> _activeTargets = {};

/// 启动预取；目标已缓存时返回 null。
///
/// [headers] 为 null / 空时不设置请求头（Dio 默认 UA 即可）。
AudioPredownloadTask? startAudioPredownload({
  required Uri uri,
  required String targetPath,
  Map<String, String>? headers,
}) {
  // 已有完整缓存文件：边播边缓存会直接命中，无需重复下载。
  if (File(targetPath).existsSync()) return null;
  // 同一路径已有在途预取：让现有 writer 写完，不并行写同一份半成品。
  if (!_activeTargets.add(targetPath)) return null;

  // 半成品用独立后缀：just_audio 的 LockCachingAudioSource 使用
  // `audioCachePartSuffix`，两边不能共用同一路径（取消清理会误删对方正在写的文件）。
  final partFile = File('$targetPath$audioCachePredownloadSuffix');
  final dio = _dio();
  final cancelToken = CancelToken();
  final completer = Completer<void>();
  final success = Completer<bool>();
  var cancelled = false;

  Future<void> run() async {
    IOSink? sink;
    try {
      final response = await dio.requestUri<dynamic>(
        uri,
        cancelToken: cancelToken,
        options: Options(
          method: 'GET',
          responseType: ResponseType.stream,
          headers: (headers == null || headers.isEmpty) ? null : headers,
        ),
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
      if (cancelled || !_canLand(targetPath)) {
        await _deleteQuietly(partFile);
      } else {
        // 原子落位：播放侧只认最终文件名，不会读到半成品。落位后再确认
        // 最终文件存在，成功信号只有在文件真的可播时才为 true。
        await partFile.rename(targetPath);
        if (await File(targetPath).exists()) {
          if (!success.isCompleted) success.complete(true);
        }
      }
    } catch (_) {
      // 失败/取消静默：清理半成品，真正播放时正常取链流播。
      try {
        await sink?.close();
      } catch (_) {}
      await _deleteQuietly(partFile);
    } finally {
      _activeTargets.remove(targetPath);
      if (!success.isCompleted) success.complete(false);
      if (!completer.isCompleted) completer.complete();
    }
  }

  unawaited(run());
  return AudioPredownloadTask(
    done: completer.future,
    succeeded: success.future,
    onCancel: () {
      cancelled = true;
      cancelToken.cancel();
    },
  );
}

/// 落位前复查：下载期间同一路径可能已经被别人（边播边缓存的 writer）接手，
/// 此时再 rename 会与 `.part` 并存、甚至覆盖刚写好的完整缓存（issue #60）。
bool _canLand(String targetPath) {
  if (File(targetPath).existsSync()) return false;
  if (File('$targetPath$audioCachePartSuffix').existsSync()) return false;
  return true;
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (_) {}
}
