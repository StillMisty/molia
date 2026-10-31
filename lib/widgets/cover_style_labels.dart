/// 封面风格 / 作用范围的界面文案映射（唯一实现，设置行与弹层共用）。
///
/// 领域层只暴露稳定 id；用户可见名称一律走这里 + `AppLocalizations`，
/// 中英文成对维护（见 `docs/copy_style.md`）。
library;

import '../domain/models/cover_style.dart';
import '../l10n/app_localizations.dart';

String coverStyleName(AppLocalizations l10n, CoverStyle style) =>
    switch (style) {
      CoverStyle.original => l10n.coverStyleOriginal,
      CoverStyle.oneLastKiss => l10n.coverStyleOneLastKiss,
      CoverStyle.lineArt => l10n.coverStyleLineArt,
      CoverStyle.pencil => l10n.coverStylePencil,
      CoverStyle.emboss => l10n.coverStyleEmboss,
      CoverStyle.pixel => l10n.coverStylePixel,
      CoverStyle.ink => l10n.coverStyleInk,
      CoverStyle.duotone => l10n.coverStyleDuotone,
      CoverStyle.film => l10n.coverStyleFilm,
    };

String coverStyleDescription(AppLocalizations l10n, CoverStyle style) =>
    switch (style) {
      CoverStyle.original => l10n.coverStyleOriginalSubtitle,
      CoverStyle.oneLastKiss => l10n.coverStyleOneLastKissSubtitle,
      CoverStyle.lineArt => l10n.coverStyleLineArtSubtitle,
      CoverStyle.pencil => l10n.coverStylePencilSubtitle,
      CoverStyle.emboss => l10n.coverStyleEmbossSubtitle,
      CoverStyle.pixel => l10n.coverStylePixelSubtitle,
      CoverStyle.ink => l10n.coverStyleInkSubtitle,
      CoverStyle.duotone => l10n.coverStyleDuotoneSubtitle,
      CoverStyle.film => l10n.coverStyleFilmSubtitle,
    };

String coverStyleScopeName(AppLocalizations l10n, CoverStyleScope scope) =>
    switch (scope) {
      CoverStyleScope.player => l10n.coverStyleScopePlayer,
      CoverStyleScope.all => l10n.coverStyleScopeAll,
    };

String coverStyleScopeDescription(
  AppLocalizations l10n,
  CoverStyleScope scope,
) => switch (scope) {
  CoverStyleScope.player => l10n.coverStyleScopePlayerSubtitle,
  CoverStyleScope.all => l10n.coverStyleScopeAllSubtitle,
};
