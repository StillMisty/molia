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
    expect(harness.backend.volumes, [1.0], reason: '后端构造默认 1.0，启动加载后仍要显式下发一次');
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

  test('adjustVolume 步进并下发，clamp 到 0..1', () async {
    final harness = build();
    await harness.provider.preferencesReady;

    await harness.provider.adjustVolume(-0.05);
    expect(harness.provider.volume, closeTo(0.95, 1e-9));
    expect(harness.backend.volumes.last, closeTo(0.95, 1e-9));

    await harness.provider.setVolume(0.02);
    await harness.provider.adjustVolume(-0.05);
    expect(harness.provider.volume, 0.0, reason: '下限 clamp');
    expect(harness.backend.volumes.last, 0.0);

    final dispatched = harness.backend.volumes.length;
    await harness.provider.adjustVolume(-0.05);
    expect(
      harness.backend.volumes.length,
      dispatched,
      reason: '已到底：继续按是空转，不重复下发',
    );

    await harness.provider.setVolume(0.98);
    await harness.provider.adjustVolume(0.05);
    expect(harness.provider.volume, 1.0, reason: '上限 clamp');
    expect(harness.backend.volumes.last, 1.0);
  });

  test('静音态下 adjustVolume 解除静音并生效', () async {
    final harness = build();
    await harness.provider.preferencesReady;
    await harness.provider.setVolume(0.4);
    await harness.provider.toggleMute();
    expect(harness.provider.muted, isTrue);
    expect(harness.backend.volumes.last, 0.0);

    await harness.provider.adjustVolume(-0.05);
    expect(harness.provider.muted, isFalse, reason: '用户调音量即期望听见声音');
    expect(harness.provider.volume, closeTo(0.35, 1e-9));
    expect(harness.backend.volumes.last, closeTo(0.35, 1e-9));
  });

  test('adjustVolume 走防抖落盘：连按不逐次写盘，停手后落定', () async {
    final harness = build();
    await harness.provider.preferencesReady;
    await harness.provider.adjustVolume(-0.05);
    await harness.provider.adjustVolume(-0.05);

    final duringDebounce = build();
    await duringDebounce.provider.preferencesReady;
    expect(duringDebounce.provider.volume, 1.0, reason: '防抖窗口内不写盘');

    await Future<void>.delayed(const Duration(milliseconds: 500));
    final afterDebounce = build();
    await afterDebounce.provider.preferencesReady;
    expect(afterDebounce.provider.volume, closeTo(0.9, 1e-9));
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

  test('音量落盘防抖：拖动中的值不逐帧写盘，停手后落定', () async {
    final harness = build();
    await harness.provider.preferencesReady;
    await harness.provider.setVolume(0.4);

    // 防抖窗口内：还没写盘（滑杆拖动每帧都会走到 setVolume）。
    final duringDrag = build();
    await duringDrag.provider.preferencesReady;
    expect(duringDrag.provider.volume, 1.0, reason: '拖动中的中间值不立即落盘');

    // 停手（防抖窗口过去）后：写入，下一次启动读到。
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final afterDrag = build();
    await afterDrag.provider.preferencesReady;
    expect(afterDrag.provider.volume, closeTo(0.4, 1e-9));
  });

  test('越界值收进 0..1', () async {
    final harness = build();
    await harness.provider.preferencesReady;

    await harness.provider.setVolume(2);
    expect(harness.provider.volume, 1.0);

    await harness.provider.setVolume(-1);
    expect(harness.provider.volume, 0.0);
    expect(harness.backend.volumes.last, 0.0);
  });

  test('音量变化不进低频快照（快照契约不新增字段）', () async {
    final backend = FakePlaybackBackend();
    final facade = DefaultPlaybackFacade(backend: backend);
    final provider = buildTestPlaybackProvider(facade: facade);
    addTearDown(provider.dispose);
    await provider.preferencesReady;

    var snapshotNotifies = 0;
    facade.snapshot.addListener(() => snapshotNotifies++);

    await provider.setVolume(0.4);

    expect(provider.volume, 0.4);
    expect(snapshotNotifies, 0, reason: '音量不属于播放快照');
  });
}
