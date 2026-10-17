import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/playback/default_playback_facade.dart';
import 'package:molia/providers/playback_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

/// 应用内音量链路：provider 状态 → facade → 后端，以及设备本地持久化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 组装 provider 并记录假后端的音量下发（启动加载已并入 preferencesReady）。
  ({PlaybackProvider provider, FakePlaybackBackend backend}) build() {
    final backend = FakePlaybackBackend();
    final provider = buildTestPlaybackProvider(backend: backend);
    addTearDown(provider.dispose);
    return (provider: provider, backend: backend);
  }

  test('默认满音量、未静音；启动把有效音量下发一次', () async {
    final harness = build();
    expect(harness.provider.volume, 1.0);
    expect(harness.provider.muted, isFalse);

    await harness.provider.preferencesReady;
    expect(harness.backend.volumes, [1.0],
        reason: '后端构造默认 1.0，启动加载后仍要显式下发一次');
  });

  test('setVolume 更新值并下发到后端，通知 UI', () async {
    final harness = build();
    await harness.provider.preferencesReady;

    var notifies = 0;
    harness.provider.addListener(() => notifies++);
    await harness.provider.setVolume(0.4);

    expect(harness.provider.volume, 0.4);
    expect(harness.provider.muted, isFalse);
    expect(harness.backend.volumes.last, 0.4);
    expect(notifies, 1);
  });

  test('toggleMute 以 0 下发；取消静音恢复原音量', () async {
    final harness = build();
    await harness.provider.preferencesReady;
    await harness.provider.setVolume(0.4);

    await harness.provider.toggleMute();
    expect(harness.provider.muted, isTrue);
    expect(harness.provider.volume, 0.4, reason: '静音不改音量值');
    expect(harness.backend.volumes.last, 0.0);

    // 静音期间改音量：只更新值，不解除静音，有效音量仍为 0。
    await harness.provider.setVolume(0.7);
    expect(harness.provider.muted, isTrue);
    expect(harness.provider.volume, 0.7);
    expect(harness.backend.volumes.last, 0.0);

    await harness.provider.toggleMute();
    expect(harness.provider.muted, isFalse);
    expect(harness.backend.volumes.last, 0.7);
  });

  test('adjustVolume 静音态自动解除静音并按步进生效', () async {
    final harness = build();
    await harness.provider.preferencesReady;
    await harness.provider.setVolume(0.4);
    await harness.provider.toggleMute();

    await harness.provider.adjustVolume(0.1);

    expect(harness.provider.muted, isFalse, reason: '调整即期望听见声音');
    expect(harness.provider.volume, closeTo(0.5, 1e-9));
    expect(harness.backend.volumes.last, closeTo(0.5, 1e-9));
  });

  test('持久化往返：音量与静音在重建 provider 后恢复并下发', () async {
    final first = build();
    await first.provider.preferencesReady;
    await first.provider.setVolume(0.4);
    await first.provider.toggleMute();

    final second = build();
    await second.provider.preferencesReady;

    expect(second.provider.volume, closeTo(0.4, 1e-9));
    expect(second.provider.muted, isTrue);
    expect(second.backend.volumes, [0.0], reason: '恢复的静音态启动即压到 0');
  });

  test('越界值收进 0..1（设置与步进调整同理）', () async {
    final harness = build();
    await harness.provider.preferencesReady;

    await harness.provider.setVolume(2);
    expect(harness.provider.volume, 1.0);

    await harness.provider.setVolume(-1);
    expect(harness.provider.volume, 0.0);
    expect(harness.backend.volumes.last, 0.0);

    await harness.provider.adjustVolume(2);
    expect(harness.provider.volume, 1.0);
    expect(harness.backend.volumes.last, 1.0);
  });

  test('音量变化不进低频快照（快照契约不新增字段）', () async {
    final backend = FakePlaybackBackend();
    final facade = DefaultPlaybackFacade(backend: backend);
    final provider =
        PlaybackProvider(facade: facade, messenger: FakeMessenger());
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    var snapshotNotifies = 0;
    facade.snapshot.addListener(() => snapshotNotifies++);

    await provider.setVolume(0.4);

    expect(provider.volume, 0.4);
    expect(snapshotNotifies, 0, reason: '音量不属于播放快照');
  });
}
