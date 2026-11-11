import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/providers/library_outcome.dart';
import 'package:molia/providers/library_read_projection.dart';

void main() {
  ReadReconciliation<List<int>, int> build({
    bool supersedeReads = false,
    bool replayRequiresLoaded = true,
    bool Function(List<int> value)? canReadQuietly,
  }) {
    return ReadReconciliation(
      initialValue: const [],
      mergeQuiet: (current, fresh) => [...current, ...fresh],
      replayWrites: (current, pending) => [...current, ...pending],
      failureState: (value, error) => value.isEmpty
          ? LibraryReadState.failed(error)
          : const LibraryReadState.ready(),
      supersedeReads: supersedeReads,
      replayRequiresLoaded: replayRequiresLoaded,
      canReadQuietly: canReadQuietly,
    );
  }

  test('explicit 翻 loading 并替换，quiet 合并且保持旧值可见', () async {
    final read = build();
    final explicitGate = Completer<List<int>>();
    final explicit = read.load(
      intent: LibraryReadIntent.explicit,
      fetch: () => explicitGate.future,
    );
    expect(read.state.isLoading, isTrue);
    explicitGate.complete([1]);
    await explicit;
    expect(read.value, [1]);
    expect(read.state.isReady, isTrue);
    final snapshot = read.snapshot;
    expect(snapshot.value, [1]);
    expect(snapshot.loaded, isTrue);
    expect(snapshot.reading, isFalse);

    final quietGate = Completer<List<int>>();
    final quiet = read.load(
      intent: LibraryReadIntent.quiet,
      fetch: () => quietGate.future,
    );
    expect(read.state.isReady, isTrue, reason: '静默校准不翻 loading');
    expect(read.value, [1]);
    quietGate.complete([2]);
    await quiet;
    expect(read.value, [1, 2], reason: 'quiet 走 mergeQuiet');
  });

  test('supersedeReads：后发起的读取抢占，旧结果不写回', () async {
    final read = build(supersedeReads: true);
    final staleGate = Completer<List<int>>();
    final stale = read.load(
      intent: LibraryReadIntent.quiet,
      fetch: () => staleGate.future,
    );
    final freshGate = Completer<List<int>>();
    final fresh = read.load(
      intent: LibraryReadIntent.quiet,
      fetch: () => freshGate.future,
    );

    freshGate.complete([2]);
    final freshResult = await fresh;
    staleGate.complete([1]);
    final staleResult = await stale;

    expect(freshResult.accepted, isTrue);
    expect(staleResult.accepted, isFalse);
    expect(read.value, [2]);
  });

  test('读取期间写入先缓冲，最后一个读取落地后按到达顺序重放', () async {
    final read = build();
    await read.load(
      intent: LibraryReadIntent.explicit,
      fetch: () => Future.value([1]),
    );

    final gate = Completer<List<int>>();
    final pending = read.load(
      intent: LibraryReadIntent.quiet,
      fetch: () => gate.future,
    );
    expect(read.bufferWrite(2), isTrue);
    expect(read.bufferWrite(3), isTrue);
    expect(read.value, [1], reason: '读在途时写入不直接改快照');
    gate.complete([4]);
    await pending;

    expect(read.value, [1, 4, 2, 3]);
    expect(read.bufferWrite(5), isFalse, reason: '没有读取在途时由调用方直接补丁');
  });

  test('从未加载成功时保留缓冲，等下一次整表读取后重放', () async {
    final read = build();
    final failedGate = Completer<List<int>>();
    final failed = read.load(
      intent: LibraryReadIntent.explicit,
      fetch: () => failedGate.future,
    );
    expect(read.bufferWrite(2), isTrue);
    failedGate.completeError(StateError('read failed'));
    await failed;
    expect(read.value, isEmpty, reason: '失败且无基线时不伪造历史');

    await read.load(
      intent: LibraryReadIntent.explicit,
      fetch: () => Future.value([1]),
    );
    expect(read.value, [1, 2], reason: '下一次成功读取后补入缓冲写入');
  });

  test('invalidate(staleReads) 让在途结果作废，discardValue 清空快照', () async {
    final read = build();
    final gate = Completer<List<int>>();
    final pending = read.load(
      intent: LibraryReadIntent.explicit,
      fetch: () => gate.future,
    );
    read.invalidate(staleReads: true, discardValue: true, discardPending: true);
    expect(read.value, isEmpty);
    expect(read.state.isLoading, isTrue);

    gate.complete([1]);
    final result = await pending;
    expect(result.accepted, isFalse);
    expect(read.value, isEmpty, reason: '释放前的读取不能写回');
  });

  test('markExplicitLoading 同步占位，读取落地后回收', () async {
    final read = build();
    expect(read.markExplicitLoading(), isTrue);
    expect(read.explicitLoading, isTrue);
    expect(read.markExplicitLoading(), isFalse, reason: '已有显式占位不重复发起');

    final gate = Completer<List<int>>();
    final pending = read.load(
      intent: LibraryReadIntent.explicit,
      fetch: () => gate.future,
    );
    expect(read.explicitLoading, isTrue);
    gate.complete(const []);
    await pending;
    expect(read.explicitLoading, isFalse);
  });

  test('canReadQuietly 为假时不发起查询，也不改变快照', () async {
    var calls = 0;
    final read = build(canReadQuietly: (value) => value.isNotEmpty);
    final result = await read.load(
      intent: LibraryReadIntent.quiet,
      fetch: () {
        calls++;
        return Future.value([1]);
      },
    );
    expect(calls, 0);
    expect(result.accepted, isFalse);
    expect(read.value, isEmpty);
  });
}
