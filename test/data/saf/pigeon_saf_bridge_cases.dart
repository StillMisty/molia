import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/saf/pigeon_saf_bridge.dart';
import 'package:molia/data/saf/saf_bridge.dart';
import 'package:molia/data/saf/saf_bridge_factory.dart';
import 'package:molia/platform/pigeon/saf.g.dart';
import 'package:molia/platform/pigeon/saf_adapter.dart';

/// 假 Pigeon transport：按调用顺序返回批次，可注入连接层 / 业务错误。
class _FakeTransport implements SafPigeonTransport {
  bool available = true;
  bool isSupported = true;

  SafDocumentMessage? statResult;
  Object? statError;
  String? beginResult = 'token';
  Object? beginError;
  final List<SafTreeBatchMessage?> batches = [];
  Object? nextError;

  /// 第几次 `listTreeNext` 抛 [nextError]（默认首次）。
  int nextErrorOnCall = 1;
  Object? headError;
  Object? rangeError;
  Uint8List? headResult;
  Uint8List? rangeResult;
  Object? closeError;

  int beginCalls = 0;
  int nextCalls = 0;
  int closeCalls = 0;
  int lastMaxEntries = 0;
  final List<String> closedTokens = [];

  @override
  bool get supported => isSupported;

  @override
  bool get transportAvailable => isSupported && available;

  @override
  Future<SafDocumentMessage?> stat(String uri) async {
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
    lastMaxEntries = maxEntries;
    if (nextError != null && nextCalls >= nextErrorOnCall) throw nextError!;
    if (batches.isEmpty) return null;
    return batches.removeAt(0);
  }

  @override
  Future<void> listTreeClose(String token) async {
    closeCalls++;
    closedTokens.add(token);
    if (closeError != null) throw closeError!;
  }

  @override
  Future<Uint8List?> readHead(String uri, int length) async {
    if (headError != null) throw headError!;
    return headResult;
  }

  @override
  Future<Uint8List?> readRange(String uri, int start, int length) async {
    if (rangeError != null) throw rangeError!;
    return rangeResult;
  }
}

/// 旧通道 fallback 的假实现。
class _FakeFallbackBridge implements SafBridge {
  int statCalls = 0;
  int listTreeCalls = 0;
  int readHeadCalls = 0;
  int readRangeCalls = 0;
  SafDocument? statResult;
  final List<SafTreeEvent> treeEvents = [];

  @override
  Future<SafDocument?> stat(String uri) async {
    statCalls++;
    return statResult;
  }

  @override
  Stream<SafTreeEvent> listTree(
    String uri, {
    required int maxDepth,
    bool Function()? isCancelled,
  }) async* {
    listTreeCalls++;
    for (final event in treeEvents) {
      if (isCancelled?.call() == true) return;
      yield event;
    }
  }

  @override
  Future<Uint8List?> readHead(String uri, int length) async {
    readHeadCalls++;
    return Uint8List.fromList([9]);
  }

  @override
  Future<Uint8List?> readRange(String uri, int start, int length) async {
    readRangeCalls++;
    return Uint8List.fromList([8]);
  }
}

SafTreeEntryMessage _entry(String relativePath) => SafTreeEntryMessage(
  uri: 'content://tree/1/document/$relativePath',
  name: relativePath,
  relativePath: relativePath,
  isDirectory: false,
  sizeBytes: 10,
  mtimeMs: 20,
  skip: null,
);

SafTreeEntryMessage _skip(String relativePath, String reason) =>
    SafTreeEntryMessage(
      uri: '',
      name: '',
      relativePath: relativePath,
      isDirectory: false,
      sizeBytes: 0,
      mtimeMs: 0,
      skip: reason,
    );

void main() {
  group('PigeonSafBridge', () {
    test('stat 映射；空 uri / 展示名按桥接语义补齐', () async {
      final transport = _FakeTransport()
        ..statResult = SafDocumentMessage(
          uri: '',
          displayName: ' Music ',
          isDirectory: true,
          sizeBytes: 42,
          mtimeMs: 1234,
        );
      final bridge = PigeonSafBridge(transport);

      final document = await bridge.stat('content://tree/1');
      expect(document?.uri, 'content://tree/1');
      expect(document?.displayName, 'Music');
      expect(document?.isDirectory, isTrue);
      expect(document?.sizeBytes, 42);
      expect(document?.mtimeMs, 1234);

      transport.statResult = null;
      expect(await bridge.stat('content://tree/1'), isNull);
    });

    test('业务错误码映射为 SafFailureKind', () async {
      final cases = {
        'MISSING': SafFailureKind.missing,
        'PERMISSION_DENIED': SafFailureKind.permissionDenied,
        'UNSUPPORTED': SafFailureKind.unsupported,
        'INVALID_ARGUMENT': SafFailureKind.io,
        'BOOM': SafFailureKind.io,
      };
      for (final entry in cases.entries) {
        final transport = _FakeTransport()
          ..statError = SafPigeonException(entry.key, 'x');
        await expectLater(
          PigeonSafBridge(transport).stat('content://tree/1'),
          throwsA(
            isA<SafBridgeException>().having(
              (e) => e.kind,
              'kind',
              entry.value,
            ),
          ),
        );
      }
    });

    test('listTree 分批、done、skip、close 与批量大小', () async {
      final transport = _FakeTransport()
        ..batches.addAll([
          SafTreeBatchMessage(
            entries: [_entry('a.mp3'), _skip('.trash', 'hidden')],
            done: false,
          ),
          SafTreeBatchMessage(
            entries: [_skip('deep', 'depthExceeded')],
            done: true,
          ),
        ]);
      final bridge = PigeonSafBridge(transport);

      final events = await bridge
          .listTree('content://tree/1', maxDepth: 8)
          .toList();
      final entries = events.whereType<SafTreeEntry>().toList();
      final skips = events.whereType<SafTreeSkipped>().toList();
      expect(entries, hasLength(1));
      expect(entries.single.displayName, 'a.mp3');
      expect(entries.single.sizeBytes, 10);
      expect(skips.map((s) => s.reason), ['hidden', 'depthExceeded']);
      expect(skips.map((s) => s.relativePath), ['.trash', 'deep']);
      expect(transport.beginCalls, 1);
      expect(transport.nextCalls, 2);
      expect(transport.lastMaxEntries, PigeonSafBridge.batchSize);
      expect(transport.closeCalls, 1);
      expect(transport.closedTokens, ['token']);
    });

    test('listTree 取消后不再拉取下一批，但仍关闭会话', () async {
      final transport = _FakeTransport()
        ..batches.addAll([
          SafTreeBatchMessage(entries: [_entry('a.mp3')], done: false),
          SafTreeBatchMessage(entries: [_entry('b.mp3')], done: false),
        ]);
      final bridge = PigeonSafBridge(transport);
      var cancelled = false;

      final events = <SafTreeEvent>[];
      await for (final event in bridge.listTree(
        'content://tree/1',
        maxDepth: 8,
        isCancelled: () => cancelled,
      )) {
        events.add(event);
        cancelled = true;
      }

      expect(events.whereType<SafTreeEntry>(), hasLength(1));
      expect(transport.nextCalls, 1);
      expect(transport.closeCalls, 1);
    });

    test('close 失败不覆盖扫描结果', () async {
      final transport = _FakeTransport()
        ..batches.add(
          SafTreeBatchMessage(entries: [_entry('a.mp3')], done: true),
        )
        ..closeError = StateError('close failed');
      final bridge = PigeonSafBridge(transport);

      final events = await bridge
          .listTree('content://tree/1', maxDepth: 8)
          .toList();
      expect(events.whereType<SafTreeEntry>(), hasLength(1));
      expect(transport.closeCalls, 1);
    });

    test('listTreeBegin 返回 null → UNSUPPORTED（与旧通道一致）', () async {
      final transport = _FakeTransport()..beginResult = null;
      await expectLater(
        PigeonSafBridge(transport).listTree('content://tree/1', maxDepth: 8),
        emitsError(
          isA<SafBridgeException>().having(
            (e) => e.kind,
            'kind',
            SafFailureKind.unsupported,
          ),
        ),
      );
      expect(transport.nextCalls, 0);
      // begin 没有拿到 token，没有会话可关。
      expect(transport.closeCalls, 0);
    });

    test('readHead / readRange 参数语义与旧通道一致', () async {
      final transport = _FakeTransport()
        ..headResult = Uint8List.fromList([1, 2])
        ..rangeResult = Uint8List.fromList([3]);
      final bridge = PigeonSafBridge(transport);

      expect(await bridge.readHead('content://x', 0), isEmpty);
      expect(await bridge.readHead('content://x', 2), [1, 2]);
      expect(await bridge.readRange('content://x', -1, 2), isNull);
      expect(await bridge.readRange('content://x', 0, -1), isNull);
      expect(await bridge.readRange('content://x', 5, 1), [3]);
    });
  });

  group('PigeonFirstSafBridge', () {
    test('连接层失败 → 回退旧通道', () async {
      final transport = _FakeTransport()
        ..statError = const SafTransportUnavailable('gone')
        ..headError = const SafTransportUnavailable('gone')
        ..rangeError = const SafTransportUnavailable('gone')
        ..beginError = const SafTransportUnavailable('gone');
      final fallback = _FakeFallbackBridge()
        ..statResult = const SafDocument(
          uri: 'content://tree/1',
          displayName: 'Music',
          isDirectory: true,
          sizeBytes: 0,
          mtimeMs: 0,
        )
        ..treeEvents.add(_fallbackEntry());
      final bridge = PigeonFirstSafBridge(
        pigeon: transport,
        fallback: fallback,
      );

      expect((await bridge.stat('content://tree/1'))?.displayName, 'Music');
      expect(await bridge.readHead('content://x', 2), [9]);
      expect(await bridge.readRange('content://x', 0, 2), [8]);
      expect(
        await bridge.listTree('content://tree/1', maxDepth: 8).toList(),
        hasLength(1),
      );
      expect(fallback.statCalls, 1);
      expect(fallback.readHeadCalls, 1);
      expect(fallback.readRangeCalls, 1);
      expect(fallback.listTreeCalls, 1);
    });

    test('业务错误不换 transport', () async {
      final transport = _FakeTransport()
        ..statError = const SafPigeonException('PERMISSION_DENIED');
      final fallback = _FakeFallbackBridge();
      final bridge = PigeonFirstSafBridge(
        pigeon: transport,
        fallback: fallback,
      );

      await expectLater(
        bridge.stat('content://tree/1'),
        throwsA(
          isA<SafBridgeException>().having(
            (e) => e.kind,
            'kind',
            SafFailureKind.permissionDenied,
          ),
        ),
      );
      expect(fallback.statCalls, 0);
    });

    test('首批之前连接失败 → 回退；已产出条目不回退', () async {
      final firstBatch = _FakeTransport()
        ..nextError = const SafTransportUnavailable('gone');
      final fallback = _FakeFallbackBridge()..treeEvents.add(_fallbackEntry());
      final bridge = PigeonFirstSafBridge(
        pigeon: firstBatch,
        fallback: fallback,
      );

      final events = await bridge
          .listTree('content://tree/1', maxDepth: 8)
          .toList();
      expect(events, hasLength(1));
      expect(fallback.listTreeCalls, 1);
      expect(firstBatch.closeCalls, 1);

      final midStream = _FakeTransport()
        ..batches.add(
          SafTreeBatchMessage(entries: [_entry('a.mp3')], done: false),
        )
        ..nextError = const SafTransportUnavailable('gone')
        ..nextErrorOnCall = 2;
      final midFallback = _FakeFallbackBridge();
      final midBridge = PigeonFirstSafBridge(
        pigeon: midStream,
        fallback: midFallback,
      );

      final seen = <SafTreeEvent>[];
      await expectLater(
        midBridge.listTree('content://tree/1', maxDepth: 8).forEach(seen.add),
        throwsA(
          isA<SafBridgeException>().having(
            (e) => e.kind,
            'kind',
            SafFailureKind.io,
          ),
        ),
      );
      expect(seen.whereType<SafTreeEntry>(), hasLength(1));
      expect(midFallback.listTreeCalls, 0);
      expect(midStream.closeCalls, 1);
    });

    test('transport 初始不可用 → 直接走旧通道', () async {
      final transport = _FakeTransport()..available = false;
      final fallback = _FakeFallbackBridge()..treeEvents.add(_fallbackEntry());
      final bridge = PigeonFirstSafBridge(
        pigeon: transport,
        fallback: fallback,
      );

      await bridge.listTree('content://tree/1', maxDepth: 8).toList();
      expect(transport.beginCalls, 0);
      expect(fallback.listTreeCalls, 1);
    });
  });

  group('createSafBridge', () {
    test('非 Android 返回 null（桌面继续走 dart:io）', () {
      expect(createSafBridge(isAndroid: false), isNull);
    });

    test('Android 组合 Pigeon 优先 + 旧通道 fallback', () {
      final transport = _FakeTransport();
      final fallback = _FakeFallbackBridge();
      final bridge = createSafBridge(
        isAndroid: true,
        pigeon: transport,
        fallback: fallback,
      );
      expect(bridge, isA<PigeonFirstSafBridge>());
    });
  });
}

SafTreeEntry _fallbackEntry() => const SafTreeEntry(
  uri: 'content://tree/1/document/fallback.mp3',
  displayName: 'fallback.mp3',
  relativePath: 'fallback.mp3',
  isDirectory: false,
  sizeBytes: 1,
  mtimeMs: 1,
);
