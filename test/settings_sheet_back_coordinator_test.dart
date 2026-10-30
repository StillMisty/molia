import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/settings/settings_sheet.dart';

void main() {
  group('SettingsSheetBackCoordinator', () {
    test('默认：弹层保持收缩，预测返回未激活', () {
      final coordinator = SettingsSheetBackCoordinator();

      expect(coordinator.sheetShrinksOnPredictiveBack, isTrue);
      expect(coordinator.predictiveBackActive, isFalse);
    });

    test('子页手势：弹层不收缩，接管后激活', () {
      final coordinator = SettingsSheetBackCoordinator();

      coordinator.beginPredictiveBack(
        canPopInnerRoute: true,
        handledByInnerRoute: true,
      );

      expect(coordinator.sheetShrinksOnPredictiveBack, isFalse);
      expect(coordinator.predictiveBackActive, isTrue);
    });

    test('首屏手势：弹层收缩，不由内层路由接管', () {
      final coordinator = SettingsSheetBackCoordinator();

      coordinator.beginPredictiveBack(canPopInnerRoute: false);

      expect(coordinator.sheetShrinksOnPredictiveBack, isTrue);
      expect(coordinator.predictiveBackActive, isFalse);
    });

    test('弹层上方还有表面：缩放归零但内层不接管（active 保持 false）', () {
      final coordinator = SettingsSheetBackCoordinator();

      coordinator.beginPredictiveBack(canPopInnerRoute: true);

      expect(
        coordinator.sheetShrinksOnPredictiveBack,
        isFalse,
        reason: '内层能 pop 时缩放归属仍是子页，避免上层表面手势带出 sheet 收缩',
      );
      expect(coordinator.predictiveBackActive, isFalse);
    });

    test('end 在整轮分发后才重置 active，收缩归属保留到下一次手势', () {
      fakeAsync((async) {
        final coordinator = SettingsSheetBackCoordinator();
        coordinator.beginPredictiveBack(
          canPopInnerRoute: true,
          handledByInnerRoute: true,
        );

        coordinator.endPredictiveBack();

        expect(
          coordinator.predictiveBackActive,
          isTrue,
          reason: '提交期间 observer 注册顺序不保证，guard 仍需读到本次归属',
        );
        expect(coordinator.sheetShrinksOnPredictiveBack, isFalse);

        async.flushMicrotasks();

        expect(coordinator.predictiveBackActive, isFalse);
        expect(
          coordinator.sheetShrinksOnPredictiveBack,
          isFalse,
          reason: '子页 pop 后弹层不得突然跳回收缩态',
        );
      });
    });

    test('下一次首屏手势重新固定收缩归属', () {
      fakeAsync((async) {
        final coordinator = SettingsSheetBackCoordinator();
        coordinator.beginPredictiveBack(
          canPopInnerRoute: true,
          handledByInnerRoute: true,
        );
        coordinator.endPredictiveBack();
        async.flushMicrotasks();

        coordinator.beginPredictiveBack(canPopInnerRoute: false);

        expect(coordinator.sheetShrinksOnPredictiveBack, isTrue);
        expect(coordinator.predictiveBackActive, isFalse);
      });
    });
  });
}
