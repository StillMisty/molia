/// AI 推歌共享 UI 逻辑：隐私确认弹窗（AI 页）+ 失败文案映射
/// （AI 页与发现页错误卡共用，避免两处漂移）。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/failure.dart';
import '../domain/models/ai_dj.dart';
import '../l10n/app_localizations.dart';
import '../providers/ai_dj_provider.dart';
import '../services/notification_service.dart';

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

/// 「上次更新」相对时间：刚刚 / N 分钟前 / N 小时前 / 昨天 HH:mm / M月D日。
///
/// AI 页与发现页推荐区共用（同一条信息不在两处漂移）。
String aiDjUpdatedText(AppLocalizations l10n, DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.inMinutes < 1) return l10n.aiDjUpdatedJustNow;
  if (diff.inMinutes < 60) return l10n.aiDjUpdatedMinutesAgo(diff.inMinutes);
  final sameDay =
      now.year == time.year && now.month == time.month && now.day == time.day;
  if (sameDay && diff.inHours < 24) {
    return l10n.aiDjUpdatedHoursAgo(diff.inHours);
  }
  final hhmm =
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
  final yesterday = now.subtract(const Duration(days: 1));
  if (time.year == yesterday.year &&
      time.month == yesterday.month &&
      time.day == yesterday.day) {
    return l10n.aiDjUpdatedYesterday(hhmm);
  }
  return l10n.aiDjUpdatedDate(time.month, time.day);
}

/// 本轮反馈分组：手动「不感兴趣」同时也会进入 skipped 标签，展示时去重。
({
  List<ResolvedRecommendation> notInterested,
  List<String> skipped,
  List<String> liked,
})
aiDjRoundFeedback(AiDjProvider provider) {
  final notInterested = provider.notInterestedItems;
  final manualLabels = {for (final item in notInterested) item.source.label};
  return (
    notInterested: notInterested,
    skipped: [
      for (final label in provider.skippedLabels)
        if (!manualLabels.contains(label)) label,
    ],
    liked: provider.likedLabels,
  );
}

/// 反馈入口行摘要：本轮 / 长期条数；全空时显示空态文案。
String aiDjFeedbackSummary(AppLocalizations l10n, AiDjProvider provider) {
  final round = aiDjRoundFeedback(provider);
  final roundCount =
      round.notInterested.length + round.skipped.length + round.liked.length;
  final memoryCount =
      provider.rememberedSkippedLabels.length +
      provider.rememberedLikedLabels.length +
      provider.seeds.length;
  if (roundCount == 0 && memoryCount == 0) return l10n.aiDjFeedbackEmpty;
  return l10n.aiDjFeedbackSummary(roundCount, memoryCount);
}

/// 清空 AI 记忆：确认 → 清空 → 提示（反馈弹窗与偏好页共用）。
Future<void> confirmAndClearAiDjMemory(
  BuildContext context,
  AiDjProvider provider,
) async {
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context, rootNavigator: true);
  final confirmed = await M3EDialog.show<bool>(
    context,
    dialog: M3EDialog(
      title: l10n.aiDjClearMemoryTitle,
      content: Text(l10n.aiDjClearMemoryBody),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(false),
          child: Text(l10n.cancel),
        ),
        M3EButton.filled(
          key: const Key('aiDjClearMemoryConfirm'),
          onPressed: () => navigator.pop(true),
          child: Text(l10n.aiDjClearMemory),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  await provider.clearFeedbackMemory();
  if (!context.mounted) return;
  final notifications = context.read<NotificationService?>();
  if (notifications == null) {
    M3ESnackbar.show(context, message: l10n.aiDjMemoryCleared);
  } else {
    notifications.showSuccessSnackBar(l10n.aiDjMemoryCleared);
  }
}

/// 历史批次来源标签。
String aiDjOriginText(AppLocalizations l10n, AiDjOrigin origin) =>
    switch (origin) {
      AiDjOrigin.refresh => l10n.aiDjOriginRefresh,
      AiDjOrigin.autoFeed => l10n.aiDjOriginAutoFeed,
      AiDjOrigin.manualFeed => l10n.aiDjOriginManualFeed,
    };

/// 显式生成阶段文案（静默补歌不进入该 UI）：进度的唯一单行说明。
String aiDjPhaseText(AppLocalizations l10n, AiDjProgress progress) =>
    switch (progress.phase) {
      AiDjPhase.profile => l10n.aiDjPhaseProfile,
      AiDjPhase.model => l10n.aiDjPhaseModel,
      AiDjPhase.resolving => l10n.aiDjPhaseResolving(
        progress.done,
        progress.total,
      ),
    };

/// 偏好 token → 文案（未知值原样展示，避免空白）。
String aiDjStyleLabel(AppLocalizations l10n, String token) => switch (token) {
  'pop' => l10n.aiDjStylePop,
  'rock' => l10n.aiDjStyleRock,
  'electronic' => l10n.aiDjStyleElectronic,
  'folk' => l10n.aiDjStyleFolk,
  'rap' => l10n.aiDjStyleRap,
  'rnb' => l10n.aiDjStyleRnb,
  'jazz' => l10n.aiDjStyleJazz,
  'classical' => l10n.aiDjStyleClassical,
  'metal' => l10n.aiDjStyleMetal,
  'acg' => l10n.aiDjStyleAcg,
  'instrumental' => l10n.aiDjStyleInstrumental,
  'chineseStyle' => l10n.aiDjStyleChineseStyle,
  _ => token,
};

String aiDjSceneLabel(AppLocalizations l10n, String token) => switch (token) {
  'commute' => l10n.aiDjSceneCommute,
  'focus' => l10n.aiDjSceneFocus,
  'relax' => l10n.aiDjSceneRelax,
  'workout' => l10n.aiDjSceneWorkout,
  'sleep' => l10n.aiDjSceneSleep,
  'weekend' => l10n.aiDjSceneWeekend,
  _ => token,
};

String aiDjLanguageLabel(AppLocalizations l10n, String token) =>
    switch (token) {
      'mandarin' => l10n.aiDjLanguageMandarin,
      'cantonese' => l10n.aiDjLanguageCantonese,
      'english' => l10n.aiDjLanguageEnglish,
      'japanese' => l10n.aiDjLanguageJapanese,
      'korean' => l10n.aiDjLanguageKorean,
      'instrumental' => l10n.aiDjLanguageInstrumental,
      _ => token,
    };

String aiDjEraLabel(AppLocalizations l10n, String token) => switch (token) {
  kAiEraRecent3 => l10n.aiDjEraRecent3,
  kAiEra2010s => l10n.aiDjEra2010s,
  kAiEra2000s => l10n.aiDjEra2000s,
  kAiEraBefore90 => l10n.aiDjEraBefore90,
  _ => l10n.aiDjEraAny,
};

String aiDjExplorationLabel(AppLocalizations l10n, String token) =>
    switch (token) {
      kAiExplorationSafe => l10n.aiDjExplorationSafe,
      kAiExplorationSurprise => l10n.aiDjExplorationSurprise,
      _ => l10n.aiDjExplorationBalanced,
    };

String aiDjSectionLabel(AppLocalizations l10n, AiUpstreamSection section) =>
    switch (section) {
      AiUpstreamSection.summary => l10n.aiDjScopeSummary,
      AiUpstreamSection.topArtists => l10n.aiDjScopeTopArtists,
      AiUpstreamSection.topTracks => l10n.aiDjScopeTopTracks,
      AiUpstreamSection.timeAndSource => l10n.aiDjScopeTimeAndSource,
      AiUpstreamSection.recentEvents => l10n.aiDjScopeRecentEvents,
      AiUpstreamSection.listenedExclusions => l10n.aiDjScopeListenedExclusions,
      AiUpstreamSection.favorites => l10n.aiDjScopeFavorites,
      AiUpstreamSection.playlists => l10n.aiDjScopePlaylists,
    };

/// 偏好人话摘要（AI 页入口行 + 发送范围摘要共用）。
String aiDjPreferencesSummary(AppLocalizations l10n, AiPreferences prefs) {
  final parts = <String>[
    if (prefs.styles.isNotEmpty)
      prefs.styles.map((value) => aiDjStyleLabel(l10n, value)).join(' / '),
    if (prefs.scenes.isNotEmpty)
      prefs.scenes.map((value) => aiDjSceneLabel(l10n, value)).join(' / '),
    if (prefs.languages.isNotEmpty)
      prefs.languages
          .map((value) => aiDjLanguageLabel(l10n, value))
          .join(' / '),
    if (prefs.era != kAiEraAny) aiDjEraLabel(l10n, prefs.era),
    aiDjExplorationLabel(l10n, prefs.exploration),
  ];
  return parts.join(' · ');
}
