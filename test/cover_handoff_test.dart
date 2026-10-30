import 'package:flutter/animation.dart' show Curves;
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/track.dart';
import 'package:molia/widgets/cover_handoff.dart';

/// 接管代数单测：不挂 widget，直接锁定 deck 渲染所依赖的数值语义
/// （连续/重启/链式/尾巴/窗口与淡入反解）。
Track _track(String id) => Track(
  id: TrackId('fake', id),
  title: 'Title $id',
  artists: [Artist(name: 'Artist $id')],
  album: 'Album',
  duration: const Duration(seconds: 30),
  origin: TrackOrigin.lx,
  payload: {'id': id},
);

const double _sideOffset = 72;

void _expectVisual(
  CoverHandoffVisual actual, {
  required double x,
  required double rotation,
  required double scale,
  required double opacity,
}) {
  expect(actual.x, closeTo(x, 1e-9));
  expect(actual.rotation, closeTo(rotation, 1e-9));
  expect(actual.scale, closeTo(scale, 1e-9));
  expect(actual.opacity, closeTo(opacity, 1e-9));
}

void main() {
  final a = _track('a');
  final b = _track('b');
  final c = _track('c');

  group('连续接管（continuous）', () {
    test('qAt 把 p0 映射到剩余行程起点', () {
      final handoff = CoverHandoff(
        kind: CoverHandoffKind.continuous,
        p0: 0.3,
        direction: 1,
        previousCenterTrack: a,
      );
      expect(handoff.qAt(0.2), 0);
      expect(handoff.qAt(0.3), 0);
      expect(handoff.qAt(0.65), closeTo(0.5, 1e-9));
      expect(handoff.qAt(1), 1);
      expect(handoff.isContinuous, isTrue);
    });

    test('p0 与常规公式重合，中段/终点按 q 插值到侧槽', () {
      const double p0 = 0.3;
      final CoverHandoffVisual from = coverRegularCenterVisual(
        p0,
        direction: 1,
        sideOffset: _sideOffset,
      );
      // 常规公式在 p0 的手算值：位移 72×0.7、倾角 0.05×0.7、
      // 缩放 0.78+0.22×0.3、透明度 0.85+0.15×0.3。
      _expectVisual(
        from,
        x: 50.4,
        rotation: 0.035,
        scale: 0.846,
        opacity: 0.895,
      );
      final handoff = CoverHandoff(
        kind: CoverHandoffKind.continuous,
        p0: p0,
        direction: 1,
        previousCenterTrack: a,
        outgoingFrom: from,
      );
      // 接管帧：滑出卡就是上一段中心卡，无跳变。
      _expectVisual(
        coverHandoffOutgoingVisual(handoff, p0, sideOffset: _sideOffset),
        x: 50.4,
        rotation: 0.035,
        scale: 0.846,
        opacity: 0.895,
      );
      // 剩余行程中点 q=0.5：从捕获视觉线性走到左槽。
      _expectVisual(
        coverHandoffOutgoingVisual(handoff, 0.65, sideOffset: _sideOffset),
        x: (50.4 - _sideOffset) / 2,
        rotation: (0.035 - coverHandoffSideRotation) / 2,
        scale: (0.846 + coverHandoffSideSlotScale) / 2,
        opacity: (0.895 + coverHandoffNeighborOpacity) / 2,
      );
      // 终点与稳态侧槽卡完全重合。
      _expectVisual(
        coverHandoffOutgoingVisual(handoff, 1, sideOffset: _sideOffset),
        x: -_sideOffset,
        rotation: -coverHandoffSideRotation,
        scale: coverHandoffSideSlotScale,
        opacity: coverHandoffNeighborOpacity,
      );
      // 未捕获新中心起点时，中心继续走全局公式（p0 / 中段 / 落位）。
      _expectVisual(
        coverCenterVisualAt(
          handoff: handoff,
          centerTrack: b,
          progress: p0,
          direction: 1,
          sideOffset: _sideOffset,
        ),
        x: 50.4,
        rotation: 0.035,
        scale: 0.846,
        opacity: 0.895,
      );
      _expectVisual(
        coverCenterVisualAt(
          handoff: handoff,
          centerTrack: b,
          progress: 0.65,
          direction: 1,
          sideOffset: _sideOffset,
        ),
        x: 72 * 0.35,
        rotation: 0.05 * 0.35,
        scale: 0.78 + 0.22 * 0.65,
        opacity: 0.85 + 0.15 * 0.65,
      );
      _expectVisual(
        coverCenterVisualAt(
          handoff: handoff,
          centerTrack: b,
          progress: 1,
          direction: 1,
          sideOffset: _sideOffset,
        ),
        x: 0,
        rotation: 0,
        scale: 1,
        opacity: 1,
      );
    });

    test('捕获的 source neighbor 中心从侧槽实际视觉接管到中心', () {
      final CoverHandoffVisual source = coverSourceNeighborVisual(
        direction: 1,
        sideOffset: _sideOffset,
        opacity: 0.4,
      );
      _expectVisual(
        source,
        x: _sideOffset,
        rotation: coverHandoffSideRotation,
        scale: coverHandoffSideSlotScale,
        opacity: 0.4,
      );
      final handoff = CoverHandoff(
        kind: CoverHandoffKind.continuous,
        p0: 0.6,
        direction: 1,
        previousCenterTrack: a,
        centerFrom: source,
        centerFromTrack: b,
      );
      _expectVisual(
        coverHandoffCenterVisual(handoff, 0.6)!,
        x: _sideOffset,
        rotation: coverHandoffSideRotation,
        scale: coverHandoffSideSlotScale,
        opacity: 0.4,
      );
      _expectVisual(
        coverHandoffCenterVisual(handoff, 0.8)!,
        x: _sideOffset / 2,
        rotation: coverHandoffSideRotation / 2,
        scale: (coverHandoffSideSlotScale + 1) / 2,
        opacity: 0.7,
      );
      _expectVisual(
        coverHandoffCenterVisual(handoff, 1)!,
        x: 0,
        rotation: 0,
        scale: 1,
        opacity: 1,
      );
    });
  });

  group('链式查询', () {
    test('只有捕获过的同一身份才用 override，其余退回全局公式', () {
      final CoverHandoffVisual capturedCenter = coverSourceNeighborVisual(
        direction: 1,
        sideOffset: _sideOffset,
        opacity: 0.3,
      );
      final handoff = CoverHandoff(
        kind: CoverHandoffKind.continuous,
        p0: 0.6,
        direction: 1,
        previousCenterTrack: a,
        centerFrom: capturedCenter,
        centerFromTrack: b,
      );
      // 同一身份（不同 Track 实例、同 id）→ 捕获视觉。
      _expectVisual(
        coverCenterVisualAt(
          handoff: handoff,
          centerTrack: _track('b'),
          progress: 0.8,
          direction: 1,
          sideOffset: _sideOffset,
        ),
        x: _sideOffset / 2,
        rotation: coverHandoffSideRotation / 2,
        scale: (coverHandoffSideSlotScale + 1) / 2,
        opacity: 0.65,
      );
      // 不同身份 → 常规全局公式，不能把别人的捕获位置套过来。
      final CoverHandoffVisual global = coverCenterVisualAt(
        handoff: handoff,
        centerTrack: c,
        progress: 0.8,
        direction: 1,
        sideOffset: _sideOffset,
      );
      _expectVisual(
        global,
        x: _sideOffset * 0.2,
        rotation: coverHandoffSideRotation * 0.2,
        scale: coverHandoffSideSlotScale + 0.22 * 0.8,
        opacity: 0.85 + 0.15 * 0.8,
      );
      // 无接管快照 → 公式。
      expect(
        coverCenterVisualAt(
          handoff: null,
          centerTrack: b,
          progress: 0.8,
          direction: 1,
          sideOffset: _sideOffset,
        ),
        global,
      );
    });
  });

  group('restart 接管', () {
    test('两端都从捕获视觉起步，按新弹簧 p 走到中心/侧槽', () {
      const capturedCenter = CoverHandoffVisual(
        x: 30,
        rotation: 0.02,
        scale: 0.9,
        opacity: 0.95,
      );
      const capturedOutgoing = CoverHandoffVisual(
        x: -40,
        rotation: -0.03,
        scale: 0.84,
        opacity: 0.9,
      );
      final handoff = CoverHandoff(
        kind: CoverHandoffKind.restart,
        p0: 0,
        direction: -1,
        previousCenterTrack: b,
        outgoingFrom: capturedCenter,
        centerFrom: capturedOutgoing,
        centerFromTrack: a,
      );
      expect(handoff.qAt(0), 0);
      expect(handoff.qAt(0.25), 0.25);
      expect(handoff.qAt(1.4), 1);
      // p=0：旧中心 B 停在捕获位置，新中心 A 接住旧滑出卡位置。
      _expectVisual(
        coverHandoffOutgoingVisual(handoff, 0, sideOffset: _sideOffset),
        x: 30,
        rotation: 0.02,
        scale: 0.9,
        opacity: 0.95,
      );
      _expectVisual(
        coverHandoffCenterVisual(handoff, 0)!,
        x: -40,
        rotation: -0.03,
        scale: 0.84,
        opacity: 0.9,
      );
      // p=0.5：两端各走一半。
      _expectVisual(
        coverHandoffOutgoingVisual(handoff, 0.5, sideOffset: _sideOffset),
        x: (30 + _sideOffset) / 2,
        rotation: (0.02 + coverHandoffSideRotation) / 2,
        scale: (0.9 + coverHandoffSideSlotScale) / 2,
        opacity: (0.95 + coverHandoffNeighborOpacity) / 2,
      );
      _expectVisual(
        coverHandoffCenterVisual(handoff, 0.5)!,
        x: -20,
        rotation: -0.015,
        scale: 0.92,
        opacity: 0.95,
      );
      // p=1：滑出卡到目标侧槽（方向 -1 = 右侧），新中心落位。
      _expectVisual(
        coverHandoffOutgoingVisual(handoff, 1, sideOffset: _sideOffset),
        x: _sideOffset,
        rotation: coverHandoffSideRotation,
        scale: coverHandoffSideSlotScale,
        opacity: coverHandoffNeighborOpacity,
      );
      _expectVisual(
        coverHandoffCenterVisual(handoff, 1)!,
        x: 0,
        rotation: 0,
        scale: 1,
        opacity: 1,
      );
    });
  });

  group('tail 离场', () {
    test('按剩余行程滑出并淡出，终点越过侧槽、不会回摆', () {
      final tail = CoverHandoffTail(
        track: a,
        p0: 0.4,
        direction: 1,
        from: const CoverHandoffVisual(
          x: 0,
          rotation: 0,
          scale: 1,
          opacity: 0.9,
        ),
      );
      expect(
        tail.visualAt(0.4, sideOffset: _sideOffset, fadeSpan: 0.45),
        const CoverHandoffVisual(x: 0, rotation: 0, scale: 1, opacity: 0.9),
      );
      // q=0.5：easeOut(0.5) 的滑动；淡出已走完（0.5/0.45 > 1）。
      final double slide = Curves.easeOut.transform(0.5);
      _expectVisual(
        tail.visualAt(0.7, sideOffset: _sideOffset, fadeSpan: 0.45),
        x: -_sideOffset * 1.15 * slide,
        rotation: -coverHandoffSideRotation * 1.15 * slide,
        scale: 1 - 0.3 * slide,
        opacity: 0,
      );
      // 终点：越过侧槽（-72）继续向外，不回摆，完全透明。
      final CoverHandoffVisual end = tail.visualAt(
        1,
        sideOffset: _sideOffset,
        fadeSpan: 0.45,
      );
      _expectVisual(
        end,
        x: -_sideOffset * 1.15,
        rotation: -coverHandoffSideRotation * 1.15,
        scale: 0.70,
        opacity: 0,
      );
      expect(end.x, lessThan(-_sideOffset));

      double previousX = double.infinity;
      double previousOpacity = double.infinity;
      for (var i = 0; i <= 20; i++) {
        final CoverHandoffVisual step = tail.visualAt(
          0.4 + 0.6 * i / 20,
          sideOffset: _sideOffset,
          fadeSpan: 0.45,
        );
        expect(
          step.x,
          lessThanOrEqualTo(previousX + 1e-9),
          reason: 'tail 只能继续远离中心，不能回摆进入侧槽窗口',
        );
        expect(step.opacity, lessThanOrEqualTo(previousOpacity + 1e-9));
        if (i >= 10) expect(step.opacity, 0);
        previousX = step.x;
        previousOpacity = step.opacity;
      }
    });

    test('rebased 以当前渲染值为新起点继续离场', () {
      final tail = CoverHandoffTail(
        track: a,
        p0: 0.4,
        direction: 1,
        from: const CoverHandoffVisual(
          x: 20,
          rotation: 0.01,
          scale: 0.9,
          opacity: 0.8,
        ),
      );
      final CoverHandoffVisual atRebase = tail.visualAt(
        0.6,
        sideOffset: _sideOffset,
        fadeSpan: 0.45,
      );
      final revased = tail.rebased(p0: 0, visual: atRebase);
      expect(
        revased.visualAt(0, sideOffset: _sideOffset, fadeSpan: 0.45),
        atRebase,
      );
      expect(
        revased.visualAt(1, sideOffset: _sideOffset, fadeSpan: 0.45).x,
        lessThan(-_sideOffset),
      );
    });

    test('常规滑出卡捕获成 tail 时沿用中心运动公式', () {
      final tail = coverHandoffTailFromRegularOutgoing(
        track: a,
        p0: 0.3,
        direction: 1,
        sideOffset: _sideOffset,
      );
      _expectVisual(
        tail.from,
        x: -_sideOffset * 0.3,
        rotation: -coverHandoffSideRotation * 0.3,
        scale: 1 - 0.22 * 0.3,
        opacity: 1 - 0.15 * 0.3,
      );
    });

    test('接管滑出卡捕获 tail：淡出到 0 时丢弃，否则沿用捕获身份', () {
      final handoff = CoverHandoff(
        kind: CoverHandoffKind.restart,
        p0: 0,
        direction: -1,
        previousCenterTrack: b,
        outgoingFrom: const CoverHandoffVisual(
          x: 10,
          rotation: 0,
          scale: 1,
          opacity: 0.5,
        ),
      );
      final tail = coverHandoffTailFromOutgoingHandoff(
        handoff,
        0.5,
        sideOffset: _sideOffset,
      );
      expect(tail, isNotNull);
      expect(tail!.track, b);
      expect(tail.p0, 0.5);
      expect(tail.direction, -1);
      final faded = CoverHandoff(
        kind: CoverHandoffKind.restart,
        p0: 0,
        direction: -1,
        previousCenterTrack: b,
        outgoingFrom: const CoverHandoffVisual(
          x: 10,
          rotation: 0,
          scale: 1,
          opacity: 0,
        ),
      );
      expect(
        coverHandoffTailFromOutgoingHandoff(faded, 0, sideOffset: _sideOffset),
        isNull,
      );
    });
  });

  group('常规公式与窗口', () {
    test('滑出卡公式在起手/中途/终点/过冲的值', () {
      _expectVisual(
        coverRegularOutgoingVisual(0, direction: 1, sideOffset: _sideOffset),
        x: 0,
        rotation: 0,
        scale: 1,
        opacity: 1,
      );
      _expectVisual(
        coverRegularOutgoingVisual(0.5, direction: 1, sideOffset: _sideOffset),
        x: -36,
        rotation: -0.025,
        scale: 0.89,
        opacity: 0.925,
      );
      _expectVisual(
        coverRegularOutgoingVisual(1, direction: 1, sideOffset: _sideOffset),
        x: -_sideOffset,
        rotation: -coverHandoffSideRotation,
        scale: coverHandoffSideSlotScale,
        opacity: coverHandoffNeighborOpacity,
      );
      // 弹簧过冲：几何保留过冲，透明度截断（M3E effects 不过冲）。
      _expectVisual(
        coverRegularOutgoingVisual(1.1, direction: 1, sideOffset: _sideOffset),
        x: -_sideOffset * 1.1,
        rotation: -coverHandoffSideRotation * 1.1,
        scale: 0.78 - 0.022,
        opacity: coverHandoffNeighborOpacity,
      );
      // 反向只翻转水平位移与倾角。
      _expectVisual(
        coverRegularOutgoingVisual(0.5, direction: -1, sideOffset: _sideOffset),
        x: 36,
        rotation: 0.025,
        scale: 0.89,
        opacity: 0.925,
      );
    });

    test('中心公式在过冲时同样截断透明度', () {
      _expectVisual(
        coverRegularCenterVisual(1.1, direction: 1, sideOffset: _sideOffset),
        x: -_sideOffset * 0.1,
        rotation: -coverHandoffSideRotation * 0.1,
        scale: 0.78 + 0.22 * 1.1,
        opacity: 1,
      );
    });

    test('旧身份窗口 p∈[0,0.4] 内 easeOut 淡出，之后保持 0', () {
      expect(coverOldNeighborOpacityAt(0), coverHandoffNeighborOpacity);
      expect(
        coverOldNeighborOpacityAt(0.2),
        closeTo(
          coverHandoffNeighborOpacity * (1 - Curves.easeOut.transform(0.5)),
          1e-9,
        ),
      );
      expect(coverOldNeighborOpacityAt(0.4), 0);
      expect(coverOldNeighborOpacityAt(0.8), 0);
    });

    test('源侧新身份窗口 p∈[0.6,1] 内 easeInOut 淡入', () {
      expect(coverSourceNewNeighborOpacityAt(0.5), 0);
      expect(coverSourceNewNeighborOpacityAt(0.6), 0);
      expect(
        coverSourceNewNeighborOpacityAt(0.8),
        closeTo(
          coverHandoffNeighborOpacity * Curves.easeInOut.transform(0.5),
          1e-9,
        ),
      );
      expect(coverSourceNewNeighborOpacityAt(1), coverHandoffNeighborOpacity);
    });
  });

  group('sourceFadeStartFor 反解', () {
    test('easeOut 透明度往返（含端点夹取）', () {
      for (final t in <double>[0, 0.1, 0.25, 0.5, 0.75, 0.9, 1]) {
        final double preview =
            coverHandoffNeighborOpacity * Curves.easeOut.transform(t);
        final double start = coverSourceFadeStartFor(preview);
        // Curves.easeOut 内部按 0.001 精度求值，反解容差随之为 5e-3。
        expect(start, closeTo(t, 5e-3), reason: 't=$t');
        expect(
          coverHandoffNeighborOpacity * Curves.easeOut.transform(start),
          closeTo(preview, 5e-3),
        );
      }
      expect(coverSourceFadeStartFor(-0.2), 0);
      expect(coverSourceFadeStartFor(0), 0);
      expect(coverSourceFadeStartFor(coverHandoffNeighborOpacity), 1);
      expect(coverSourceFadeStartFor(2), 1);
      // 自定义邻位端点同样按比例反解。
      final double customPreview = 0.5 * Curves.easeOut.transform(0.4);
      expect(
        coverSourceFadeStartFor(customPreview, neighborOpacity: 0.5),
        closeTo(0.4, 5e-3),
      );
    });
  });

  group('视觉插值', () {
    test('线性插值与端点', () {
      const from = CoverHandoffVisual(
        x: -10,
        rotation: 0.1,
        scale: 0.5,
        opacity: 0.25,
      );
      const to = CoverHandoffVisual(
        x: 30,
        rotation: -0.1,
        scale: 1.5,
        opacity: 0.75,
      );
      _expectVisual(
        CoverHandoffVisual.lerp(from, to, 0.25),
        x: 0,
        rotation: 0.05,
        scale: 0.75,
        opacity: 0.375,
      );
      expect(CoverHandoffVisual.lerp(from, to, 0), from);
      expect(CoverHandoffVisual.lerp(from, to, 1), to);
    });
  });
}
