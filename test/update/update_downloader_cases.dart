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

/// 更新下载器：流式写盘、断点续传、重试、sha256 强制校验、旧文件清理。
///
/// 走 path_provider 的平台通道替身（getTemporaryDirectory → 测试临时目录），
/// 不触碰真实设备目录；重试退避统一注入 zero，避免单测真实等待。
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

  /// 206 续传响应：只包含[start, total) 这一段，并带 Content-Range。
  ResponseBody rangeResponse({
    required List<int> bytes,
    required int start,
    required int total,
  }) => ResponseBody(
    Stream.fromIterable([Uint8List.fromList(bytes)]),
    206,
    headers: {
      Headers.contentLengthHeader: ['${bytes.length}'],
      'Content-Range': ['bytes $start-${start + bytes.length - 1}/$total'],
    },
  );

  test('下载成功：写盘 + sha256 校验 + 进度累计', () async {
    final payload = utf8.encode('molia-update-payload' * 8);
    final digest = crypto.sha256.convert(payload).toString();
    final progress = <int>[];

    final downloader = UpdateDownloader(
      dio: createAppDio(
        adapter: MockDioAdapter(
          (_) => streamResponse([payload.sublist(0, 10), payload.sublist(10)]),
        ),
      ),
      retryBaseDelay: Duration.zero,
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

  test('Range 续传成功：Content-Range 偏移校验 + 完整文件 + 全量进度', () async {
    final payload = utf8.encode('molia-resume-payload-' * 32);
    final digest = crypto.sha256.convert(payload).toString();
    final half = payload.length ~/ 2;
    final staging = Directory('${tempDir.path}/updates');
    await staging.create(recursive: true);
    final part = File(
      '${staging.path}/molia-1.2.3-windows-x64.zip.'
      '${digest.substring(0, 8)}.part',
    );
    await part.writeAsBytes(payload.sublist(0, half));

    final progress = <(int, int)>[];
    final adapter = MockDioAdapter((options) {
      expect(options.headers['Range'], 'bytes=$half-');
      return rangeResponse(
        bytes: payload.sublist(half),
        start: half,
        total: payload.length,
      );
    });
    final downloader = UpdateDownloader(
      dio: createAppDio(adapter: adapter),
      retryBaseDelay: Duration.zero,
    );

    final path = await downloader.download(
      url: Uri.parse('https://example.com/molia.zip'),
      targetFileName: 'molia-1.2.3-windows-x64.zip',
      sha256: digest,
      expectedSize: payload.length,
      onProgress: (received, total) => progress.add((received, total)),
    );

    expect(adapter.requests, hasLength(1));
    expect(progress.first, (half, payload.length));
    expect(progress.last, (payload.length, payload.length));
    expect(progress.every((entry) => entry.$2 == payload.length), isTrue);
    expect(await File(path).readAsBytes(), payload);
    expect(await part.exists(), isFalse);
  });

  test('Range 请求返回 200：part 被截断，不保留旧内容', () async {
    final payload = utf8.encode('fresh-payload-after-ignored-range');
    final staging = Directory('${tempDir.path}/updates');
    await staging.create(recursive: true);
    final part = File('${staging.path}/molia.zip.part');
    await part.writeAsString('OLD-PART-DATA');

    final adapter = MockDioAdapter((options) {
      expect(options.headers['Range'], isNotNull);
      return streamResponse([payload]);
    });
    final downloader = UpdateDownloader(
      dio: createAppDio(adapter: adapter),
      retryBaseDelay: Duration.zero,
    );

    final path = await downloader.download(
      url: Uri.parse('https://example.com/molia.zip'),
      targetFileName: 'molia.zip',
      onProgress: (_, _) {},
    );

    expect(await File(path).readAsBytes(), payload);
    expect(await part.exists(), isFalse);
  });

  test('网络第一次失败、第二次成功：请求 2 次、文件完整', () async {
    final payload = utf8.encode('retry-after-network-error');
    var calls = 0;
    final adapter = MockDioAdapter((options) {
      calls++;
      if (calls == 1) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'offline',
        );
      }
      return streamResponse([payload]);
    });
    final downloader = UpdateDownloader(
      dio: createAppDio(adapter: adapter),
      retryBaseDelay: Duration.zero,
    );

    final path = await downloader.download(
      url: Uri.parse('https://example.com/molia.zip'),
      targetFileName: 'molia.zip',
      onProgress: (_, _) {},
    );

    expect(adapter.requests, hasLength(2));
    expect(await File(path).readAsBytes(), payload);
  });

  test('服务器不给 Content-Length：用 expectedSize 作为 total', () async {
    final payload = utf8.encode('expected-size-payload');
    final totals = <int>[];
    final adapter = MockDioAdapter(
      (_) =>
          ResponseBody(Stream.fromIterable([Uint8List.fromList(payload)]), 200),
    );
    final downloader = UpdateDownloader(
      dio: createAppDio(adapter: adapter),
      retryBaseDelay: Duration.zero,
    );

    final path = await downloader.download(
      url: Uri.parse('https://example.com/molia.zip'),
      targetFileName: 'molia.zip',
      expectedSize: payload.length,
      onProgress: (_, total) => totals.add(total),
    );

    expect(totals, isNotEmpty);
    expect(totals, everyElement(payload.length));
    expect(await File(path).readAsBytes(), payload);
  });

  test('sha256 不匹配：删除文件并报校验失败', () async {
    final downloader = UpdateDownloader(
      dio: createAppDio(
        adapter: MockDioAdapter(
          (_) => streamResponse([utf8.encode('corrupted')]),
        ),
      ),
      retryBaseDelay: Duration.zero,
    );

    await expectLater(
      downloader.download(
        url: Uri.parse('https://example.com/molia.apk'),
        targetFileName: 'molia-1.2.3-android-arm64.apk',
        sha256: 'deadbeef',
        onProgress: (_, _) {},
      ),
      throwsA(
        isA<UpdateFailureException>().having(
          (e) => e.kind,
          'kind',
          UpdateFailureKind.checksumMismatch,
        ),
      ),
    );
    final staging = Directory('${tempDir.path}/updates');
    if (await staging.exists()) {
      expect(staging.listSync(), isEmpty);
    }
  });

  test('HTTP 非 200 归一为网络失败（5xx 重试到上限）', () async {
    final adapter = MockDioAdapter(
      (_) => textResponse('nope', statusCode: 502),
    );
    final downloader = UpdateDownloader(
      dio: createAppDio(adapter: adapter),
      retryBaseDelay: Duration.zero,
    );
    await expectLater(
      downloader.download(
        url: Uri.parse('https://example.com/molia.zip'),
        targetFileName: 'molia.zip',
        onProgress: (_, _) {},
      ),
      throwsA(
        isA<UpdateFailureException>().having(
          (e) => e.kind,
          'kind',
          UpdateFailureKind.network,
        ),
      ),
    );
    expect(adapter.requests, hasLength(3));
  });

  test('下载前清掉上次留下的安装包', () async {
    final staging = Directory('${tempDir.path}/updates');
    await staging.create(recursive: true);
    final stale = File('${staging.path}/molia-1.0.0-windows-x64.zip');
    await stale.writeAsString('old');

    final downloader = UpdateDownloader(
      dio: createAppDio(
        adapter: MockDioAdapter((_) => streamResponse([utf8.encode('new')])),
      ),
      retryBaseDelay: Duration.zero,
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
