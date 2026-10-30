import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_stamp.dart';
import 'package:molia/data/sync/sync_stamp_book.dart';
import 'package:molia/data/sync/sync_state_codec.dart';
import 'package:molia/domain/models/device_sync.dart';

/// 同步戳账本：发号器单调性 / 吸收、登记与墓碑、基线与编解码往返。
///
/// 账本是纯内存模块：这里直接构造实例，不经过 SharedPreferences 与安全存储。
void main() {
  late int now;
  late int changes;
  late SyncStampBook book;

  setUp(() {
    now = 1000;
    changes = 0;
    book = SyncStampBook(
      clock: () => now,
      deviceId: () => 'devA',
      onChanged: () => changes++,
    );
  });

  test('发号器同毫秒严格递增，吸收远端戳后本机下一次写入必胜', () {
    final first = book.stampIssuer.next();
    final second = book.stampIssuer.next();
    expect(first, const SyncVersion(physical: 1000, deviceId: 'devA'));
    expect(second.physical, 1000);
    expect(second.counter, 1);
    expect(second.isNewerThan(first), isTrue);
    expect(book.stampBaseline, const SyncVersion(physical: 1000, counter: 1));
    expect(changes, 2, reason: '每次取号都推进持久化基线');

    // 吸收同物理毫秒但 counter 更前的远端戳（不触发超前 warning 路径）。
    book.stampIssuer.observe(
      const SyncVersion(physical: 1000, counter: 5, deviceId: 'devB'),
    );
    expect(book.stampBaseline.counter, 5);
    final afterObserve = book.stampIssuer.next();
    expect(afterObserve.counter, 6);
    expect(
      afterObserve.isNewerThan(
        const SyncVersion(physical: 1000, counter: 5, deviceId: 'devB'),
      ),
      isTrue,
    );

    // 滞后观测不前进、不重复标脏。
    final changesBefore = changes;
    book.stampIssuer.observe(
      const SyncVersion(physical: 500, counter: 9, deviceId: 'devC'),
    );
    expect(book.stampBaseline.counter, 6);
    expect(changes, changesBefore);
  });

  test('登记 / 墓碑：写入标脏，移除只在命中时标脏', () {
    const stamp = SyncStamp(
      hash: 'h',
      version: SyncVersion(physical: 1000, counter: 1),
    );
    book.putSettingStamp('theme', stamp);
    book.putScriptStamp('lx-a', stamp);
    book.putScriptTombstone('lx-b', stamp);
    book.putCoverStamp('wy:1', stamp);
    book.putCoverTombstone('wy:2', stamp);
    expect(book.settingStamps['theme'], stamp);
    expect(book.scriptStamps['lx-a'], stamp);
    expect(book.scriptTombstones['lx-b'], stamp);
    expect(book.coverStamps['wy:1'], stamp);
    expect(book.coverTombstones['wy:2'], stamp);
    expect(changes, 5);

    book.removeScriptStamp('missing');
    book.removeScriptTombstone('missing');
    book.removeCoverStamp('missing');
    book.removeCoverTombstone('missing');
    expect(changes, 5, reason: '未命中条目的移除不改状态');

    book.removeScriptStamp('lx-a');
    book.removeScriptTombstone('lx-b');
    book.removeCoverStamp('wy:1');
    book.removeCoverTombstone('wy:2');
    expect(book.scriptStamps, isEmpty);
    expect(book.scriptTombstones, isEmpty);
    expect(book.coverStamps, isEmpty);
    expect(book.coverTombstones, isEmpty);
    expect(changes, 9);
  });

  test('脚本 id 基线 / 激活脚本 / 会话登记：整体替换并标脏', () {
    book.setKnownScriptIds(['lx-a', 'lx-b']);
    expect(book.knownScriptIds, ['lx-a', 'lx-b']);
    expect(
      () => book.knownScriptIds.add('lx-c'),
      throwsUnsupportedError,
      reason: '对外只暴露不可变视图',
    );

    book.setKnownScriptIds(['lx-b']);
    expect(book.knownScriptIds, ['lx-b']);

    const active = SyncStamp(
      hash: 'active',
      version: SyncVersion(physical: 1000, counter: 2),
    );
    const session = SyncStamp(version: SyncVersion(physical: 1000, counter: 3));
    book.setActiveScriptStamp(active);
    book.setSessionStamp(session);
    expect(book.activeScriptStamp, active);
    expect(book.sessionStamp, session);

    book.setActiveScriptStamp(null);
    book.setSessionStamp(null);
    expect(book.activeScriptStamp, isNull);
    expect(book.sessionStamp, isNull);
    expect(changes, 6, reason: 'set* 即使写成 null 也按显式变更标脏');
  });

  test('snapshot 复制集合：之后的本地写入不影响已取切片', () {
    book.putSettingStamp('theme', const SyncStamp(hash: 'h'));
    book.setKnownScriptIds(['lx-a']);

    final snapshot = book.snapshot();
    book.putSettingStamp('language', const SyncStamp(hash: 'h2'));
    book.setKnownScriptIds(['lx-b']);

    expect(snapshot.settingStamps.keys, ['theme']);
    expect(snapshot.knownScriptIds, ['lx-a']);
    expect(book.settingStamps.keys, ['theme', 'language']);
    expect(book.knownScriptIds, ['lx-b']);
  });

  test('applyState 整体替换且不标脏', () {
    book.putSettingStamp('stale', const SyncStamp(hash: 'old'));
    final changesBefore = changes;

    book.applyState(
      SyncStampBookState(
        stampBaseline: const SyncVersion(physical: 2000, counter: 4),
        settingStamps: {'theme': const SyncStamp(hash: 'new')},
        scriptStamps: {'lx-a': const SyncStamp(hash: 'script')},
        scriptTombstones: {
          'lx-b': const SyncStamp(version: SyncVersion(physical: 2001)),
        },
        knownScriptIds: const ['lx-a'],
        activeScriptStamp: const SyncStamp(hash: 'active'),
        sessionStamp: const SyncStamp(version: SyncVersion(physical: 2002)),
        coverStamps: {'wy:1': const SyncStamp(hash: 'cover')},
        coverTombstones: {
          'wy:2': const SyncStamp(version: SyncVersion(physical: 2003)),
        },
      ),
    );

    expect(book.settingStamps.keys, ['theme']);
    expect(book.settingStamps.containsKey('stale'), isFalse);
    expect(book.scriptStamps['lx-a']!.hash, 'script');
    expect(book.scriptTombstones['lx-b']!.version.physical, 2001);
    expect(book.knownScriptIds, ['lx-a']);
    expect(book.activeScriptStamp!.hash, 'active');
    expect(book.sessionStamp!.version.physical, 2002);
    expect(book.coverStamps['wy:1']!.hash, 'cover');
    expect(book.coverTombstones['wy:2']!.version.physical, 2003);
    expect(book.stampBaseline, const SyncVersion(physical: 2000, counter: 4));
    expect(changes, changesBefore, reason: '启动恢复不是本地变更');
  });

  test('基线恢复：seed 不倒退，全库最大戳参与取号', () {
    final first = book.stampIssuer.next(); // (1000, 0)
    final snapshot = book.snapshot();

    // 重启后时钟归零：从持久化基线恢复，下一次仍严格大于旧戳。
    now = 0;
    final restored = SyncStampBook(
      clock: () => now,
      deviceId: () => 'devA',
      onChanged: () {},
    )..applyState(snapshot);
    restored.seed(restored.stampBaseline);
    final after = restored.stampIssuer.next();
    expect(after.isNewerThan(first), isTrue);
    expect(after.physical, first.physical);
    expect(after.counter, first.counter + 1);

    // 全库最大戳比持久化基线更新：seed 吸收后下一次写入必胜。
    const dbMax = SyncVersion(physical: 5000, counter: 7, deviceId: 'devB');
    restored.seed(dbMax);
    final afterDbSeed = restored.stampIssuer.next();
    expect(afterDbSeed.isNewerThan(dbMax), isTrue);
  });

  test('编解码往返：账本快照经 SyncStateCodec 保持全部键与值', () {
    book.putSettingStamp(
      'theme',
      const SyncStamp(
        hash: 'h-theme',
        version: SyncVersion(physical: 1000, counter: 1),
      ),
    );
    book.putScriptStamp(
      'lx-a',
      const SyncStamp(
        hash: 'h-script',
        version: SyncVersion(physical: 1000, counter: 2),
      ),
    );
    book.putScriptTombstone(
      'lx-b',
      const SyncStamp(version: SyncVersion(physical: 1000, counter: 3)),
    );
    book.setKnownScriptIds(['lx-a']);
    book.setActiveScriptStamp(
      const SyncStamp(
        hash: 'h-active',
        version: SyncVersion(physical: 1000, counter: 4),
      ),
    );
    book.setSessionStamp(
      const SyncStamp(version: SyncVersion(physical: 1000, counter: 5)),
    );
    book.putCoverStamp(
      'wy:1',
      const SyncStamp(
        hash: 'h-cover',
        version: SyncVersion(physical: 1000, counter: 6),
      ),
    );
    book.putCoverTombstone(
      'wy:2',
      const SyncStamp(version: SyncVersion(physical: 1000, counter: 7)),
    );
    final snapshot = book.snapshot();

    final encoded = SyncStateCodec.encode(_persistedFrom(snapshot));
    // 持久化键是格式契约：改名等于改格式（见 sync_state_codec.dart）。
    expect(encoded['stampSeq'], {
      'physical': book.stampBaseline.physical,
      'counter': book.stampBaseline.counter,
    });
    expect(encoded['settings'], contains('theme'));
    expect(encoded['scriptStamps'], contains('lx-a'));
    expect(encoded['scriptTombstones'], contains('lx-b'));
    expect(encoded['knownScripts'], ['lx-a']);
    expect(encoded['activeScript'], isNotNull);
    expect(encoded['sessionStamp'], isNotNull);
    expect(encoded['coverStamps'], contains('wy:1'));
    expect(encoded['coverTombstones'], contains('wy:2'));

    final wire = jsonDecode(jsonEncode(encoded)) as Map<String, dynamic>;
    final decoded = SyncStateCodec.decode(wire)!;
    final restored = SyncStampBook(
      clock: () => now,
      deviceId: () => 'devA',
      onChanged: () {},
    )..applyState(_bookStateFrom(decoded));

    expect(restored.stampBaseline, book.stampBaseline);
    expect(restored.settingStamps['theme']!.hash, 'h-theme');
    expect(restored.scriptStamps['lx-a']!.hash, 'h-script');
    expect(restored.scriptTombstones['lx-b']!.version.counter, 3);
    expect(restored.knownScriptIds, ['lx-a']);
    expect(restored.activeScriptStamp!.hash, 'h-active');
    expect(restored.sessionStamp!.version.counter, 5);
    expect(restored.coverStamps['wy:1']!.hash, 'h-cover');
    expect(restored.coverTombstones['wy:2']!.version.counter, 7);
  });
}

/// 账本切片 → 持久化快照（存储层 `_snapshot()` 的同形映射）。
SyncPersistedState _persistedFrom(SyncStampBookState stamps) =>
    SyncPersistedState(
      stampBaseline: stamps.stampBaseline,
      settingStamps: stamps.settingStamps,
      scriptTombstones: stamps.scriptTombstones,
      scriptStamps: stamps.scriptStamps,
      knownScriptIds: stamps.knownScriptIds,
      activeScriptStamp: stamps.activeScriptStamp,
      sessionStamp: stamps.sessionStamp,
      coverStamps: stamps.coverStamps,
      coverTombstones: stamps.coverTombstones,
    );

/// 持久化快照 → 账本切片（存储层 `_applyState()` 的同形映射）。
SyncStampBookState _bookStateFrom(SyncPersistedState state) =>
    SyncStampBookState(
      stampBaseline: state.stampBaseline,
      settingStamps: state.settingStamps,
      scriptTombstones: state.scriptTombstones,
      scriptStamps: state.scriptStamps,
      knownScriptIds: state.knownScriptIds,
      activeScriptStamp: state.activeScriptStamp,
      sessionStamp: state.sessionStamp,
      coverStamps: state.coverStamps,
      coverTombstones: state.coverTombstones,
    );
