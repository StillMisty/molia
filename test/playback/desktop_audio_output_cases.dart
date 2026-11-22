import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/playback/desktop_audio_output_port_io.dart';
import 'package:molia/playback/pactl_sink_events.dart';
import 'package:molia/playback/pactl_sink_tracker.dart';

/// 桌面输出监听的两块可测逻辑：`pactl` 行解析（纯函数）与平台通道端口
/// （假 MethodChannel，不碰真实原生）。ADR-0036。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pactl subscribe 行解析', () {
    test('remove sink 是输出丢失候选', () {
      final event = parsePactlEvent("Event 'remove' on sink #42");
      expect(event, isNotNull);
      expect(event!.kind, PactlEventKind.removed);
      expect(event.facility, 'sink');
      expect(event.id, 42);
      expect(event.isSinkRemoved, isTrue);
    });

    test('remove source / sink-input 不是输出丢失', () {
      for (final line in [
        "Event 'remove' on source #7",
        "Event 'remove' on sink-input #9",
        "Event 'remove' on source-output #11",
      ]) {
        final event = parsePactlEvent(line);
        expect(event, isNotNull, reason: line);
        expect(event!.isSinkRemoved, isFalse, reason: line);
      }
    });

    test('new / change 只表示设备或默认值变化', () {
      final event = parsePactlEvent("Event 'change' on server");
      expect(event!.kind, PactlEventKind.changed);
      expect(event.facility, 'server');
      expect(event.id, isNull);
      expect(event.isSinkRemoved, isFalse);
      expect(
        parsePactlEvent("Event 'new' on sink #3")!.kind,
        PactlEventKind.added,
      );
    });

    test('未知事件名 / 未知对象类型不抛异常', () {
      expect(
        parsePactlEvent("Event 'move' on sink #1")!.kind,
        PactlEventKind.unknown,
      );
      expect(parsePactlEvent("Event 'change' on card #2")!.facility, 'card');
    });

    test('CRLF、额外空白与空行', () {
      expect(parsePactlEvent("Event 'remove' on sink #5\r")!.id, 5);
      expect(parsePactlEvent("  Event  'change'   on   sink   #6  ")!.id, 6);
      expect(parsePactlEvent(''), isNull);
      expect(parsePactlEvent('   '), isNull);
    });

    test('损坏行返回 null', () {
      for (final line in [
        'garbage',
        "Event '' on sink #1",
        "Event 'remove' on",
        "Event 'remove' sink #1",
        "Event 'remove' on sink #",
        "Event 'remove' on sink #999999999999999999999999",
      ]) {
        expect(parsePactlEvent(line), isNull, reason: line);
      }
    });

    test('大 id 正常解析', () {
      final event = parsePactlEvent("Event 'remove' on sink #4294967295");
      expect(event!.id, 4294967295);
    });
  });

  group('PactlSinkTracker 默认 sink 决策', () {
    PactlSinkTracker trackerWith({
      String? defaultSink,
      Map<int, String> sinks = const {},
    }) {
      final tracker = PactlSinkTracker();
      tracker.applySnapshot(
        PactlSinkSnapshot(sinkNamesById: sinks, defaultSink: defaultSink),
      );
      return tracker;
    }

    test('默认 sink 被移除：立即上报，刷新只更新快照', () {
      final tracker = trackerWith(
        defaultSink: 'alsa_output.headphones',
        sinks: {1: 'alsa_output.headphones', 2: 'alsa_output.speakers'},
      );
      final action = tracker.onEvent(
        parsePactlEvent("Event 'remove' on sink #1")!,
      );
      expect(action.emitOutputLost, isTrue);
      expect(action.refresh, isTrue);
      expect(action.notifyIfDefaultMissing, isFalse);
    });

    test('非默认 sink 被移除：不暂停，只刷新并保留兜底判定', () {
      final tracker = trackerWith(
        defaultSink: 'alsa_output.headphones',
        sinks: {1: 'alsa_output.headphones', 2: 'alsa_output.usb-dac'},
      );
      final action = tracker.onEvent(
        parsePactlEvent("Event 'remove' on sink #2")!,
      );
      expect(action.emitOutputLost, isFalse);
      expect(action.refresh, isTrue);
      expect(action.notifyIfDefaultMissing, isTrue);
    });

    test('source / sink-input 移除不是输出丢失', () {
      final tracker = trackerWith(defaultSink: 'a', sinks: {1: 'a'});
      for (final line in [
        "Event 'remove' on source #7",
        "Event 'remove' on sink-input #9",
      ]) {
        final action = tracker.onEvent(parsePactlEvent(line)!);
        expect(action.refresh, isFalse, reason: line);
        expect(action.emitOutputLost, isFalse, reason: line);
      }
    });

    test('new / change 只刷新，不暂停', () {
      final tracker = trackerWith(defaultSink: 'a', sinks: {1: 'a'});
      final sinkChange = tracker.onEvent(
        parsePactlEvent("Event 'change' on sink #1")!,
      );
      expect(sinkChange.refresh, isTrue);
      expect(sinkChange.notifyIfDefaultMissing, isFalse);
      expect(sinkChange.emitOutputLost, isFalse);

      final serverChange = tracker.onEvent(
        parsePactlEvent("Event 'change' on server")!,
      );
      expect(serverChange.refresh, isTrue);
      expect(serverChange.notifyIfDefaultMissing, isTrue);
      expect(serverChange.emitOutputLost, isFalse);
    });

    test('server change：旧默认名消失才上报', () {
      final tracker = trackerWith(defaultSink: 'a', sinks: {1: 'a', 2: 'b'});
      final action = tracker.onEvent(
        parsePactlEvent("Event 'change' on server")!,
      );
      expect(action.notifyIfDefaultMissing, isTrue);
      // 主动切到仍存活的 b：旧默认 a 还在，不暂停。
      expect(
        tracker.applySnapshot(
          const PactlSinkSnapshot(
            sinkNamesById: {1: 'a', 2: 'b'},
            defaultSink: 'b',
          ),
        ),
        isFalse,
      );
      // 旧默认 a 已从列表消失：输出丢失（用独立 tracker 保留旧状态，
      // 上一步的主动切换已经更新了默认值）。
      final lostTracker = trackerWith(
        defaultSink: 'a',
        sinks: {1: 'a', 2: 'b'},
      );
      expect(
        lostTracker.applySnapshot(
          const PactlSinkSnapshot(sinkNamesById: {2: 'b'}, defaultSink: 'b'),
        ),
        isTrue,
      );
    });

    test('默认查询失败保留上一默认值，不会永久关闭检测', () {
      final tracker = trackerWith(defaultSink: 'a', sinks: {1: 'a'});
      expect(
        tracker.applySnapshot(
          const PactlSinkSnapshot(
            sinkNamesById: {1: 'a'},
            defaultSink: null,
            defaultSinkKnown: false,
          ),
        ),
        isFalse,
      );
      expect(tracker.defaultSink, 'a');
      expect(tracker.sinkNamesById, {1: 'a'});
    });
  });

  group('桌面输出端口（Windows / macOS 通道）', () {
    for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
      test('${platform.name}：outputLost 到达流，未知方法忽略', () async {
        final channel = MethodChannel(
          desktopAudioOutputChannelName,
          const StandardMethodCodec(),
        );
        final port = DesktopAudioOutputPort(
          channel: channel,
          platform: platform,
        );
        final events = <void>[];
        final subscription = port.outputLost.listen(events.add);
        addTearDown(subscription.cancel);
        await port.start();

        await _send(channel, 'outputLost');
        await pumpEventQueue();
        expect(events, hasLength(1));

        await _send(channel, 'unrelated');
        await pumpEventQueue();
        expect(events, hasLength(1));

        await port.dispose();
        await _send(channel, 'outputLost');
        await pumpEventQueue();
        expect(events, hasLength(1), reason: 'dispose 后不再产生事件');
      });
    }

    test('supported 为 false 但声明会产 outputLost（服务据此订阅）', () {
      final port = DesktopAudioOutputPort(
        channel: MethodChannel(desktopAudioOutputChannelName),
        platform: TargetPlatform.windows,
      );
      expect(port.supported, isFalse);
      expect(port.emitsOutputLost, isTrue);
    });
  });
}

Future<void> _send(MethodChannel channel, String method) {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (_) {},
      );
}
