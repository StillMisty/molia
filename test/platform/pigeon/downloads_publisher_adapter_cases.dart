import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/downloads_publisher_io.dart';
import 'package:molia/data/downloads/downloads_publisher_types.dart';
import 'package:molia/platform/pigeon/downloads_publisher_adapter.dart';

/// 假 Pigeon host：覆盖成功、null、异常与非 Android 分支。
class _FakeHostApi implements DownloadsPublisherHostApi {
  String? publicRootResult;
  String? publishResult;
  bool removeResult = false;
  bool throwOnPublicRoot = false;
  bool throwOnPublish = false;
  bool throwOnRemove = false;

  int publicRootCalls = 0;
  int publishCalls = 0;
  int removeCalls = 0;

  String? lastSourcePath;
  String? lastDisplayName;
  String? lastMimeType;
  String? lastRelativeDir;
  String? lastRemoveUri;

  @override
  Future<String?> publicRoot() async {
    publicRootCalls++;
    if (throwOnPublicRoot) throw StateError('pigeon root failed');
    return publicRootResult;
  }

  @override
  Future<String?> publish(
    String sourcePath,
    String displayName,
    String mimeType,
    String relativeDir,
  ) async {
    publishCalls++;
    lastSourcePath = sourcePath;
    lastDisplayName = displayName;
    lastMimeType = mimeType;
    lastRelativeDir = relativeDir;
    if (throwOnPublish) throw StateError('pigeon publish failed');
    return publishResult;
  }

  @override
  Future<bool> remove(String uri) async {
    removeCalls++;
    lastRemoveUri = uri;
    if (throwOnRemove) throw StateError('pigeon remove failed');
    return removeResult;
  }
}

/// 旧通道 fallback 的假实现。
class _FakeFallbackPublisher implements DownloadsPublisher {
  String? publicRootResult;
  String? publishResult;
  bool removeResult = false;

  int publicRootCalls = 0;
  int publishCalls = 0;
  int removeCalls = 0;

  @override
  bool get supported => true;

  @override
  Future<String?> publicRoot() async {
    publicRootCalls++;
    return publicRootResult;
  }

  @override
  Future<String?> publish({
    required String sourcePath,
    required String displayName,
    required String mimeType,
    String relativeDir = '',
  }) async {
    publishCalls++;
    return publishResult;
  }

  @override
  Future<bool> remove(String uri) async {
    removeCalls++;
    return removeResult;
  }
}

void main() {
  group('PigeonDownloadsPublisherAdapter', () {
    test('Android 成功路径：参数原样传给生成 API', () async {
      final host = _FakeHostApi()
        ..publicRootResult = '/storage/emulated/0/Download/Molia'
        ..publishResult = 'content://media/external/downloads/1'
        ..removeResult = true;
      final adapter = PigeonDownloadsPublisherAdapter(
        api: host,
        isAndroid: true,
      );

      expect(adapter.supported, isTrue);
      expect(await adapter.publicRoot(), '/storage/emulated/0/Download/Molia');
      expect(
        await adapter.publish(
          sourcePath: '/data/app/a.mp3',
          displayName: 'a.mp3',
          mimeType: 'audio/mpeg',
          relativeDir: 'exports',
        ),
        'content://media/external/downloads/1',
      );
      expect(
        await adapter.remove('content://media/external/downloads/1'),
        isTrue,
      );

      expect(host.lastSourcePath, '/data/app/a.mp3');
      expect(host.lastDisplayName, 'a.mp3');
      expect(host.lastMimeType, 'audio/mpeg');
      expect(host.lastRelativeDir, 'exports');
      expect(host.lastRemoveUri, 'content://media/external/downloads/1');
    });

    test('原生返回 null / false 原样透传', () async {
      final host = _FakeHostApi()
        ..publicRootResult = null
        ..publishResult = null
        ..removeResult = false;
      final adapter = PigeonDownloadsPublisherAdapter(
        api: host,
        isAndroid: true,
      );

      expect(await adapter.publicRoot(), isNull);
      expect(
        await adapter.publish(
          sourcePath: '/data/app/a.mp3',
          displayName: 'a.mp3',
          mimeType: 'audio/mpeg',
        ),
        isNull,
      );
      expect(
        await adapter.remove('content://media/external/downloads/0'),
        isFalse,
      );
      expect(adapter.transportAvailable, isTrue);
    });

    test('空参数不进原生：sourcePath / displayName 为空返回 null，uri 为空返回 false', () async {
      final host = _FakeHostApi();
      final adapter = PigeonDownloadsPublisherAdapter(
        api: host,
        isAndroid: true,
      );

      expect(
        await adapter.publish(
          sourcePath: '',
          displayName: 'a.mp3',
          mimeType: 'audio/mpeg',
        ),
        isNull,
      );
      expect(
        await adapter.publish(
          sourcePath: '/data/app/a.mp3',
          displayName: '',
          mimeType: 'audio/mpeg',
        ),
        isNull,
      );
      expect(await adapter.remove(''), isFalse);
      expect(host.publishCalls, 0);
      expect(host.removeCalls, 0);
    });

    test('异常静默降级为 null / false，并永久标记 transport 不可用', () async {
      final host = _FakeHostApi()
        ..throwOnPublicRoot = true
        ..throwOnPublish = true
        ..throwOnRemove = true;
      final adapter = PigeonDownloadsPublisherAdapter(
        api: host,
        isAndroid: true,
      );

      expect(await adapter.publicRoot(), isNull);
      expect(adapter.transportAvailable, isFalse);
      // 已标记不可用：后续调用不再触碰生成 API。
      expect(
        await adapter.publish(
          sourcePath: '/data/app/a.mp3',
          displayName: 'a.mp3',
          mimeType: 'audio/mpeg',
        ),
        isNull,
      );
      expect(
        await adapter.remove('content://media/external/downloads/1'),
        isFalse,
      );
      expect(host.publishCalls, 0);
      expect(host.removeCalls, 0);
    });

    test('非 Android：不触碰生成 API，保持 Noop 语义', () async {
      final host = _FakeHostApi();
      final adapter = PigeonDownloadsPublisherAdapter(
        api: host,
        isAndroid: false,
      );

      expect(adapter.supported, isFalse);
      expect(adapter.transportAvailable, isFalse);
      expect(await adapter.publicRoot(), isNull);
      expect(
        await adapter.publish(
          sourcePath: '/data/app/a.mp3',
          displayName: 'a.mp3',
          mimeType: 'audio/mpeg',
        ),
        isNull,
      );
      expect(
        await adapter.remove('content://media/external/downloads/1'),
        isFalse,
      );
      expect(host.publicRootCalls, 0);
      expect(host.publishCalls, 0);
      expect(host.removeCalls, 0);
    });
  });

  group('PigeonFirstDownloadsPublisher', () {
    test('Pigeon 正常时使用其结果，不调用旧通道', () async {
      final host = _FakeHostApi()
        ..publicRootResult = '/pigeon/Molia'
        ..publishResult = 'content://pigeon/1'
        ..removeResult = true;
      final fallback = _FakeFallbackPublisher()
        ..publicRootResult = '/legacy/Molia'
        ..publishResult = 'content://legacy/1'
        ..removeResult = false;
      final publisher = PigeonFirstDownloadsPublisher(
        pigeon: PigeonDownloadsPublisherAdapter(api: host, isAndroid: true),
        fallback: fallback,
      );

      expect(publisher.supported, isTrue);
      expect(await publisher.publicRoot(), '/pigeon/Molia');
      expect(
        await publisher.publish(
          sourcePath: '/data/app/a.mp3',
          displayName: 'a.mp3',
          mimeType: 'audio/mpeg',
        ),
        'content://pigeon/1',
      );
      expect(await publisher.remove('content://pigeon/1'), isTrue);
      expect(fallback.publicRootCalls, 0);
      expect(fallback.publishCalls, 0);
      expect(fallback.removeCalls, 0);
    });

    test('Pigeon transport 异常时回退旧通道', () async {
      final host = _FakeHostApi()
        ..throwOnPublicRoot = true
        ..throwOnPublish = true
        ..throwOnRemove = true;
      final fallback = _FakeFallbackPublisher()
        ..publicRootResult = '/legacy/Molia'
        ..publishResult = 'content://legacy/1'
        ..removeResult = true;
      final publisher = PigeonFirstDownloadsPublisher(
        pigeon: PigeonDownloadsPublisherAdapter(api: host, isAndroid: true),
        fallback: fallback,
      );

      expect(await publisher.publicRoot(), '/legacy/Molia');
      expect(
        await publisher.publish(
          sourcePath: '/data/app/a.mp3',
          displayName: 'a.mp3',
          mimeType: 'audio/mpeg',
          relativeDir: 'exports',
        ),
        'content://legacy/1',
      );
      expect(await publisher.remove('content://legacy/1'), isTrue);
      expect(fallback.publicRootCalls, 1);
      expect(fallback.publishCalls, 1);
      expect(fallback.removeCalls, 1);
    });

    test('Pigeon 正常返回 null 视为真实失败，不重复发布', () async {
      final host = _FakeHostApi()..publishResult = null;
      final fallback = _FakeFallbackPublisher()
        ..publishResult = 'content://legacy/1';
      final publisher = PigeonFirstDownloadsPublisher(
        pigeon: PigeonDownloadsPublisherAdapter(api: host, isAndroid: true),
        fallback: fallback,
      );

      expect(
        await publisher.publish(
          sourcePath: '/data/app/a.mp3',
          displayName: 'a.mp3',
          mimeType: 'audio/mpeg',
        ),
        isNull,
      );
      expect(fallback.publishCalls, 0);
    });

    test('非 Android 工厂返回 Noop 语义', () async {
      final publisher = createDownloadsPublisher();
      expect(publisher.supported, isFalse);
      expect(await publisher.publicRoot(), isNull);
      expect(
        await publisher.publish(
          sourcePath: '/nonexistent.mp3',
          displayName: 'a.mp3',
          mimeType: 'audio/mpeg',
        ),
        isNull,
      );
      expect(
        await publisher.remove('content://media/external/downloads/0'),
        isFalse,
      );
    });
  });
}
