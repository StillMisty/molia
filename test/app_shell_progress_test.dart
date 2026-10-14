import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:molia/app/app_shell.dart' as shell;

/// 顶栏（`AppBar.bottom`）进度条几何不变量。
///
/// 回归：AppBar 把 bottom 放进 `Column(spaceBetween)` 且 `PreferredSize`
/// 不给子级收紧约束——不钉槽高时，暂停用的平直进度条（自身 4dp）会底对齐、
/// 比播放中的波浪进度条（自身 10dp）低 3dp，点 play/pause 整条跳变。
void main() {
  /// 复现真实宿主约束：AppBar + `PreferredSize(10)` 的 bottom 槽。
  Future<Rect> pumpBar(WidgetTester tester, {required bool isPlaying}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(10),
              child: shell.ProgressIndicator(
                position: const Duration(seconds: 30),
                duration: const Duration(minutes: 2).inMilliseconds.toDouble(),
                isPlaying: isPlaying,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.getRect(find.byType(M3EProgressIndicator));
  }

  testWidgets('播放 / 暂停两态几何完全一致', (tester) async {
    final playing = await pumpBar(tester, isPlaying: true);
    final paused = await pumpBar(tester, isPlaying: false);

    expect(playing.height, 10, reason: '波浪态占满槽高');
    expect(paused, playing, reason: '平直态必须与波浪态同槽心');
  });
}
