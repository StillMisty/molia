/// AI 推歌共享 UI 逻辑：隐私确认弹窗（AI 页）+ 失败文案映射
/// （AI 页与发现页错误卡共用，避免两处漂移）。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/failure.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';

/// 首次开启前的隐私确认：未确认则弹窗，确认后落库；返回是否已确认。
Future<bool> ensureAiDjConsent(
  BuildContext context,
  AiDjProvider provider,
) async {
  if (provider.consentGranted) return true;
  final l10n = AppLocalizations.of(context)!;
  // 弹层 dialog 挂 root navigator（M3EDialog.show 语义）；AI 页位于设置弹层的
  // 嵌套 Navigator 内，页面 context 上的 pop 会误退本页，关闭要显式定向。
  final navigator = Navigator.of(context, rootNavigator: true);
  final agreed = await M3EDialog.show<bool>(
    context,
    dialog: M3EDialog(
      title: l10n.aiDjConsentTitle,
      content: SingleChildScrollView(child: Text(l10n.aiDjConsentBody)),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(false),
          child: Text(l10n.cancel),
        ),
        M3EButton.filled(
          key: const Key('aiDjConsentAgreeButton'),
          onPressed: () => navigator.pop(true),
          child: Text(l10n.aiDjAgree),
        ),
      ],
    ),
  );
  if (agreed != true) return false;
  await provider.grantConsent();
  return true;
}

/// [SourceFailure.l10nKey] → 文案（未知 key 回退通用请求失败）。
String aiDjFailureText(AppLocalizations l10n, SourceFailure failure) {
  return switch (failure.l10nKey) {
    'aiDjNotConfigured' => l10n.aiDjNotConfigured,
    'aiDjUnauthorized' => l10n.aiDjUnauthorized,
    'aiDjRateLimited' => l10n.aiDjRateLimited,
    'aiDjBadResponse' => l10n.aiDjBadResponse,
    'aiDjNothingResolved' => l10n.aiDjNothingResolved,
    _ => l10n.aiDjRequestFailed,
  };
}
