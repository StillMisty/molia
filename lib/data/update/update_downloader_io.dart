import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/app_release.dart';
import '../http/app_dio.dart';

/// 更新产物下载器（原生实现）：流式写盘 + 进度回调 + sha256 强制校验。
///
/// 设计要点：
/// - 走 dio 的 `ResponseType.stream`：APK/压缩包几十 MB，不整块进内存；
/// - 下载目录固定在临时目录的 `updates/`（Android 与 FileProvider 的
///   `cache-path name="updates"` 对齐，系统安装器需要可授予读取的路径），
///   每次下载前清掉旧安装包，避免多版本堆积；
/// - 清单给了 sha256 就必须校验（失败删除文件并报错）；
/// - 取消（用户点「取消下载」）异常原样抛出，由 provider 区分取消与失败。
class UpdateDownloader {
  UpdateDownloader({Dio? dio}) : _dio = dio ?? createAppDio();

  final Dio _dio;

  /// 下载 [url] 到临时目录下的 [targetFileName]，返回写好的文件路径。
  ///
  /// [onProgress] 的 `total` 在拿不到 Content-Length 时为 -1。
  Future<String> download({
    required Uri url,
    required String targetFileName,
    String? sha256,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await _stagingDirectory();
    await dir.create(recursive: true);
    await clearStaleFiles();
    final target = File(p.join(dir.path, p.basename(targetFileName)));

    final Response<ResponseBody> response;
    try {
      response = await _dio.getUri<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      throw UpdateFailureException(
        UpdateFailureKind.network,
        '下载失败: ${e.type} ${e.message}',
      );
    }
    if (response.httpStatus != 200) {
      throw UpdateFailureException(
        UpdateFailureKind.network,
        '下载返回 HTTP ${response.httpStatus}',
      );
    }

    final body = streamBody(response);
    final contentLength = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '',
        ) ??
        -1;

    final sink = target.openWrite();
    var sinkClosed = false;
    Future<void> closeSink() async {
      if (sinkClosed) return;
      sinkClosed = true;
      try {
        await sink.flush();
      } catch (_) {
        // flush 失败由后续校验兜底：文件一定不完整。
      }
      try {
        await sink.close();
      } catch (_) {}
    }

    final digestSink = _DigestSink();
    final hasher = sha256 == null
        ? null
        : crypto.sha256.startChunkedConversion(digestSink);
    var received = 0;

    try {
      await for (final chunk in body.stream) {
        sink.add(chunk);
        hasher?.add(chunk);
        received += chunk.length;
        onProgress(received, contentLength);
      }
      await closeSink();

      if (hasher != null && sha256 != null) {
        hasher.close();
        final actual = digestSink.value?.toString().toLowerCase();
        if (actual != sha256.toLowerCase()) {
          await _deleteQuietly(target);
          throw UpdateFailureException(
            UpdateFailureKind.checksumMismatch,
            'sha256 校验失败：期望 $sha256，实际 $actual',
          );
        }
      }
      return target.path;
    } catch (e) {
      await closeSink();
      await _deleteQuietly(target);
      if (e is UpdateFailureException) rethrow;
      if (e is DioException && CancelToken.isCancel(e)) rethrow;
      throw UpdateFailureException(UpdateFailureKind.network, '下载中断: $e');
    }
  }

  /// 清掉上次留下的安装包（同一临时目录只保留本次下载）。
  Future<void> clearStaleFiles() async {
    try {
      final dir = await _stagingDirectory();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        await _deleteQuietly(entity);
      }
    } catch (_) {
      // 清理失败不阻断下载。
    }
  }

  Future<Directory> _stagingDirectory() async {
    final temp = await getTemporaryDirectory();
    return Directory(p.join(temp.path, 'updates'));
  }

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) await entity.delete(recursive: true);
    } catch (_) {
      // 删不掉残留文件不影响结果：下次下载会覆盖。
    }
  }
}

/// crypto 的分块哈希输出（`Sink<Digest>`）单值捕获。
class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
