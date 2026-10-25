import '../l10n/app_localizations.dart';

/// 音源音质的本地化显示名（设置 / 音源 / 省流页共用）。
///
/// 值域是 LX 音质标识（见 `kLxQualityOrder`）；未知值沿用值本身，
/// 保证新增音质标签也能显示。
String sourceQualityLabel(AppLocalizations l10n, String quality) {
  return switch (quality) {
    'flac24bit' => l10n.sourcesQualityHiRes,
    'flac' => l10n.sourcesQualityLossless,
    'wav' => l10n.sourcesQualityWav,
    'ape' => l10n.sourcesQualityApe,
    '320k' => l10n.sourcesQuality320k,
    '192k' => l10n.sourcesQuality192k,
    '128k' => l10n.sourcesQuality128k,
    _ => quality,
  };
}
