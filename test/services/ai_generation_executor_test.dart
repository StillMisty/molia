import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/domain/models/failure.dart';
import 'package:molia/services/ai/ai_generation_executor.dart';

AiDjBatch _batch(String id) => AiDjBatch(
      id: id,
      items: const [],
      generatedAt: DateTime(2026, 10, 22),
    );

AiGenerationIntent _intent(
  AiGenerationLane lane, {
  String? replacingUri,
}) =>
    AiGenerationIntent(
      origin: lane == AiGenerationLane.silent
          ? AiDjOrigin.autoFeed
          : AiDjOrigin.refresh,
      count: 1,
      lane: lane,
      replacingUri: replacingUri,
    );

void main() {
  test('显式取消后晚到结果不提交；下一轮 epoch 可正常提交', () async {
    final executor = AiGenerationExecutor();
    addTearDown(executor.dispose);
    final gate = Completer<AiDjBatch>();
    var commits = 0;
    var failures = 0;
    var progressCalls = 0;

    final first = executor.run<AiDjBatch>(
      intent: _intent(AiGenerationLane.explicit),
      invoke: (token, onProgress) async {
        onProgress?.call(AiDjProgress(
          phase: AiDjPhase.profile,
          startedAt: DateTime(2026, 10, 22),
        ));
        progressCalls++;
        return gate.future;
      },
      commit: (batch) async {
        commits++;
        return batch;
      },
      onFailure: (_, _) => failures++,
    );

    expect(executor.isBusy, isTrue);
    expect(executor.progress, isNotNull);
    expect(progressCalls, 1);

    executor.cancelExplicit();
    expect(executor.isBusy, isFalse);
    expect(executor.progress, isNull);

    gate.complete(_batch('late'));
    expect(await first, isNull);
    expect(commits, 0, reason: '取消后的晚到结果不能提交');
    expect(failures, 0, reason: '取消不写错误');

    final second = await executor.run<AiDjBatch>(
      intent: _intent(AiGenerationLane.explicit),
      invoke: (_, _) async => _batch('next'),
      commit: (batch) async {
        commits++;
        return batch;
      },
      onFailure: (_, _) => failures++,
    );

    expect(second?.id, 'next');
    expect(commits, 1, reason: '新一轮 epoch 不受上一轮取消影响');
    expect(executor.isBusy, isFalse);
  });

  test('silent 在途时 explicit 启动会抢占，silent 结果丢弃', () async {
    final executor = AiGenerationExecutor();
    addTearDown(executor.dispose);
    final silentGate = Completer<AiDjBatch>();
    var silentCommits = 0;

    final silent = executor.run<AiDjBatch>(
      intent: _intent(AiGenerationLane.silent),
      invoke: (_, _) async => silentGate.future,
      commit: (batch) async {
        silentCommits++;
        return batch;
      },
      onFailure: (_, _) {},
    );
    expect(executor.autoFeedInFlight, isTrue);
    expect(executor.isBusy, isFalse);

    final explicit = await executor.run<AiDjBatch>(
      intent: _intent(AiGenerationLane.explicit),
      invoke: (_, _) async => _batch('explicit'),
      commit: (batch) async => batch,
      onFailure: (_, _) {},
    );

    expect(explicit?.id, 'explicit');
    expect(executor.autoFeedInFlight, isFalse, reason: '显式操作取消静默 token');

    silentGate.complete(_batch('silent-late'));
    expect(await silent, isNull);
    expect(silentCommits, 0, reason: '被抢占的静默结果不能入队');
  });

  test('replace 不受 cancelExplicit 影响；与 explicit 忙碌位互不污染', () async {
    final executor = AiGenerationExecutor();
    addTearDown(executor.dispose);
    const replacingUri = 'wy:1';
    final replaceGate = Completer<AiDjBatch>();
    final explicitGate = Completer<AiDjBatch>();
    var replaceCommits = 0;

    final replace = executor.run<AiDjBatch>(
      intent: _intent(AiGenerationLane.replace, replacingUri: replacingUri),
      invoke: (_, _) async => replaceGate.future,
      commit: (batch) async {
        replaceCommits++;
        return batch;
      },
      onFailure: (_, _) {},
    );
    expect(executor.replacingUri, replacingUri);
    expect(executor.isBusy, isFalse);

    executor.cancelExplicit();
    expect(executor.replacingUri, replacingUri, reason: '换一首本来不可取消');

    final explicit = executor.run<AiDjBatch>(
      intent: _intent(AiGenerationLane.explicit),
      invoke: (_, _) async => explicitGate.future,
      commit: (batch) async => batch,
      onFailure: (_, _) {},
    );
    expect(executor.isBusy, isTrue);
    expect(executor.replacingUri, replacingUri);

    replaceGate.complete(_batch('replace'));
    expect((await replace)?.id, 'replace');
    expect(executor.replacingUri, isNull);
    expect(executor.isBusy, isTrue, reason: '换一首结束不能清掉显式忙碌位');

    explicitGate.complete(_batch('explicit'));
    expect((await explicit)?.id, 'explicit');
    expect(executor.isBusy, isFalse);
    expect(replaceCommits, 1);
  });

  test('只有 explicit lane 收到非空 onProgress', () async {
    final executor = AiGenerationExecutor();
    addTearDown(executor.dispose);
    final progressArgs = <bool>[];

    Future<void> run(AiGenerationLane lane) async {
      await executor.run<AiDjBatch>(
        intent: _intent(
          lane,
          replacingUri: lane == AiGenerationLane.replace ? 'wy:1' : null,
        ),
        invoke: (_, onProgress) async {
          progressArgs.add(onProgress != null);
          return _batch(lane.name);
        },
        commit: (batch) async => batch,
        onFailure: (_, _) {},
      );
    }

    await run(AiGenerationLane.explicit);
    await run(AiGenerationLane.silent);
    await run(AiGenerationLane.replace);

    expect(progressArgs, [true, false, false]);
  });

  test('失败策略分流：surface / autoFeed 各自只回调对应策略', () async {
    final executor = AiGenerationExecutor();
    addTearDown(executor.dispose);
    final policies = <AiGenerationFailurePolicy>[];

    Future<void> run(AiGenerationLane lane) async {
      await executor.run<AiDjBatch>(
        intent: _intent(
          lane,
          replacingUri: lane == AiGenerationLane.replace ? 'wy:1' : null,
        ),
        invoke: (_, _) async => throw const SourceFailure(
          kind: FailureKind.unknown,
          message: 'boom',
        ),
        commit: (batch) async => batch,
        onFailure: (intent, _) => policies.add(intent.failurePolicy),
      );
    }

    await run(AiGenerationLane.explicit);
    expect(policies, [AiGenerationFailurePolicy.surface]);

    policies.clear();
    await run(AiGenerationLane.replace);
    expect(policies, [AiGenerationFailurePolicy.surface]);

    policies.clear();
    await run(AiGenerationLane.silent);
    expect(policies, [AiGenerationFailurePolicy.autoFeed]);
  });
}
