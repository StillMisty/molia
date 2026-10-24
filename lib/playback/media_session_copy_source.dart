/// 生产文案来源：把全局界面语言解析成 [MediaSessionCopy]。
///
/// 只有组合根（系统媒体会话装配）使用它：handler 只收到一个
/// `ValueListenable<MediaSessionCopy>`，不再直接读 `LanguageService`。语言
/// 变化时 notifier 重算并通知 handler 重发通知动作文案。
library;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/widgets.dart' show WidgetsBinding;

import '../l10n/app_localizations.dart';
import '../services/language_service.dart';
import 'media_session_copy.dart';

/// 跟随界面语言的文案源（与 `LanguageService.localeNotifier` 同生命周期）。
///
/// 组合根在 `runApp` 前创建一次并注入 handler；进程内不再释放（与语言服务
/// 的全局 notifier 一致）。测试直接注入自己的 `ValueNotifier<MediaSessionCopy>`。
class LocalizedMediaSessionCopy extends ValueNotifier<MediaSessionCopy> {
  LocalizedMediaSessionCopy()
      : super(MediaSessionCopy.of(_currentLocalizations())) {
    LanguageService.localeNotifier.addListener(_refresh);
  }

  void _refresh() {
    value = MediaSessionCopy.of(_currentLocalizations());
  }

  /// 与托盘菜单同一解析口径：用户选择优先、否则跟随系统，不支持的 locale
  /// 回退首个支持语言（`lookupAppLocalizations` 对不支持的语言会抛错）。
  static AppLocalizations _currentLocalizations() {
    final effective = LanguageService.localeNotifier.value ??
        WidgetsBinding.instance.platformDispatcher.locale;
    final resolved = LanguageService.supportedLocales.any(
      (supported) => supported.languageCode == effective.languageCode,
    )
        ? effective
        : LanguageService.supportedLocales.first;
    return lookupAppLocalizations(resolved);
  }

  @override
  void dispose() {
    LanguageService.localeNotifier.removeListener(_refresh);
    super.dispose();
  }
}
