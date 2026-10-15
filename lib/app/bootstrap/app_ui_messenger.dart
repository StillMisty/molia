/// composition root 内的 UiMessenger 适配器：唯一持有 navigatorKey /
/// scaffoldMessengerKey 的提示出口，把领域失败映射为 l10n 文案。
///
/// 错误提示统一经此注入；provider 不 import `main.dart`
/// （docs/architecture.md §2.1）。实现随组合根拆 stack builders 从
/// `main.dart` 原样搬到这里（行为不变）。
library;

import '../../domain/models/failure.dart';
import '../../domain/ports/ui_messenger.dart';
import '../../l10n/app_localizations.dart';
import '../../services/notification_service.dart';
import '../app_shell.dart';

class AppUiMessenger implements UiMessenger {
  const AppUiMessenger(this._notifications);

  final NotificationService _notifications;

  @override
  void showMessage(String message) {
    _notifications.showSnackBar(message, duration: const Duration(seconds: 3));
  }

  @override
  void showFailure(SourceFailure failure) {
    final context = navigatorKey.currentContext;
    final l10n = context == null ? null : AppLocalizations.of(context);
    final text =
        l10n == null ? '播放失败: ${failure.message}' : _localize(l10n, failure);
    _notifications.showSnackBar(text, duration: const Duration(seconds: 3));
  }

  /// 把领域失败映射为 l10n 文案：参数化键（playbackFailed 等）按
  /// failure.l10nKey 分发，未知 key 回退通用播放失败文案。
  String _localize(AppLocalizations l10n, SourceFailure failure) {
    switch (failure.l10nKey) {
      case 'downloadFileMissing':
        // 本地下载文件缺失：播放取链时归一化出的可读提示。
        return l10n.downloadFileMissing;
      case null:
      case 'playbackFailed':
        return l10n.playbackFailed(failure.message);
      default:
        // 未知 key 回退到通用播放失败文案（不显示 `$e` 之外的新格式）。
        return l10n.playbackFailed(failure.message);
    }
  }
}
