import 'package:flutter_test/flutter_test.dart';
import 'package:molia/widgets/track_row.dart';
import 'package:molia/widgets/track_table_header.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

/// 宽屏表格表头：列标题与列构成由行内同一份 `TrackRowColumnSpec` 决定，
/// 左缘与行内列逐列对齐（对齐靠行内网格的 token 复刻：表面内边距、封面位、
/// 列间距、行尾槽宽）。
///
/// 这里同时钉住「播放时间列」只有历史档才有：规范里 `timeWidth = 0`
/// 即整套表格不含该列（表头与行同步消失，不会一侧有列一侧没有）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 表头与一行同宽并排（同一横向页边距），用于逐列比较左缘。
  Future<void> pumpHeaderWithRow(
    WidgetTester tester,
    TrackRowColumnSpec spec,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: TrackTableHeader(spec: spec),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: TrackRow(
                  model: const TrackRowModel(
                    title: 'Title',
                    artistNames: ['Col Artist'],
                    album: 'Col Album',
                    time: '10-18',
                    durationMs: 185000,
                  ),
                  surface: TrackRowSurface(tableSpec: spec),
                  position: M3ECardPosition.first,
                  onTap: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 表头某一列与该列在行内的左缘相同：错位即行内网格（内边距 / 封面位 /
  /// 列间距 / 槽宽）与表头两边不同源。
  void expectColumnAligned(WidgetTester tester, String label, String cell) {
    expect(
      tester.getTopLeft(find.text(cell)).dx,
      tester.getTopLeft(find.text(label)).dx,
      reason: '$label 列左缘与行内 $cell 不一致',
    );
  }

  testWidgets('表头高度 = 预声明 extent（钉住表头的 sliver 与之同值）', (tester) async {
    await pumpHeaderWithRow(tester, TrackRowColumnSpec.standard);

    expect(
      tester.getSize(find.byType(TrackTableHeader)).height,
      TrackTableHeader.extentOf(tester.element(find.byType(TrackTableHeader))),
    );
  });

  testWidgets('默认档：三列标题，列左缘与行内列逐列对齐', (tester) async {
    await pumpHeaderWithRow(tester, TrackRowColumnSpec.standard);

    expect(find.text('艺术家'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('时长'), findsOneWidget);
    expect(find.text('播放时间'), findsNothing, reason: '默认档没有时间列');

    expectColumnAligned(tester, '艺术家', 'Col Artist');
    expectColumnAligned(tester, '专辑', 'Col Album');
    expectColumnAligned(tester, '时长', '3:05');
  });

  testWidgets('历史档：多出播放时间列，四列左缘仍与行内列对齐', (tester) async {
    await pumpHeaderWithRow(tester, TrackRowColumnSpec.history);

    expect(find.text('播放时间'), findsOneWidget);

    expectColumnAligned(tester, '艺术家', 'Col Artist');
    expectColumnAligned(tester, '专辑', 'Col Album');
    expectColumnAligned(tester, '播放时间', '10-18');
    expectColumnAligned(tester, '时长', '3:05');
  });

  testWidgets('表头列宽与规范一致（换规范 = 换列宽，两处同源）', (tester) async {
    await pumpHeaderWithRow(tester, TrackRowColumnSpec.history);

    expect(
      tester.getSize(find.text('播放时间')).width,
      TrackRowColumnSpec.history.timeWidth,
    );
    expect(
      tester.getSize(find.text('艺术家')).width,
      TrackRowColumnSpec.history.artistWidth,
    );
    expect(
      tester.getSize(find.text('10-18')).width,
      TrackRowColumnSpec.history.timeWidth,
    );

    await pumpHeaderWithRow(tester, TrackRowColumnSpec.standard);
    expect(
      tester.getSize(find.text('艺术家')).width,
      TrackRowColumnSpec.standard.artistWidth,
    );
    expect(find.text('播放时间'), findsNothing);
  });
}
