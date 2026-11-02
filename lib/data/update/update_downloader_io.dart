import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../domain/models/app_release.dart';
import '../http/app_dio.dart';

/// 更新产物下载器：流式写盘 + 断点续传 + 重试 + sha256 强制校验。
///
/// 设计要点：
/// - 走 dio 的 `ResponseType.stream`：APK/压缩包几十 MB，不整块进内存；
/// - 下载目录固定在临时目录的 `updates/`（Android 与 FileProvider 的
///   `cache-path name="updates"` 对齐，系统安装器需要可授予读取的路径）；
/// - 半成品用 `<target>.<sha8>.part`：同一产物续传时能找到上次的 part，
///   sha 不同（换版本 / 换渠道）则自然落到另一个文件名；
/// - 清单给了 sha256 就必须校验（失败删除 part 并报错）；
/// - 取消（用户点「取消下载」）异常原样抛出，由 provider 区分取消与失败。
class UpdateDownloader {
  UpdateDownloader({
    Dio? dio,
    this._retryBaseDelay = const Duration(seconds: 1),
  }) : _dio = dio ?? createAppDio();

  /// 含首次在内的最大尝试次数。
  static const int _maxAttempts = 3;

  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _receiveTimeout = Duration(seconds: 30);

  final Dio _dio;

  /// 退避基准：第 1 次重试等 1 个基准、第 2 次等 2 个基准（测试注入 zero）。
  final Duration _retryBaseDelay;

  /// 下载 [url] 到临时目录下的 [targetFileName]，返回写好的文件路径。
  ///
  /// [expectedSize] 来自清单产物大小：服务器不给 Content-Length 时用它做
  /// 进度总量；没有 sha 时也用它兜底校验最终文件长度。
  /// [onProgress] 的 `received` 始终是含已续传字节的全量，`total` 在拿不到
  /// 总大小时为 -1。
  Future<String> download({
    required Uri url,
    required String targetFileName,
    String? sha256,
    int? expectedSize,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await _stagingDirectory();
    await dir.create(recursive: true);
    final targetName = p.basename(targetFileName);
    final target = File(p.join(dir.path, targetName));
    final sha = _normalizeSha(sha256);
    final part = File(p.join(dir.path, _partFileName(targetName, sha)));

    // 只保留当前 part：旧 part / 旧完整包都不参与本次下载，避免把别的
    // 版本（或不同 sha）的字节续到当前文件里。
    await _clearStaleFilesExcept(part.path);

    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        await _downloadAttempt(
          url: url,
          part: part,
          expectedSize: expectedSize,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
        return await _verifyAndCommit(
          target: target,
          part: part,
          sha256: sha,
          expectedSize: expectedSize,
        );
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          await _deleteQuietly(part);
          rethrow;
        }
        if (attempt >= _maxAttempts) {
          throw UpdateFailureException(
            UpdateFailureKind.network,
            '下载失败: ${e.type} ${e.message}',
          );
        }
        await _waitBeforeRetry(attempt, url, part, cancelToken);
      } on _RetryableDownloadFailure catch (e) {
        if (attempt >= _maxAttempts) {
          throw UpdateFailureException(UpdateFailureKind.network, e.message);
        }
        await _waitBeforeRetry(attempt, url, part, cancelToken);
      } on UpdateFailureException {
        // 4xx / 校验失败等确定性失败：不重试，原样交给调用方。
        rethrow;
      } catch (e) {
        if (attempt >= _maxAttempts) {
          throw UpdateFailureException(UpdateFailureKind.network, '下载中断: $e');
        }
        await _waitBeforeRetry(attempt, url, part, cancelToken);
      }
    }
    throw const UpdateFailureException(UpdateFailureKind.network, '下载重试次数耗尽');
  }

  /// 清掉上次留下的安装包（同一临时目录只保留本次下载）。
  Future<void> clearStaleFiles() => _clearStaleFilesExcept(null);

  /// 单次尝试：构造 Range、处理 200 / 206 / 416 / 5xx，流式写 part。
  ///
  /// 网络 / 流中断只保留 part 并抛可重试失败；取消会删 part 后原样抛出。
  Future<void> _downloadAttempt({
    required Uri url,
    required File part,
    required int? expectedSize,
    required void Function(int received, int total) onProgress,
    required CancelToken? cancelToken,
  }) async {
    final partSize = await _fileLength(part);
    final requestHeaders = <String, Object?>{};
    if (partSize > 0) {
      requestHeaders['Range'] = 'bytes=$partSize-';
    }

    final response = await _dio.getUri<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: requestHeaders,
        connectTimeout: _connectTimeout,
        receiveTimeout: _receiveTimeout,
      ),
      cancelToken: cancelToken,
    );

    final status = response.httpStatus;
    final contentLength = _contentLength(response.headers);
    final resume = status == 206;

    if (status == 416) {
      // part 与服务端当前资源对不上（例如发布被替换成更小的文件）：
      // 删掉后从零重来，比继续拼一个错误文件安全。
      await _deleteQuietly(part);
      throw const _RetryableDownloadFailure('服务器拒绝续传（HTTP 416）');
    }
    if (status >= 500) {
      throw _RetryableDownloadFailure('下载返回 HTTP $status');
    }
    if (status < 200 || status >= 300) {
      // 4xx / 3xx 重试通常没有意义；part 保留，下次用户手动重试仍可续传。
      throw UpdateFailureException(
        UpdateFailureKind.network,
        '下载返回 HTTP $status',
      );
    }
    if (status != 200 && status != 206) {
      throw UpdateFailureException(
        UpdateFailureKind.network,
        '下载返回 HTTP $status',
      );
    }

    final range = resume
        ? _ContentRange.parse(response.headers.value('content-range') ?? '')
        : null;
    if (resume && (range == null || range.start != partSize)) {
      // 追加到错误偏移会把文件写坏：删 part 后下一次走整包下载。
      await _deleteQuietly(part);
      throw const _RetryableDownloadFailure('Content-Range 与本地续传位置不一致');
    }

    final total = _resolveTotal(
      resume: resume,
      range: range,
      partSize: partSize,
      contentLength: contentLength,
      expectedSize: expectedSize,
    );

    final sink = part.openWrite(
      mode: resume ? FileMode.append : FileMode.write,
    );
    var sinkClosed = false;
    Future<void> closeSink() async {
      if (sinkClosed) return;
      sinkClosed = true;
      try {
        await sink.flush();
      } catch (_) {
        // flush 失败由长度 / sha 校验兜底：文件一定不完整。
      }
      try {
        await sink.close();
      } catch (_) {}
    }

    var received = resume ? partSize : 0;
    try {
      // 续传时先告诉调用方「已有多少 / 总共多少」，避免进度条从 0 重新跳。
      if (resume && partSize > 0) onProgress(received, total);
      await for (final chunk in streamBody(response).stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await closeSink();
    } on DioException catch (e) {
      await closeSink();
      if (CancelToken.isCancel(e)) {
        await _deleteQuietly(part);
        rethrow;
      }
      // 网络中断：保留 part，下一次尝试接着 Range 续传。
      throw _RetryableDownloadFailure('下载中断: ${e.type} ${e.message}');
    } catch (e) {
      await closeSink();
      // 流中断 / 写盘失败：保留已写下的 part，下一步仍可续传。
      throw _RetryableDownloadFailure('下载中断: $e');
    }
  }

  /// 完整文件校验（流式 sha）后落盘：先删旧 target，再 rename part。
  Future<String> _verifyAndCommit({
    required File target,
    required File part,
    required String? sha256,
    required int? expectedSize,
  }) async {
    if (sha256 != null) {
      final actual = (await crypto.sha256.bind(part.openRead()).first)
          .toString()
          .toLowerCase();
      if (actual != sha256) {
        await _deleteQuietly(part);
        throw UpdateFailureException(
          UpdateFailureKind.checksumMismatch,
          'sha256 校验失败：期望 $sha256，实际 $actual',
        );
      }
    } else if (expectedSize != null) {
      final actual = await part.length();
      if (actual != expectedSize) {
        // 没有 sha 时，清单里的大小是最后一道完整性兜底。
        await _deleteQuietly(part);
        throw UpdateFailureException(
          UpdateFailureKind.network,
          '下载长度不符：期望 $expectedSize，实际 $actual',
        );
      }
    }

    await _deleteQuietly(target);
    await part.rename(target.path);
    return target.path;
  }

  Future<void> _waitBeforeRetry(
    int attempt,
    Uri url,
    File part,
    CancelToken? cancelToken,
  ) async {
    if (cancelToken?.isCancelled ?? false) {
      await _deleteQuietly(part);
      throw DioException(
        requestOptions: RequestOptions(path: url.toString()),
        type: DioExceptionType.cancel,
        error: '用户取消下载',
      );
    }
    final delay = _retryBaseDelay * attempt;
    if (delay <= Duration.zero) return;
    final cancelFuture = cancelToken?.whenCancel;
    if (cancelFuture == null) {
      await Future<void>.delayed(delay);
      return;
    }
    // 退避期间取消不必等满 1s / 2s：与等待赛跑，取消立刻删 part 并抛出。
    final result = await Future.any<Object?>([
      Future<void>.delayed(delay),
      cancelFuture,
    ]);
    if (result is DioException && CancelToken.isCancel(result)) {
      await _deleteQuietly(part);
      throw result;
    }
  }

  int _resolveTotal({
    required bool resume,
    required _ContentRange? range,
    required int partSize,
    required int? contentLength,
    required int? expectedSize,
  }) {
    if (resume && range?.total != null) return range!.total!;
    if (expectedSize != null && expectedSize > 0) return expectedSize;
    if (contentLength != null && contentLength > 0) {
      // 206 的 Content-Length 只是本次续传分片；200 则是整包长度，
      // 此时即使本地有旧 part 也会被截断，不能把旧长度加进去。
      return resume ? partSize + contentLength : contentLength;
    }
    return -1;
  }

  int? _contentLength(Headers headers) {
    final value = int.tryParse(
      headers.value(Headers.contentLengthHeader) ?? '',
    );
    return value != null && value >= 0 ? value : null;
  }

  Future<int> _fileLength(File file) async {
    try {
      return await file.exists() ? await file.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  String? _normalizeSha(String? sha256) {
    final value = sha256?.trim().toLowerCase();
    return value == null || value.isEmpty ? null : value;
  }

  String _partFileName(String targetName, String? sha256) {
    if (sha256 == null) return '$targetName.part';
    final sha8 = sha256.length > 8 ? sha256.substring(0, 8) : sha256;
    return '$targetName.$sha8.part';
  }

  /// 清理暂存目录，只保留 [keepPath]（当前 part）；null 表示全部删除。
  Future<void> _clearStaleFilesExcept(String? keepPath) async {
    try {
      final dir = await _stagingDirectory();
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (keepPath != null && p.equals(entity.path, keepPath)) continue;
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

/// Content-Range 的起始偏移与总大小（`bytes 100-199/200`；`*` 表示未知）。
class _ContentRange {
  const _ContentRange({required this.start, required this.total});

  final int start;
  final int? total;

  static _ContentRange? parse(String value) {
    final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$')
        .firstMatch(value.trim());
    if (match == null) return null;
    return _ContentRange(
      start: int.parse(match.group(1)!),
      total: match.group(3) == '*' ? null : int.parse(match.group(3)!),
    );
  }
}

/// 可重试的下载失败（5xx / 流中断 / Range 协议错等）。
class _RetryableDownloadFailure implements Exception {
  const _RetryableDownloadFailure(this.message);

  final String message;

  @override
  String toString() => '_RetryableDownloadFailure($message)';
}
