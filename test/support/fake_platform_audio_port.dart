/// 记录型平台音频端口：断言配置快照、激活 / 释放顺序与 notify 标志，
/// 并让测试手动推送中断 / 耳机 / 设备事件（不触碰任何平台通道）。
library;

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:molia/playback/platform_audio_port.dart';

class FakePlatformAudioPort implements PlatformAudioPort {
  FakePlatformAudioPort({this.supported = true, this.emitsOutputLost = true});

  @override
  bool supported;

  @override
  bool emitsOutputLost;

  final List<String> calls = [];
  final List<AudioSessionConfiguration> configurations = [];
  final List<bool> deactivateNotifyOthers = [];

  int startCalls = 0;
  int configureCalls = 0;
  int activateCalls = 0;
  int deactivateCalls = 0;
  int disposeCalls = 0;

  /// 默认激活结果；[activateResults] 非空时按顺序消费（用于「先拒后允许」）。
  bool activateResult = true;
  final List<bool> activateResults = [];

  bool throwOnStart = false;
  bool throwOnConfigure = false;
  bool throwOnActivate = false;
  bool throwOnDeactivate = false;

  /// 平台激活前的观察钩子（断言「激活早于播放器 play」）。
  void Function()? onActivate;

  final StreamController<AudioInterruptionEvent> _interruptions =
      StreamController<AudioInterruptionEvent>.broadcast();
  final StreamController<void> _outputLost = StreamController<void>.broadcast();
  final StreamController<AudioDevicesChangedEvent> _deviceChanges =
      StreamController<AudioDevicesChangedEvent>.broadcast();

  @override
  Stream<AudioInterruptionEvent> get interruptions => _interruptions.stream;

  @override
  Stream<void> get outputLost => _outputLost.stream;

  @override
  Stream<AudioDevicesChangedEvent> get deviceChanges => _deviceChanges.stream;

  void emitInterruption(AudioInterruptionEvent event) =>
      _interruptions.add(event);

  void emitOutputLost() => _outputLost.add(null);

  void emitDeviceChanges(AudioDevicesChangedEvent event) =>
      _deviceChanges.add(event);

  @override
  Future<void> start() async {
    startCalls++;
    calls.add('start');
    if (throwOnStart) throw StateError('start failed');
  }

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configureCalls++;
    calls.add('configure');
    configurations.add(configuration);
    if (throwOnConfigure) throw StateError('configure failed');
  }

  @override
  Future<bool> activate() async {
    activateCalls++;
    calls.add('activate');
    onActivate?.call();
    if (throwOnActivate) throw StateError('activate failed');
    return activateResults.isEmpty
        ? activateResult
        : activateResults.removeAt(0);
  }

  @override
  Future<void> deactivate({required bool notifyOthers}) async {
    deactivateCalls++;
    deactivateNotifyOthers.add(notifyOthers);
    calls.add(notifyOthers ? 'deactivate:notify' : 'deactivate');
    if (throwOnDeactivate) throw StateError('deactivate failed');
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    calls.add('dispose');
    // 控制器由测试进程回收：在 fake_async 里关闭会让 close() 的完成微任务
    // 留在已退出的 zone，导致 tearDown 永远等不到。
  }
}
