import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import 'package:molia/domain/models/ai_dj.dart';
import 'package:molia/l10n/app_localizations.dart';
import 'package:molia/widgets/ai_dj_shared.dart';
import 'package:molia/widgets/ai_dj_waiting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHost(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      M3EMaterialApp(
        data: M3EThemeData.fromMaterial(ThemeData.light()),
        theme: ThemeData.light(),
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: const [Locale('zh')],
        home: Scaffold(body: child),
      ),
    );
  }

  AiDjProgress progress(
    AiDjPhase phase, {
    int done = 0,
    int total = 0,
    int targetCount = 24,
    int resolved = 0,
    int unresolved = 0,
  }) => AiDjProgress(
    phase: phase,
    done: done,
    total: total,
    targetCount: targetCount,
    resolved: resolved,
    unresolved: unresolved,
    startedAt: DateTime(2026),
  );

  test('进度副标题只保留状态和数字', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('zh'));

    expect(
      aiDjProgressSubtitle(
        l10n,
        progress(AiDjPhase.profile),
        fallbackTargetCount: 24,
        seconds: 3,
      ),
      '正在挑选 24 首 · 已等待 3 秒',
    );
    expect(
      aiDjProgressSubtitle(
        l10n,
        progress(AiDjPhase.model),
        fallbackTargetCount: 24,
        seconds: 12,
      ),
      'AI 正在选歌 · 已等待 12 秒',
    );
    expect(
      aiDjProgressSubtitle(
        l10n,
        progress(AiDjPhase.resolving, done: 8, total: 24, resolved: 6),
        fallbackTargetCount: 24,
        seconds: 12,
      ),
      '已找到 6 首 · 已等待 12 秒',
    );
    expect(
      aiDjProgressTitle(l10n, progress(AiDjPhase.resolving, total: 24)),
      '正在本地找歌',
    );
  });

  testWidgets('阶段步进显示找歌进度', (tester) async {
    await pumpHost(
      tester,
      AiDjPhaseSteps(
        progress: progress(
          AiDjPhase.resolving,
          done: 8,
          total: 24,
          resolved: 6,
        ),
      ),
    );

    expect(find.text('整理听歌偏好'), findsOneWidget);
    expect(find.text('AI 正在选歌'), findsOneWidget);
    expect(find.text('正在找歌 8/24'), findsOneWidget);
  });

  testWidgets('细进度条带无障碍语义', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpHost(
      tester,
      const AiDjThinProgress(
        value: 0.5,
        semanticLabel: '推荐生成进度',
        semanticValue: '8/24',
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final node = tester.getSemantics(find.byType(AiDjThinProgress));
    expect(node.label, '推荐生成进度');
    expect(node.value, '8/24');
    semantics.dispose();
  });
}
