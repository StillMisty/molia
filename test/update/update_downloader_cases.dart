import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/http/app_dio.dart';
import 'package:molia/data/update/update_downloader.dart';
import 'package:molia/domain/models/app_release.dart';

import '../support/mock_dio.dart';

/// 更新下载器：流式写盘、进度回调、sha256 强制校验、旧文件清理。
///
/// 走 path_provider 的平台通道替身（getTemporaryDirectory → 测试临时目录），
/// 不触碰真实设备目录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('molia-download-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return tempDir.path;
      return null;
    });
    addTearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProviderChannel, null);
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });
  });

  /// 分块流式响应（带 Content-Length）。
  ResponseBody streamResponse(List<List<int>> chunks) => ResponseBody(
        Stream.fromIterable(chunks.map(Uint8List.fromList)),
        200,
        headers: {
          Headers.contentLengthHeader: [
            '${chunks.fold<int>(0, (sum, chunk) => sum + chunk.length)}',
          ],
        },
      );

  test('下载成功：写盘 + sha256 校验 + 进度累计', () async {
    final payload = utf8.encode('molia-update-payload' * 8);
    final digest = crypto.sha256.convert(payload).toString();
    final progress = <int>[];

    final downloader = UpdateDownloader(
      dio: createAppDio(
        adapter: MockDioAdapter(
          (_) => streamResponse([
            payload.sublist(0, 10),
            payload.sublist(10),
          ]),
        ),
      ),
    );

    final path = await downloader.download(
      url: Uri.parse('https://example.com/molia.zip'),
      targetFileName: 'molia-1.2.3-windows-x64.zip',
      sha256: digest,
      onProgress: (received, total) => progress.add(received),
    );

    final file = File(path);
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), payload);
    expect(progress, [10, payload.length]);
  });

  test('sha256 不匹配：删除文件并报校验失败', () async {
    final downloader = UpdateDownloader(
      dio: createAppDio(
        adapter: MockDioAdapter((_) => streamResponse([
              utf8.encode('corrupted'),
            ])),
      ),
    );

    await expectLater(
      downloader.download(
        url: Uri.parse('https://example.com/molia.apk'),
        targetFileName: 'molia-1.2.3-android-arm64.apk',
        sha256: 'deadbeef',
        onProgress: (_, _) {},
      ),
      throwsA(isA<UpdateFailureException>().having(
        (e) => e.kind,
        'kind',
        UpdateFailureKind.checksumMismatch,
      )),
    );
    final staging = Directory('${tempDir.path}/updates');
    if (await staging.exists()) {
      expect(staging.listSync(), isEmpty);
    }
  });

  test('HTTP 非 200 归一为网络失败', () async {
    final downloader = UpdateDownloader(
      dio: createAppDio(
        adapter: MockDioAdapter(
          (_) => textResponse('nope', statusCode: 502),
        ),
      ),
    );
    await expectLater(
      downloader.download(
        url: Uri.parse('https://example.com/molia.zip'),
        targetFileName: 'molia.zip',
        onProgress: (_, _) {},
      ),
      throwsA(isA<UpdateFailureException>().having(
        (e) => e.kind,
        'kind',
        UpdateFailureKind.network,
      )),
    );
  });

  test('下载前清掉上次留下的安装包', () async {
    final staging = Directory('${tempDir.path}/updates');
    await staging.create(recursive: true);
    final stale = File('${staging.path}/molia-1.0.0-windows-x64.zip');
    await stale.writeAsString('old');

    final downloader = UpdateDownloader(
      dio: createAppDio(
        adapter: MockDioAdapter((_) => streamResponse([
              utf8.encode('new'),
            ])),
      ),
    );
    final path = await downloader.download(
      url: Uri.parse('https://example.com/molia.zip'),
      targetFileName: 'molia-1.2.3-windows-x64.zip',
      onProgress: (_, _) {},
    );

    expect(await stale.exists(), isFalse);
    expect(await File(path).readAsString(), 'new');
  });
}
