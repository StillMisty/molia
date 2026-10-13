import 'package:dio/dio.dart';

import '../../domain/models/app_release.dart';

/// Web 端的下载器占位：应用内更新在 Web 不可用（走刷新页面拿新版本）。
///
/// 构造参数与原生实现保持同签名（测试在 VM 上编译到 io 实现，分析器按
/// 条件导出的默认分支解析，签名不一致会报参数错误）。
class UpdateDownloader {
  const UpdateDownloader({Dio? dio});

  Future<String> download({
    required Uri url,
    required String targetFileName,
    String? sha256,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    throw const UpdateFailureException(
      UpdateFailureKind.unsupported,
      'Web 端不支持下载安装包',
    );
  }

  Future<void> clearStaleFiles() async {}
}
