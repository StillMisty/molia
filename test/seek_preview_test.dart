import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/widgets/seek_bar.dart';
import 'package:molia/widgets/seek_preview.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 进度拖动预览：状态机（时序语义的唯一实现，播放页与桌面底栏共用）
/// 与渲染面（预览优先取值 / 波浪⇄平直 / 侧时间文字）的行为钉死。
void main() {
  group('SeekPreviewController', () {
    late ValueNotifier<Duration> position;
    late ChangeNotifier trackChanges;
    late TrackId? currentId;
    late List<int> seeks;
    late SeekPreviewController controller;
    var disposed = false;

    setUp(() {
      disposed = false;
      position = ValueNotifier(Duration.zero);
      trackChanges = ChangeNotifier();
      currentId = const TrackId('tx', 'a');
      seeks = [];
      controller = SeekPreviewController(
        position: position,
        trackChanges: trackChanges,
        currentTrackId: () => currentId,
        seek: seeks.add,
      );
    });

    tearDown(() {
      if (!disposed) controller.dispose();
      position.dispose();
      trackChanges.dispose();
    });

    test('提交后保留预览，position 追上（容差内）才撤下', () {
      controller.preview(5000);
      controller.commit();
      expect(controller.previewMs.value, 5000);
      expect(seeks, [5000]);

      position.value = const Duration(milliseconds: 4600);
      expect(controller.previewMs.value, isNull);
    });

    test('容差外不回撤预览，差值落到容差即撤下', () {
      controller.preview(5000);
      controller.commit();
      position.value = const Duration(milliseconds: 4000);
      expect(controller.previewMs.value, 5000);

      position.value = const Duration(milliseconds: 4200);
      expect(controller.previewMs.value, isNull);
    });

    test('超时兜底撤下预览', () {
      fakeAsync((async) {
        controller.preview(5000);
        controller.commit();
        async.elapse(const Duration(milliseconds: 1499));
        expect(controller.previewMs.value, 5000);
        async.elapse(const Duration(milliseconds: 1));
        expect(controller.previewMs.value, isNull);
      });
    });

    test('新拖动作废上一次等待落点与兜底计时器', () {
      fakeAsync((async) {
        controller.preview(5000);
        controller.commit();
        controller.preview(8000);
        // 旧目标已作废：position 追上旧落点也不撤预览。
        position.value = const Duration(milliseconds: 5000);
        expect(controller.previewMs.value, 8000);
        async.elapse(SeekPreviewController.fallbackTimeout);
        expect(controller.previewMs.value, 8000);
      });
    });

    test('无预览时提交是空操作（值没变 / 交互被取消）', () {
      controller.commit();
      expect(seeks, isEmpty);
      expect(controller.previewMs.value, isNull);
    });

    test('曲目身份变化撤下预览，同曲目的其它通知不撤', () {
      controller.preview(8000);
      trackChanges.notifyListeners();
      expect(controller.previewMs.value, 8000);

      currentId = const TrackId('tx', 'b');
      trackChanges.notifyListeners();
      expect(controller.previewMs.value, isNull);
    });

    test('dispose 取消兜底计时器且不再响应事件', () {
      fakeAsync((async) {
        controller.preview(5000);
        controller.commit();
        controller.dispose();
        disposed = true;
        // 兜底计时器已取消：超时后不会回写已 dispose 的预览 notifier。
        async.elapse(const Duration(seconds: 3));
        // 监听已摘：dispose 后的 position / 换曲事件不再触发回写。
        position.value = const Duration(milliseconds: 5000);
        currentId = const TrackId('tx', 'b');
        trackChanges.notifyListeners();
      });
    });
  });

  group('SeekBar', () {
    late ValueNotifier<Duration> position;
    late ChangeNotifier trackChanges;
    late SeekPreviewController controller;
    late List<int> seeks;

    setUp(() {
      position = ValueNotifier(const Duration(seconds: 5));
      trackChanges = ChangeNotifier();
      seeks = [];
      controller = SeekPreviewController(
        position: position,
        trackChanges: trackChanges,
        currentTrackId: () => const TrackId('tx', 'a'),
        seek: seeks.add,
      );
    });

    tearDown(() {
      controller.dispose();
      position.dispose();
      trackChanges.dispose();
    });

    Future<void> pumpBar(
      WidgetTester tester, {
      bool isPlaying = true,
      bool hasTrack = true,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SeekBar(
              controller: controller,
              position: position,
              durationMs: 30000,
              isPlaying: isPlaying,
              hasTrack: hasTrack,
            ),
          ),
        ),
      );
    }

    M3ESlider slider(WidgetTester tester) =>
        tester.widget<M3ESlider>(find.byType(M3ESlider));

    testWidgets('播放中波浪、暂停平直', (tester) async {
      await pumpBar(tester, isPlaying: true);
      expect(slider(tester).wavy, isTrue);

      await pumpBar(tester, isPlaying: false);
      expect(slider(tester).wavy, isFalse);
    });

    testWidgets('拖动预览值优先于 position 通道', (tester) async {
      await pumpBar(tester);
      controller.preview(20000);
      await tester.pump();
      expect(slider(tester).value, 20000);
    });

    testWidgets('快速单击直接跳点到点击位置', (tester) async {
      await pumpBar(tester);
      final rect = tester.getRect(find.byType(M3ESlider));
      // tester.tapAt 的 down / up 之间不 pump，与真机 <100ms 的快速单击同一条
      // 时序：M3ESlider 的 onTapDown / onTapUp 落在同一次事件分发里，中间没有
      // 重建，它的 onChangeEnd 只能回传上一帧的 value（= 点击前的位置）。
      await tester.tapAt(Offset(rect.left + rect.width * 0.75, rect.center.dy));

      expect(seeks, hasLength(1));
      expect(seeks.single, closeTo(30000 * 0.75, 1000));
      expect(controller.previewMs.value, closeTo(30000 * 0.75, 1000));

      // 松手后的保留窗口（1500ms 兜底）跑完，避免用例结束报 pending timer。
      await tester.pump(const Duration(milliseconds: 1600));
    });

    testWidgets('无曲目禁用且侧时间显示占位', (tester) async {
      await pumpBar(tester, hasTrack: false);
      final widget = slider(tester);
      expect(widget.enabled, isFalse);
      expect(widget.onChanged, isNull);
      expect(find.text('--:--'), findsNWidgets(2));
    });

    testWidgets('侧时间文字显示当前值与总时长', (tester) async {
      await pumpBar(tester);
      expect(find.text('0:05'), findsOneWidget);
      expect(find.text('0:30'), findsOneWidget);
    });
  });
}
