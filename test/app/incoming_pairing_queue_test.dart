import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/app/app_shell.dart';
import 'package:molia/domain/models/sync_nearby_pairing.dart';

/// 应用壳接收方配对队列：当前确认窗未关闭时，后续请求必须排队而不是被
/// 当成「已有弹窗」直接拒绝。
void main() {
  SyncPairingRequest request(String id) => SyncPairingRequest(
        requestId: id,
        peerDeviceId: 'dev-$id',
        peerName: id,
        intent: SyncPairingIntent.join,
        code: '482193',
        expiresAt: 1 << 50,
      );

  test('当前窗未关闭时新请求排队，关闭后逐条展示', () async {
    final queue = IncomingPairingQueue();
    final firstGate = Completer<void>();
    final shown = <String>[];
    final rejected = <String>[];

    queue.add(request('r1'));
    final done = queue.drain(
      present: (item) async {
        shown.add(item.requestId);
        if (item.requestId == 'r1') await firstGate.future;
        return true;
      },
      reject: (item) async => rejected.add(item.requestId),
    );
    await Future<void>.delayed(Duration.zero);
    expect(shown, ['r1']);
    expect(queue.isDraining, isTrue);

    queue.add(request('r2'));
    // 重复调用 drain（流在确认窗关闭前又推了一条）不会并发开第二个窗。
    await queue.drain(
      present: (item) async => throw StateError('不应重入：${item.requestId}'),
      reject: (item) async => throw StateError('不应拒绝：${item.requestId}'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(shown, ['r1'], reason: '第一条没关闭前不展示第二条');

    firstGate.complete();
    await done;
    expect(shown, ['r1', 'r2'], reason: '当前窗关闭后 drain 继续下一条');
    expect(rejected, isEmpty);
    expect(queue.isEmpty, isTrue);
    expect(queue.isDraining, isFalse);
  });

  test('宿主 context 消失：当前与排队请求都给出拒绝结论', () async {
    final queue = IncomingPairingQueue();
    final rejected = <String>[];
    queue
      ..add(request('r1'))
      ..add(request('r2'))
      ..add(request('r3'));

    await queue.drain(
      present: (item) async => false,
      reject: (item) async => rejected.add(item.requestId),
    );

    expect(rejected, ['r1', 'r2', 'r3']);
    expect(queue.isEmpty, isTrue);
    expect(queue.isDraining, isFalse);
  });
}
