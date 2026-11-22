import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/platform/pigeon/saf.g.dart';
import 'package:molia/platform/pigeon/saf_adapter.dart';

/// 假 Pigeon host：覆盖成功、null、业务错误与连接层错误。
class _FakeHostApi implements SafHostApi {
  Object? statError;
  Object? beginError;
  Object? nextError;
  Object? closeError;
  Object? headError;
  Object? rangeError;

  SafDocumentMessage? statResult;
  String? beginResult = 'token';
  SafTreeBatchMessage? nextResult;
  Uint8List? headResult;
  Uint8List? rangeResult;

  int statCalls = 0;
  int beginCalls = 0;
  int nextCalls = 0;
  int closeCalls = 0;
  int headCalls = 0;
  int rangeCalls = 0;

  @override
  Future<SafDocumentMessage?> stat(String uri) async {
    statCalls++;
    if (statError != null) throw statError!;
    return statResult;
  }

  @override
  Future<String?> listTreeBegin(String uri, int maxDepth) async {
    beginCalls++;
    if (beginError != null) throw beginError!;
    return beginResult;
  }

  @override
  Future<SafTreeBatchMessage?> listTreeNext(
    String token,
    int maxEntries,
  ) async {
    nextCalls++;
    if (nextError != null) throw nextError!;
    return nextResult;
  }

  @override
  Future<void> listTreeClose(String token) async {
    closeCalls++;
    if (closeError != null) throw closeError!;
  }

  @override
  Future<Uint8List?> readHead(String uri, int length) async {
    headCalls++;
    if (headError != null) throw headError!;
    return headResult;
  }

  @override
  Future<Uint8List?> readRange(String uri, int start, int length) async {
    rangeCalls++;
    if (rangeError != null) throw rangeError!;
    return rangeResult;
  }
}

void main() {
  group('PigeonSafAdapter', () {
    test('非 Android 不调用 host，transport 标记不可用', () async {
      final host = _FakeHostApi();
      final adapter = PigeonSafAdapter(api: host, isAndroid: false);

      expect(adapter.supported, isFalse);
      expect(adapter.transportAvailable, isFalse);
      await expectLater(
        adapter.stat('content://tree/1'),
        throwsA(isA<SafTransportUnavailable>()),
      );
      await expectLater(
        adapter.listTreeBegin('content://tree/1', 32),
        throwsA(isA<SafTransportUnavailable>()),
      );
      expect(host.statCalls, 0);
      expect(host.beginCalls, 0);
    });

    test('成功：stat / begin / next / close / read 原样透传', () async {
      final host = _FakeHostApi()
        ..statResult = SafDocumentMessage(
          uri: 'content://tree/1',
          displayName: 'Music',
          isDirectory: true,
          sizeBytes: 0,
          mtimeMs: 7,
        )
        ..nextResult = SafTreeBatchMessage(
          entries: [
            SafTreeEntryMessage(
              uri: 'content://tree/1/document/a.mp3',
              name: 'a.mp3',
              relativePath: 'a.mp3',
              isDirectory: false,
              sizeBytes: 9,
              mtimeMs: 10,
              skip: null,
            ),
          ],
          done: true,
        )
        ..headResult = Uint8List.fromList([1, 2, 3])
        ..rangeResult = Uint8List.fromList([4, 5]);
      final adapter = PigeonSafAdapter(api: host, isAndroid: true);

      expect(adapter.supported, isTrue);
      expect(adapter.transportAvailable, isTrue);
      final document = await adapter.stat('content://tree/1');
      expect(document?.displayName, 'Music');
      expect(await adapter.listTreeBegin('content://tree/1', 32), 'token');
      final batch = await adapter.listTreeNext('token', 100);
      expect(batch?.entries.single.relativePath, 'a.mp3');
      expect(batch?.done, isTrue);
      await adapter.listTreeClose('token');
      expect(await adapter.readHead('content://x', 3), [1, 2, 3]);
      expect(await adapter.readRange('content://x', 4, 2), [4, 5]);
      expect(host.closeCalls, 1);
    });

    test('null 是真实结果，不当作 transport 失败', () async {
      final host = _FakeHostApi()
        ..beginResult = null
        ..headResult = null
        ..rangeResult = null;
      final adapter = PigeonSafAdapter(api: host, isAndroid: true);

      expect(await adapter.stat('content://tree/1'), isNull);
      expect(await adapter.listTreeBegin('content://tree/1', 32), isNull);
      expect(await adapter.listTreeNext('token', 100), isNull);
      expect(await adapter.readHead('content://x', 3), isNull);
      expect(await adapter.readRange('content://x', 0, 3), isNull);
      expect(adapter.transportAvailable, isTrue);
    });

    test('业务错误码转 SafPigeonException，不影响 transport 可用性', () async {
      final host = _FakeHostApi()
        ..statError = PlatformException(
          code: 'PERMISSION_DENIED',
          message: 'no',
        );
      final adapter = PigeonSafAdapter(api: host, isAndroid: true);

      await expectLater(
        adapter.stat('content://tree/1'),
        throwsA(
          isA<SafPigeonException>()
              .having((e) => e.code, 'code', 'PERMISSION_DENIED')
              .having((e) => e.message, 'message', 'no'),
        ),
      );
      expect(adapter.transportAvailable, isTrue);
    });

    test('未注册（channel-error）→ 不可用，后续调用不再触达 host', () async {
      final host = _FakeHostApi()
        ..statError = PlatformException(code: 'channel-error', message: 'gone');
      final adapter = PigeonSafAdapter(api: host, isAndroid: true);

      await expectLater(
        adapter.stat('content://tree/1'),
        throwsA(isA<SafTransportUnavailable>()),
      );
      expect(adapter.transportAvailable, isFalse);

      await expectLater(
        adapter.readHead('content://x', 1),
        throwsA(isA<SafTransportUnavailable>()),
      );
      expect(host.headCalls, 0);
    });

    test('MissingPluginException 与编解码异常也归为 transport 失败', () async {
      final missing = PigeonSafAdapter(
        api: _FakeHostApi()..beginError = MissingPluginException('no plugin'),
        isAndroid: true,
      );
      await expectLater(
        missing.listTreeBegin('content://tree/1', 32),
        throwsA(isA<SafTransportUnavailable>()),
      );
      expect(missing.transportAvailable, isFalse);

      final broken = PigeonSafAdapter(
        api: _FakeHostApi()..nextError = StateError('bad codec'),
        isAndroid: true,
      );
      await expectLater(
        broken.listTreeNext('token', 100),
        throwsA(isA<SafTransportUnavailable>()),
      );
      expect(broken.transportAvailable, isFalse);
    });

    test('未知业务错误码保留原 code（data 层归 IO）', () async {
      final host = _FakeHostApi()
        ..statError = PlatformException(code: 'INVALID_ARGUMENT', message: 'x');
      final adapter = PigeonSafAdapter(api: host, isAndroid: true);

      await expectLater(
        adapter.stat(''),
        throwsA(
          isA<SafPigeonException>().having(
            (e) => e.code,
            'code',
            'INVALID_ARGUMENT',
          ),
        ),
      );
      expect(adapter.transportAvailable, isTrue);
    });
  });
}
