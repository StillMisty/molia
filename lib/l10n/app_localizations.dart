import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @queueTab.
  ///
  /// In en, this message translates to:
  /// **'QUEUE'**
  String get queueTab;

  /// No description provided for @lyricsTab.
  ///
  /// In en, this message translates to:
  /// **'LYRICS'**
  String get lyricsTab;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @playbackFailed.
  ///
  /// In en, this message translates to:
  /// **'Playback failed: {error}'**
  String playbackFailed(String error);

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search songs, albums, artists...'**
  String get searchHint;

  /// No description provided for @searchIdleHint.
  ///
  /// In en, this message translates to:
  /// **'Search songs by keyword'**
  String get searchIdleHint;

  /// No description provided for @clearSearch.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get clearSearch;

  /// No description provided for @copiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String copiedToClipboard(String type);

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @lyricsFetching.
  ///
  /// In en, this message translates to:
  /// **'Fetching lyrics...'**
  String get lyricsFetching;

  /// No description provided for @lyricsNotFoundForTrack.
  ///
  /// In en, this message translates to:
  /// **'No lyrics found for this track.'**
  String get lyricsNotFoundForTrack;

  /// No description provided for @lyricsFetchError.
  ///
  /// In en, this message translates to:
  /// **'Error fetching lyrics: {error}'**
  String lyricsFetchError(String error);

  /// No description provided for @lyricsTitle.
  ///
  /// In en, this message translates to:
  /// **'Lyrics'**
  String get lyricsTitle;

  /// No description provided for @lyricsLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading lyrics...'**
  String get lyricsLoading;

  /// No description provided for @lyricsFailedToLoad.
  ///
  /// In en, this message translates to:
  /// **'Failed to load lyrics.'**
  String get lyricsFailedToLoad;

  /// No description provided for @lyricsCopyModeSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Copy lyrics mode: single repeat is on and auto-follow is paused; your previous play mode returns when you exit.'**
  String get lyricsCopyModeSnackbar;

  /// No description provided for @centerCurrentLine.
  ///
  /// In en, this message translates to:
  /// **'Center Current Line'**
  String get centerCurrentLine;

  /// No description provided for @playlist.
  ///
  /// In en, this message translates to:
  /// **'Playlist'**
  String get playlist;

  /// No description provided for @operationFailed.
  ///
  /// In en, this message translates to:
  /// **'Operation failed'**
  String get operationFailed;

  /// No description provided for @settingsAppearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearanceTitle;

  /// No description provided for @settingsThemeMode.
  ///
  /// In en, this message translates to:
  /// **'Theme mode'**
  String get settingsThemeMode;

  /// No description provided for @themeModeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeModeSystem;

  /// No description provided for @themeModeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeModeLight;

  /// No description provided for @themeModeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeModeDark;

  /// No description provided for @settingsBaseColor.
  ///
  /// In en, this message translates to:
  /// **'Base colors'**
  String get settingsBaseColor;

  /// No description provided for @settingsBaseColorWallpaper.
  ///
  /// In en, this message translates to:
  /// **'System wallpaper'**
  String get settingsBaseColorWallpaper;

  /// No description provided for @settingsBaseColorCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom color'**
  String get settingsBaseColorCustom;

  /// No description provided for @settingsMonetUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not supported on this platform'**
  String get settingsMonetUnavailable;

  /// No description provided for @settingsPureBlack.
  ///
  /// In en, this message translates to:
  /// **'Pure black background'**
  String get settingsPureBlack;

  /// No description provided for @settingsPureBlackSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use pure black surfaces in dark mode (OLED)'**
  String get settingsPureBlackSubtitle;

  /// No description provided for @settingsSeedColor.
  ///
  /// In en, this message translates to:
  /// **'Custom color'**
  String get settingsSeedColor;

  /// No description provided for @settingsFollowArtwork.
  ///
  /// In en, this message translates to:
  /// **'Follow album art'**
  String get settingsFollowArtwork;

  /// No description provided for @settingsFollowArtworkSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Follow the current track\'s album art; falls back to base colors without artwork'**
  String get settingsFollowArtworkSubtitle;

  /// No description provided for @settingsAppFont.
  ///
  /// In en, this message translates to:
  /// **'App font'**
  String get settingsAppFont;

  /// No description provided for @fontSystemDefault.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get fontSystemDefault;

  /// No description provided for @fontPickerSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search fonts'**
  String get fontPickerSearchHint;

  /// No description provided for @fontPickerEmpty.
  ///
  /// In en, this message translates to:
  /// **'No fonts available on this device'**
  String get fontPickerEmpty;

  /// No description provided for @posterFontLabel.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get posterFontLabel;

  /// No description provided for @posterColorSource.
  ///
  /// In en, this message translates to:
  /// **'Color source'**
  String get posterColorSource;

  /// No description provided for @posterColorSourceAppTheme.
  ///
  /// In en, this message translates to:
  /// **'Follow app theme'**
  String get posterColorSourceAppTheme;

  /// No description provided for @posterColorSourceArtwork.
  ///
  /// In en, this message translates to:
  /// **'Follow album art'**
  String get posterColorSourceArtwork;

  /// No description provided for @posterColorSourceCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom color'**
  String get posterColorSourceCustom;

  /// No description provided for @posterColorCustomLabel.
  ///
  /// In en, this message translates to:
  /// **'Custom color'**
  String get posterColorCustomLabel;

  /// No description provided for @posterColorUnavailable.
  ///
  /// In en, this message translates to:
  /// **'No artwork for this track'**
  String get posterColorUnavailable;

  /// No description provided for @posterFontFollowApp.
  ///
  /// In en, this message translates to:
  /// **'Follow app font'**
  String get posterFontFollowApp;

  /// No description provided for @colorBlue.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get colorBlue;

  /// No description provided for @colorPurple.
  ///
  /// In en, this message translates to:
  /// **'Purple'**
  String get colorPurple;

  /// No description provided for @colorGreen.
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get colorGreen;

  /// No description provided for @colorOrange.
  ///
  /// In en, this message translates to:
  /// **'Orange'**
  String get colorOrange;

  /// No description provided for @colorPink.
  ///
  /// In en, this message translates to:
  /// **'Pink'**
  String get colorPink;

  /// No description provided for @colorTeal.
  ///
  /// In en, this message translates to:
  /// **'Teal'**
  String get colorTeal;

  /// No description provided for @settingsPlaybackTitle.
  ///
  /// In en, this message translates to:
  /// **'Playback'**
  String get settingsPlaybackTitle;

  /// No description provided for @settingsDefaultPlayMode.
  ///
  /// In en, this message translates to:
  /// **'Default play mode'**
  String get settingsDefaultPlayMode;

  /// No description provided for @settingsDefaultPlayModeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Initial mode for new sessions; current playback is unaffected'**
  String get settingsDefaultPlayModeSubtitle;

  /// No description provided for @settingsRestoreSessionTitle.
  ///
  /// In en, this message translates to:
  /// **'Resume last playback'**
  String get settingsRestoreSessionTitle;

  /// No description provided for @settingsRestoreSessionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Restore track, queue and position on launch (on by default)'**
  String get settingsRestoreSessionSubtitle;

  /// No description provided for @settingsAutoSourceSwap.
  ///
  /// In en, this message translates to:
  /// **'Auto source switch'**
  String get settingsAutoSourceSwap;

  /// No description provided for @settingsAutoSourceSwapSubtitle.
  ///
  /// In en, this message translates to:
  /// **'On failure, find the same song in another source and switch (on by default)'**
  String get settingsAutoSourceSwapSubtitle;

  /// No description provided for @settingsDataSaverTitle.
  ///
  /// In en, this message translates to:
  /// **'Data saver'**
  String get settingsDataSaverTitle;

  /// No description provided for @settingsDataSaverSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When on, lower audio quality and reduce artwork loading on mobile data'**
  String get settingsDataSaverSubtitle;

  /// No description provided for @settingsDataSaverNetworkCellular.
  ///
  /// In en, this message translates to:
  /// **'Mobile data · active'**
  String get settingsDataSaverNetworkCellular;

  /// No description provided for @settingsDataSaverNetworkWifi.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi · inactive'**
  String get settingsDataSaverNetworkWifi;

  /// No description provided for @settingsDataSaverNetworkUnknown.
  ///
  /// In en, this message translates to:
  /// **'Network type unavailable'**
  String get settingsDataSaverNetworkUnknown;

  /// No description provided for @settingsDataSaverQuality.
  ///
  /// In en, this message translates to:
  /// **'Data saver quality cap'**
  String get settingsDataSaverQuality;

  /// No description provided for @settingsDataSaverCovers.
  ///
  /// In en, this message translates to:
  /// **'Cached artwork only on mobile data'**
  String get settingsDataSaverCovers;

  /// No description provided for @settingsDataSaverCoversSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Do not request new artwork; show a placeholder when not cached'**
  String get settingsDataSaverCoversSubtitle;

  /// No description provided for @settingsSourcesItemSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Import LX Music source scripts to search third-party platforms'**
  String get settingsSourcesItemSubtitle;

  /// No description provided for @settingsContentSection.
  ///
  /// In en, this message translates to:
  /// **'Content & sources'**
  String get settingsContentSection;

  /// No description provided for @settingsLyricsSection.
  ///
  /// In en, this message translates to:
  /// **'Lyrics & display'**
  String get settingsLyricsSection;

  /// No description provided for @settingsBottomNavTitle.
  ///
  /// In en, this message translates to:
  /// **'Bottom navigation'**
  String get settingsBottomNavTitle;

  /// No description provided for @settingsBottomNavHint.
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder; toggle to show or hide a tab (at least one stays visible)'**
  String get settingsBottomNavHint;

  /// No description provided for @settingsBottomNavKeepOne.
  ///
  /// In en, this message translates to:
  /// **'Keep at least one tab visible'**
  String get settingsBottomNavKeepOne;

  /// No description provided for @playModeSequential.
  ///
  /// In en, this message translates to:
  /// **'Sequential'**
  String get playModeSequential;

  /// No description provided for @playModeShuffle.
  ///
  /// In en, this message translates to:
  /// **'Shuffle'**
  String get playModeShuffle;

  /// No description provided for @playModeSingleRepeat.
  ///
  /// In en, this message translates to:
  /// **'Single repeat'**
  String get playModeSingleRepeat;

  /// No description provided for @generalTitle.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get generalTitle;

  /// No description provided for @settingsGeneralAndDataTitle.
  ///
  /// In en, this message translates to:
  /// **'General & data'**
  String get settingsGeneralAndDataTitle;

  /// No description provided for @settingsGeneralSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Language, app name and bottom navigation'**
  String get settingsGeneralSubtitle;

  /// No description provided for @dataManagementTitle.
  ///
  /// In en, this message translates to:
  /// **'Data & storage'**
  String get dataManagementTitle;

  /// No description provided for @settingsDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Cache, listening stats and data import/export'**
  String get settingsDataSubtitle;

  /// No description provided for @settingsDataStorageSection.
  ///
  /// In en, this message translates to:
  /// **'Storage & stats'**
  String get settingsDataStorageSection;

  /// No description provided for @settingsDataPortabilitySection.
  ///
  /// In en, this message translates to:
  /// **'Import & export'**
  String get settingsDataPortabilitySection;

  /// No description provided for @exportDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Export data'**
  String get exportDataTitle;

  /// No description provided for @exportDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Full backup: playlists, sources, settings, stats, history (no credentials)'**
  String get exportDataSubtitle;

  /// No description provided for @importDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Import data'**
  String get importDataTitle;

  /// No description provided for @importDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Merge a Molia backup into local data'**
  String get importDataSubtitle;

  /// No description provided for @clearCacheTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear Lyrics Cache'**
  String get clearCacheTitle;

  /// No description provided for @clearCacheSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Clear cached lyrics'**
  String get clearCacheSubtitle;

  /// No description provided for @cancelButton.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancelButton;

  /// No description provided for @languageSaved.
  ///
  /// In en, this message translates to:
  /// **'Language setting saved'**
  String get languageSaved;

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed or cancelled.'**
  String get exportFailed;

  /// No description provided for @importDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm Import'**
  String get importDialogTitle;

  /// No description provided for @importDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'Importing data will replace existing recent play entries with the same identifiers. This cannot be undone. Are you sure you want to continue?\n\nEnsure the JSON file is valid and was previously exported from Molia.'**
  String get importDialogMessage;

  /// No description provided for @importButton.
  ///
  /// In en, this message translates to:
  /// **'Import Data'**
  String get importButton;

  /// No description provided for @importSuccess.
  ///
  /// In en, this message translates to:
  /// **'Data imported successfully!'**
  String get importSuccess;

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to import data.'**
  String get importFailed;

  /// No description provided for @exportSuccess.
  ///
  /// In en, this message translates to:
  /// **'Data exported successfully!'**
  String get exportSuccess;

  /// No description provided for @clearCacheDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm Clear Cache'**
  String get clearCacheDialogTitle;

  /// No description provided for @clearCacheDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to clear the lyrics cache? This cannot be undone.'**
  String get clearCacheDialogMessage;

  /// No description provided for @clearCacheButton.
  ///
  /// In en, this message translates to:
  /// **'Clear Cache'**
  String get clearCacheButton;

  /// No description provided for @clearingCache.
  ///
  /// In en, this message translates to:
  /// **'Clearing cache...'**
  String get clearingCache;

  /// No description provided for @cacheCleared.
  ///
  /// In en, this message translates to:
  /// **'Cache cleared successfully!'**
  String get cacheCleared;

  /// No description provided for @cacheClearFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to clear cache'**
  String get cacheClearFailed;

  /// No description provided for @saveChanges.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get saveChanges;

  /// No description provided for @selectLyrics.
  ///
  /// In en, this message translates to:
  /// **'Select Lyrics'**
  String get selectLyrics;

  /// No description provided for @selectLyricsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Select lyrics fragments to make a poster or share'**
  String get selectLyricsTooltip;

  /// No description provided for @deselectAll.
  ///
  /// In en, this message translates to:
  /// **'Deselect All'**
  String get deselectAll;

  /// No description provided for @noLyricsSelected.
  ///
  /// In en, this message translates to:
  /// **'Please select some lyrics first'**
  String get noLyricsSelected;

  /// No description provided for @sharePoster.
  ///
  /// In en, this message translates to:
  /// **'Share Poster'**
  String get sharePoster;

  /// No description provided for @selectedLyricsCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied {count} lines of lyrics'**
  String selectedLyricsCopied(int count);

  /// No description provided for @posterGenerationFailed.
  ///
  /// In en, this message translates to:
  /// **'Poster generation failed: {error}'**
  String posterGenerationFailed(Object error);

  /// No description provided for @noLyricsToSelect.
  ///
  /// In en, this message translates to:
  /// **'No lyrics available to select'**
  String get noLyricsToSelect;

  /// No description provided for @posterLyricsLimitExceeded.
  ///
  /// In en, this message translates to:
  /// **'Maximum 10 lines of lyrics can be selected for poster generation'**
  String get posterLyricsLimitExceeded;

  /// No description provided for @tapToSelectLyrics.
  ///
  /// In en, this message translates to:
  /// **'Tap lyric line to select'**
  String get tapToSelectLyrics;

  /// No description provided for @nowPlayingLabel.
  ///
  /// In en, this message translates to:
  /// **'Now Playing'**
  String get nowPlayingLabel;

  /// No description provided for @libraryLabel.
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get libraryLabel;

  /// No description provided for @libraryTabSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get libraryTabSearch;

  /// No description provided for @libraryTabLeaderboards.
  ///
  /// In en, this message translates to:
  /// **'Charts'**
  String get libraryTabLeaderboards;

  /// No description provided for @libraryTabPlaylists.
  ///
  /// In en, this message translates to:
  /// **'Playlists'**
  String get libraryTabPlaylists;

  /// No description provided for @libraryChannelSelect.
  ///
  /// In en, this message translates to:
  /// **'Select channel'**
  String get libraryChannelSelect;

  /// No description provided for @libraryNoChannels.
  ///
  /// In en, this message translates to:
  /// **'All channels are disabled. Enable channels in Source Management.'**
  String get libraryNoChannels;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageSimplifiedChinese.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get languageSimplifiedChinese;

  /// No description provided for @collapseTooltip.
  ///
  /// In en, this message translates to:
  /// **'Collapse'**
  String get collapseTooltip;

  /// No description provided for @expandTooltip.
  ///
  /// In en, this message translates to:
  /// **'Expand'**
  String get expandTooltip;

  /// No description provided for @noItemsFound.
  ///
  /// In en, this message translates to:
  /// **'No items found'**
  String get noItemsFound;

  /// No description provided for @copyButtonText.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copyButtonText;

  /// No description provided for @posterButtonLabel.
  ///
  /// In en, this message translates to:
  /// **'Poster'**
  String get posterButtonLabel;

  /// No description provided for @retryButton.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retryButton;

  /// No description provided for @backToLibraryTooltip.
  ///
  /// In en, this message translates to:
  /// **'Back to library'**
  String get backToLibraryTooltip;

  /// No description provided for @loadingGenerating.
  ///
  /// In en, this message translates to:
  /// **'Generating poster...'**
  String get loadingGenerating;

  /// No description provided for @currentQueueEmpty.
  ///
  /// In en, this message translates to:
  /// **'Current queue is empty'**
  String get currentQueueEmpty;

  /// No description provided for @nowPlayingSection.
  ///
  /// In en, this message translates to:
  /// **'Now Playing'**
  String get nowPlayingSection;

  /// No description provided for @upNextSection.
  ///
  /// In en, this message translates to:
  /// **'Up Next'**
  String get upNextSection;

  /// No description provided for @searchLyrics.
  ///
  /// In en, this message translates to:
  /// **'Search Lyrics'**
  String get searchLyrics;

  /// No description provided for @noCurrentTrackPlaying.
  ///
  /// In en, this message translates to:
  /// **'No track currently playing'**
  String get noCurrentTrackPlaying;

  /// No description provided for @cannotGetTrackInfo.
  ///
  /// In en, this message translates to:
  /// **'Cannot get current track information'**
  String get cannotGetTrackInfo;

  /// No description provided for @lyricsSearchAppliedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Lyrics successfully searched and applied'**
  String get lyricsSearchAppliedSuccess;

  /// No description provided for @searchResults.
  ///
  /// In en, this message translates to:
  /// **'SEARCH RESULTS'**
  String get searchResults;

  /// No description provided for @noResultsFound.
  ///
  /// In en, this message translates to:
  /// **'No results found'**
  String get noResultsFound;

  /// No description provided for @playlistType.
  ///
  /// In en, this message translates to:
  /// **'Playlist'**
  String get playlistType;

  /// No description provided for @albumType.
  ///
  /// In en, this message translates to:
  /// **'Album'**
  String get albumType;

  /// No description provided for @songType.
  ///
  /// In en, this message translates to:
  /// **'Song'**
  String get songType;

  /// No description provided for @artistType.
  ///
  /// In en, this message translates to:
  /// **'Artist'**
  String get artistType;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @providerQQMusic.
  ///
  /// In en, this message translates to:
  /// **'QQ Music'**
  String get providerQQMusic;

  /// No description provided for @providerLRCLIB.
  ///
  /// In en, this message translates to:
  /// **'LRCLIB'**
  String get providerLRCLIB;

  /// No description provided for @providerNetease.
  ///
  /// In en, this message translates to:
  /// **'NetEase Cloud Music'**
  String get providerNetease;

  /// No description provided for @providerKugou.
  ///
  /// In en, this message translates to:
  /// **'Kugou Music'**
  String get providerKugou;

  /// No description provided for @providerKuwo.
  ///
  /// In en, this message translates to:
  /// **'Kuwo Music'**
  String get providerKuwo;

  /// No description provided for @providerMigu.
  ///
  /// In en, this message translates to:
  /// **'Migu Music'**
  String get providerMigu;

  /// No description provided for @lyricsBestMatch.
  ///
  /// In en, this message translates to:
  /// **'Best match'**
  String get lyricsBestMatch;

  /// No description provided for @playingFrom.
  ///
  /// In en, this message translates to:
  /// **'PLAYING FROM'**
  String get playingFrom;

  /// No description provided for @playFromAlbum.
  ///
  /// In en, this message translates to:
  /// **'PLAY FROM ALBUM'**
  String get playFromAlbum;

  /// No description provided for @playFromPlaylist.
  ///
  /// In en, this message translates to:
  /// **'PLAY FROM PLAYLIST'**
  String get playFromPlaylist;

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @sourcesTitle.
  ///
  /// In en, this message translates to:
  /// **'Source Management'**
  String get sourcesTitle;

  /// No description provided for @sourcesStatusSection.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get sourcesStatusSection;

  /// No description provided for @sourcesImportSection.
  ///
  /// In en, this message translates to:
  /// **'Import script'**
  String get sourcesImportSection;

  /// No description provided for @anyListenEntry.
  ///
  /// In en, this message translates to:
  /// **'any-listen'**
  String get anyListenEntry;

  /// No description provided for @anyListenIntroBody.
  ///
  /// In en, this message translates to:
  /// **'any-listen is a self-hosted private music service. Once the server address is set and the source is enabled, its online sources appear in search.'**
  String get anyListenIntroBody;

  /// No description provided for @anyListenIntroHint.
  ///
  /// In en, this message translates to:
  /// **'Skeleton implementation: the handshake probes (/api/ipc/hello, /api/ipc/id) follow the official source; search / url / lyric / pic endpoints are not yet verified against a real server and may not work.'**
  String get anyListenIntroHint;

  /// No description provided for @anyListenServerSection.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get anyListenServerSection;

  /// No description provided for @anyListenServerUrl.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get anyListenServerUrl;

  /// No description provided for @anyListenServerUrlHint.
  ///
  /// In en, this message translates to:
  /// **'Address of a Docker / desktop any-listen deployment'**
  String get anyListenServerUrlHint;

  /// No description provided for @anyListenServerUrlRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter the server address first'**
  String get anyListenServerUrlRequired;

  /// No description provided for @anyListenServerUrlRequiredToEnable.
  ///
  /// In en, this message translates to:
  /// **'Enter the server address before enabling'**
  String get anyListenServerUrlRequiredToEnable;

  /// No description provided for @anyListenToken.
  ///
  /// In en, this message translates to:
  /// **'Access token (optional)'**
  String get anyListenToken;

  /// No description provided for @anyListenTokenPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Paste the token issued by the server after a successful test'**
  String get anyListenTokenPlaceholder;

  /// No description provided for @anyListenTokenShow.
  ///
  /// In en, this message translates to:
  /// **'Show token'**
  String get anyListenTokenShow;

  /// No description provided for @anyListenTokenHide.
  ///
  /// In en, this message translates to:
  /// **'Hide token'**
  String get anyListenTokenHide;

  /// No description provided for @anyListenEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable any-listen source'**
  String get anyListenEnable;

  /// No description provided for @anyListenEnableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When off, it does not appear in search and makes no requests'**
  String get anyListenEnableSubtitle;

  /// No description provided for @anyListenSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get anyListenSave;

  /// No description provided for @anyListenTest.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get anyListenTest;

  /// No description provided for @anyListenSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Save failed: cannot write local storage'**
  String get anyListenSaveFailed;

  /// No description provided for @sourcesWebUnsupported.
  ///
  /// In en, this message translates to:
  /// **'LX source scripts are not supported on web (a local JS engine is required).'**
  String get sourcesWebUnsupported;

  /// No description provided for @sourcesNoneActive.
  ///
  /// In en, this message translates to:
  /// **'No source enabled'**
  String get sourcesNoneActive;

  /// No description provided for @sourcesActiveSource.
  ///
  /// In en, this message translates to:
  /// **'Active source: {name} {version}'**
  String sourcesActiveSource(String name, String version);

  /// No description provided for @sourcesActivating.
  ///
  /// In en, this message translates to:
  /// **'Activating…'**
  String get sourcesActivating;

  /// No description provided for @sourcesActivationFailed.
  ///
  /// In en, this message translates to:
  /// **'Activation failed: {error}'**
  String sourcesActivationFailed(String error);

  /// No description provided for @sourcesAuthor.
  ///
  /// In en, this message translates to:
  /// **'Author: {author}'**
  String sourcesAuthor(String author);

  /// No description provided for @sourcesUpdateAlertTitle.
  ///
  /// In en, this message translates to:
  /// **'Source update available'**
  String get sourcesUpdateAlertTitle;

  /// No description provided for @sourcesOpenUpdateUrl.
  ///
  /// In en, this message translates to:
  /// **'Open update URL'**
  String get sourcesOpenUpdateUrl;

  /// No description provided for @sourcesUpdateDismiss.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get sourcesUpdateDismiss;

  /// No description provided for @sourcesUpdateNow.
  ///
  /// In en, this message translates to:
  /// **'Update now'**
  String get sourcesUpdateNow;

  /// No description provided for @sourcesUpdating.
  ///
  /// In en, this message translates to:
  /// **'Updating…'**
  String get sourcesUpdating;

  /// No description provided for @sourcesUpdateSuccess.
  ///
  /// In en, this message translates to:
  /// **'Updated to {version}'**
  String sourcesUpdateSuccess(String version);

  /// No description provided for @sourcesUpdateNoUpdate.
  ///
  /// In en, this message translates to:
  /// **'Already up to date'**
  String get sourcesUpdateNoUpdate;

  /// No description provided for @sourcesUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Update failed: {reason}'**
  String sourcesUpdateFailed(String reason);

  /// No description provided for @sourcesUpdateManualHint.
  ///
  /// In en, this message translates to:
  /// **'This URL is not a script file. Open the update page and import it manually.'**
  String get sourcesUpdateManualHint;

  /// No description provided for @sourcesImportFromFile.
  ///
  /// In en, this message translates to:
  /// **'Import from file'**
  String get sourcesImportFromFile;

  /// No description provided for @sourcesImportFromFileSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose an LX Music source script (.js)'**
  String get sourcesImportFromFileSubtitle;

  /// No description provided for @sourcesImportFromText.
  ///
  /// In en, this message translates to:
  /// **'Paste script'**
  String get sourcesImportFromText;

  /// No description provided for @sourcesImportFromTextSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Paste the full script from the clipboard'**
  String get sourcesImportFromTextSubtitle;

  /// No description provided for @sourcesImportFromUrl.
  ///
  /// In en, this message translates to:
  /// **'Import from URL'**
  String get sourcesImportFromUrl;

  /// No description provided for @sourcesImportFromUrlSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Download the script over HTTP(S)'**
  String get sourcesImportFromUrlSubtitle;

  /// No description provided for @sourcesDefaultQuality.
  ///
  /// In en, this message translates to:
  /// **'Default quality'**
  String get sourcesDefaultQuality;

  /// No description provided for @sourcesQualityHiRes.
  ///
  /// In en, this message translates to:
  /// **'Hi-Res'**
  String get sourcesQualityHiRes;

  /// No description provided for @sourcesQualityLossless.
  ///
  /// In en, this message translates to:
  /// **'Lossless'**
  String get sourcesQualityLossless;

  /// No description provided for @sourcesQualityWav.
  ///
  /// In en, this message translates to:
  /// **'WAV'**
  String get sourcesQualityWav;

  /// No description provided for @sourcesQualityApe.
  ///
  /// In en, this message translates to:
  /// **'APE'**
  String get sourcesQualityApe;

  /// No description provided for @sourcesQuality320k.
  ///
  /// In en, this message translates to:
  /// **'320K'**
  String get sourcesQuality320k;

  /// No description provided for @sourcesQuality192k.
  ///
  /// In en, this message translates to:
  /// **'192K'**
  String get sourcesQuality192k;

  /// No description provided for @sourcesQuality128k.
  ///
  /// In en, this message translates to:
  /// **'128K'**
  String get sourcesQuality128k;

  /// No description provided for @sourcesQualityHint.
  ///
  /// In en, this message translates to:
  /// **'Preferred when resolving a track URL; falls back when unavailable.'**
  String get sourcesQualityHint;

  /// No description provided for @sourcesSortTitle.
  ///
  /// In en, this message translates to:
  /// **'Channel order'**
  String get sourcesSortTitle;

  /// No description provided for @sourcesSortReset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get sourcesSortReset;

  /// No description provided for @sourcesSortResetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Restore the default order: script sources first, built-in platforms after'**
  String get sourcesSortResetSubtitle;

  /// No description provided for @sourcesSortHint.
  ///
  /// In en, this message translates to:
  /// **'The channel order on the Discover page matches the list below and also controls the search source order. Newly imported channels are appended at the end; turning a channel off removes it from the Discover page and search results.'**
  String get sourcesSortHint;

  /// No description provided for @sourcesChannelDisabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get sourcesChannelDisabled;

  /// No description provided for @sourcesNoSearchableSources.
  ///
  /// In en, this message translates to:
  /// **'No searchable sources yet. Enable a source script to list searchable platforms here.'**
  String get sourcesNoSearchableSources;

  /// No description provided for @sourcesKindLx.
  ///
  /// In en, this message translates to:
  /// **'Script source'**
  String get sourcesKindLx;

  /// No description provided for @sourcesKindBuiltin.
  ///
  /// In en, this message translates to:
  /// **'Built-in platform'**
  String get sourcesKindBuiltin;

  /// No description provided for @sourcesImportedScripts.
  ///
  /// In en, this message translates to:
  /// **'Imported scripts ({count})'**
  String sourcesImportedScripts(int count);

  /// No description provided for @sourcesNoScripts.
  ///
  /// In en, this message translates to:
  /// **'No source scripts imported yet. Community sources can be found on GitHub by searching for “lx-music-source”.'**
  String get sourcesNoScripts;

  /// No description provided for @sourcesScriptByAuthor.
  ///
  /// In en, this message translates to:
  /// **'by {author}'**
  String sourcesScriptByAuthor(String author);

  /// No description provided for @sourcesEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get sourcesEnable;

  /// No description provided for @sourcesDisable.
  ///
  /// In en, this message translates to:
  /// **'Disable'**
  String get sourcesDisable;

  /// No description provided for @sourcesActivated.
  ///
  /// In en, this message translates to:
  /// **'Source enabled: {name}'**
  String sourcesActivated(String name);

  /// No description provided for @sourcesActivateFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to enable: {error}'**
  String sourcesActivateFailed(String error);

  /// No description provided for @sourcesDeleteScriptTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete source script'**
  String get sourcesDeleteScriptTitle;

  /// No description provided for @sourcesDeleteScriptConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}”?'**
  String sourcesDeleteScriptConfirm(String name);

  /// No description provided for @sourcesDisclaimerTitle.
  ///
  /// In en, this message translates to:
  /// **'Import source script'**
  String get sourcesDisclaimerTitle;

  /// No description provided for @sourcesDisclaimerBody.
  ///
  /// In en, this message translates to:
  /// **'Source scripts are executable JavaScript code provided by third-party communities.\nOnce imported, they run in the local JS engine and can make network requests.\nImport only scripts from trusted sources; their availability and legality are the responsibility of the provider.'**
  String get sourcesDisclaimerBody;

  /// No description provided for @sourcesContinueImport.
  ///
  /// In en, this message translates to:
  /// **'Continue import'**
  String get sourcesContinueImport;

  /// No description provided for @sourcesImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {error}'**
  String sourcesImportFailed(String error);

  /// No description provided for @sourcesPasteTitle.
  ///
  /// In en, this message translates to:
  /// **'Paste source script'**
  String get sourcesPasteTitle;

  /// No description provided for @sourcesPasteHint.
  ///
  /// In en, this message translates to:
  /// **'Paste the full script starting with /** @name ... */'**
  String get sourcesPasteHint;

  /// No description provided for @sourcesImportAction.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get sourcesImportAction;

  /// No description provided for @sourcesDownloadAndImport.
  ///
  /// In en, this message translates to:
  /// **'Download & import'**
  String get sourcesDownloadAndImport;

  /// No description provided for @searchFailed.
  ///
  /// In en, this message translates to:
  /// **'Search failed'**
  String get searchFailed;

  /// No description provided for @searchNoSourcesTitle.
  ///
  /// In en, this message translates to:
  /// **'No sources available'**
  String get searchNoSourcesTitle;

  /// No description provided for @searchNoSourcesHint.
  ///
  /// In en, this message translates to:
  /// **'Import and enable a source in Source Management, or select an available source.'**
  String get searchNoSourcesHint;

  /// No description provided for @searchNoResultsInSource.
  ///
  /// In en, this message translates to:
  /// **'No results found in “{source}”'**
  String searchNoResultsInSource(String source);

  /// No description provided for @searchKindSongs.
  ///
  /// In en, this message translates to:
  /// **'Songs'**
  String get searchKindSongs;

  /// No description provided for @searchKindArtists.
  ///
  /// In en, this message translates to:
  /// **'Artists'**
  String get searchKindArtists;

  /// No description provided for @searchKindLyrics.
  ///
  /// In en, this message translates to:
  /// **'Lyrics'**
  String get searchKindLyrics;

  /// No description provided for @searchLoadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get searchLoadMore;

  /// No description provided for @searchLoadMoreWithTotal.
  ///
  /// In en, this message translates to:
  /// **'Load more ({total} tracks)'**
  String searchLoadMoreWithTotal(int total);

  /// No description provided for @languageSettingTitle.
  ///
  /// In en, this message translates to:
  /// **'App Language'**
  String get languageSettingTitle;

  /// No description provided for @languageSettingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Change the interface display language'**
  String get languageSettingSubtitle;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get languageSystem;

  /// No description provided for @recentlyPlayedEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing played recently yet. Albums and playlists you play will show up here.'**
  String get recentlyPlayedEmpty;

  /// No description provided for @libraryRecentPlays.
  ///
  /// In en, this message translates to:
  /// **'Recent Plays'**
  String get libraryRecentPlays;

  /// No description provided for @libraryPlaylists.
  ///
  /// In en, this message translates to:
  /// **'My Playlists'**
  String get libraryPlaylists;

  /// No description provided for @libraryImportFavorites.
  ///
  /// In en, this message translates to:
  /// **'Import Favorites'**
  String get libraryImportFavorites;

  /// No description provided for @libraryImportFavoritesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Import a favorites list exported from LX Music (.lxmc)'**
  String get libraryImportFavoritesSubtitle;

  /// No description provided for @libraryImportSuccess.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} tracks'**
  String libraryImportSuccess(int count);

  /// No description provided for @libraryImportFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed: {reason}'**
  String libraryImportFailed(String reason);

  /// No description provided for @libraryImportUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Importing .lxmc favorites is not supported on this platform'**
  String get libraryImportUnsupported;

  /// No description provided for @libraryImportNoTracks.
  ///
  /// In en, this message translates to:
  /// **'No importable tracks found in the file'**
  String get libraryImportNoTracks;

  /// No description provided for @historyClear.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get historyClear;

  /// No description provided for @historyClearConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear all play history? This cannot be undone.'**
  String get historyClearConfirm;

  /// No description provided for @historyEmpty.
  ///
  /// In en, this message translates to:
  /// **'No play history yet'**
  String get historyEmpty;

  /// No description provided for @favoriteAdd.
  ///
  /// In en, this message translates to:
  /// **'Add to favorites'**
  String get favoriteAdd;

  /// No description provided for @favoriteRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove from favorites'**
  String get favoriteRemove;

  /// No description provided for @favoritesPlaylistName.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favoritesPlaylistName;

  /// No description provided for @favoritesLabel.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favoritesLabel;

  /// No description provided for @favoritesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No favorites yet'**
  String get favoritesEmpty;

  /// No description provided for @favoritesSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search songs'**
  String get favoritesSearchHint;

  /// No description provided for @favoritesSearchEmpty.
  ///
  /// In en, this message translates to:
  /// **'No matching tracks'**
  String get favoritesSearchEmpty;

  /// No description provided for @favoritesSwitchTitle.
  ///
  /// In en, this message translates to:
  /// **'Switch collection'**
  String get favoritesSwitchTitle;

  /// No description provided for @shufflePlay.
  ///
  /// In en, this message translates to:
  /// **'Shuffle'**
  String get shufflePlay;

  /// No description provided for @sortTooltip.
  ///
  /// In en, this message translates to:
  /// **'Sort'**
  String get sortTooltip;

  /// No description provided for @trackActionsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Track actions'**
  String get trackActionsTooltip;

  /// No description provided for @sortDefaultOrder.
  ///
  /// In en, this message translates to:
  /// **'Default order'**
  String get sortDefaultOrder;

  /// No description provided for @sortByTitle.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get sortByTitle;

  /// No description provided for @sortByArtist.
  ///
  /// In en, this message translates to:
  /// **'Artist'**
  String get sortByArtist;

  /// No description provided for @playAll.
  ///
  /// In en, this message translates to:
  /// **'Play all'**
  String get playAll;

  /// No description provided for @nextTrackTooltip.
  ///
  /// In en, this message translates to:
  /// **'Next track'**
  String get nextTrackTooltip;

  /// No description provided for @windowMinimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize'**
  String get windowMinimize;

  /// No description provided for @windowMaximize.
  ///
  /// In en, this message translates to:
  /// **'Maximize'**
  String get windowMaximize;

  /// No description provided for @windowRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get windowRestore;

  /// No description provided for @windowClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get windowClose;

  /// No description provided for @playlistEmpty.
  ///
  /// In en, this message translates to:
  /// **'No playlists yet. Create one or import an LX Music favorites file.'**
  String get playlistEmpty;

  /// No description provided for @playlistTracksEmpty.
  ///
  /// In en, this message translates to:
  /// **'This playlist has no tracks yet'**
  String get playlistTracksEmpty;

  /// No description provided for @playlistTrackCount.
  ///
  /// In en, this message translates to:
  /// **'{count} tracks'**
  String playlistTrackCount(int count);

  /// No description provided for @playlistDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete playlist'**
  String get playlistDelete;

  /// No description provided for @playlistDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete “{name}”?'**
  String playlistDeleteConfirm(String name);

  /// No description provided for @playlistRemoveTrack.
  ///
  /// In en, this message translates to:
  /// **'Remove from playlist'**
  String get playlistRemoveTrack;

  /// No description provided for @playlistCreate.
  ///
  /// In en, this message translates to:
  /// **'New playlist'**
  String get playlistCreate;

  /// No description provided for @playlistCreateConfirm.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get playlistCreateConfirm;

  /// No description provided for @playlistCreateHint.
  ///
  /// In en, this message translates to:
  /// **'Playlist name'**
  String get playlistCreateHint;

  /// No description provided for @playlistNameRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter a playlist name'**
  String get playlistNameRequired;

  /// No description provided for @playlistNameExists.
  ///
  /// In en, this message translates to:
  /// **'A playlist with this name already exists'**
  String get playlistNameExists;

  /// No description provided for @playlistRename.
  ///
  /// In en, this message translates to:
  /// **'Rename playlist'**
  String get playlistRename;

  /// No description provided for @addToPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Add to playlist'**
  String get addToPlaylist;

  /// No description provided for @playlistReorder.
  ///
  /// In en, this message translates to:
  /// **'Reorder'**
  String get playlistReorder;

  /// No description provided for @playlistReorderHint.
  ///
  /// In en, this message translates to:
  /// **'Long-press and drag to reorder'**
  String get playlistReorderHint;

  /// No description provided for @playlistReorderDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get playlistReorderDone;

  /// No description provided for @selectAllItems.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get selectAllItems;

  /// No description provided for @historyDeleteEntry.
  ///
  /// In en, this message translates to:
  /// **'Delete entry'**
  String get historyDeleteEntry;

  /// No description provided for @sourceSwap.
  ///
  /// In en, this message translates to:
  /// **'Change source'**
  String get sourceSwap;

  /// No description provided for @sourceSwapSearching.
  ///
  /// In en, this message translates to:
  /// **'Searching other sources…'**
  String get sourceSwapSearching;

  /// No description provided for @sourceSwapEmpty.
  ///
  /// In en, this message translates to:
  /// **'No match found in other sources'**
  String get sourceSwapEmpty;

  /// No description provided for @sourceSwapNoSources.
  ///
  /// In en, this message translates to:
  /// **'No other sources available'**
  String get sourceSwapNoSources;

  /// No description provided for @sourceSwapFailedSources.
  ///
  /// In en, this message translates to:
  /// **'{count} source(s) failed to search'**
  String sourceSwapFailedSources(int count);

  /// No description provided for @sourceSwapConfirm.
  ///
  /// In en, this message translates to:
  /// **'Change source'**
  String get sourceSwapConfirm;

  /// No description provided for @sourceSwapPreviewContext.
  ///
  /// In en, this message translates to:
  /// **'Source preview'**
  String get sourceSwapPreviewContext;

  /// No description provided for @sourceSwapDuplicateTitle.
  ///
  /// In en, this message translates to:
  /// **'Track already exists'**
  String get sourceSwapDuplicateTitle;

  /// No description provided for @sourceSwapDuplicateMessage.
  ///
  /// In en, this message translates to:
  /// **'The target playlist already contains this track. Changing the source will remove the duplicate and replace it with the selected version.'**
  String get sourceSwapDuplicateMessage;

  /// No description provided for @sourceSwapDone.
  ///
  /// In en, this message translates to:
  /// **'Source changed'**
  String get sourceSwapDone;

  /// No description provided for @sourceSwapQueueFollowed.
  ///
  /// In en, this message translates to:
  /// **'Source changed and playback switched'**
  String get sourceSwapQueueFollowed;

  /// No description provided for @sourceSwapNotFound.
  ///
  /// In en, this message translates to:
  /// **'The track is no longer in its original place'**
  String get sourceSwapNotFound;

  /// No description provided for @sourceSwapApplyFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to change source, please try again'**
  String get sourceSwapApplyFailed;

  /// No description provided for @sourceSwapTabLyrics.
  ///
  /// In en, this message translates to:
  /// **'Lyrics'**
  String get sourceSwapTabLyrics;

  /// No description provided for @sourceSwapTabAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get sourceSwapTabAudio;

  /// No description provided for @playlistAddedTo.
  ///
  /// In en, this message translates to:
  /// **'Added to “{name}”'**
  String playlistAddedTo(String name);

  /// No description provided for @playlistAlreadyContains.
  ///
  /// In en, this message translates to:
  /// **'Already in playlist'**
  String get playlistAlreadyContains;

  /// No description provided for @playlistImportToMine.
  ///
  /// In en, this message translates to:
  /// **'Import to my playlists'**
  String get playlistImportToMine;

  /// No description provided for @playlistImportFromFile.
  ///
  /// In en, this message translates to:
  /// **'Import from .lxmc file'**
  String get playlistImportFromFile;

  /// No description provided for @playlistImportFromLink.
  ///
  /// In en, this message translates to:
  /// **'Import from playlist link'**
  String get playlistImportFromLink;

  /// No description provided for @playlistImportChannel.
  ///
  /// In en, this message translates to:
  /// **'Platform'**
  String get playlistImportChannel;

  /// No description provided for @playlistImportEmpty.
  ///
  /// In en, this message translates to:
  /// **'Playlist has no importable tracks'**
  String get playlistImportEmpty;

  /// No description provided for @playlistImportedName.
  ///
  /// In en, this message translates to:
  /// **'Imported playlist'**
  String get playlistImportedName;

  /// No description provided for @discoverSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get discoverSectionTitle;

  /// No description provided for @discoverLeaderboards.
  ///
  /// In en, this message translates to:
  /// **'Charts'**
  String get discoverLeaderboards;

  /// No description provided for @discoverPlaylists.
  ///
  /// In en, this message translates to:
  /// **'Playlists'**
  String get discoverPlaylists;

  /// No description provided for @discoverHotSearches.
  ///
  /// In en, this message translates to:
  /// **'Trending'**
  String get discoverHotSearches;

  /// No description provided for @discoverOpenPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Open playlist'**
  String get discoverOpenPlaylist;

  /// No description provided for @discoverOpenPlaylistHint.
  ///
  /// In en, this message translates to:
  /// **'Paste a playlist link or ID'**
  String get discoverOpenPlaylistHint;

  /// No description provided for @discoverOpen.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get discoverOpen;

  /// No description provided for @discoverPlaylistSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search playlists'**
  String get discoverPlaylistSearchHint;

  /// No description provided for @discoverHotTags.
  ///
  /// In en, this message translates to:
  /// **'Popular tags'**
  String get discoverHotTags;

  /// No description provided for @discoverAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get discoverAll;

  /// No description provided for @discoverAllTags.
  ///
  /// In en, this message translates to:
  /// **'All tags'**
  String get discoverAllTags;

  /// No description provided for @discoverLoadMore.
  ///
  /// In en, this message translates to:
  /// **'Load more'**
  String get discoverLoadMore;

  /// No description provided for @discoverLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load'**
  String get discoverLoadFailed;

  /// No description provided for @discoverRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get discoverRetry;

  /// No description provided for @discoverNoContent.
  ///
  /// In en, this message translates to:
  /// **'Nothing here yet'**
  String get discoverNoContent;

  /// No description provided for @discoverSearchEmpty.
  ///
  /// In en, this message translates to:
  /// **'No playlists found'**
  String get discoverSearchEmpty;

  /// No description provided for @discoverPlaylistAuthor.
  ///
  /// In en, this message translates to:
  /// **'by {author}'**
  String discoverPlaylistAuthor(String author);

  /// No description provided for @discoverAddToPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Add to playlist'**
  String get discoverAddToPlaylist;

  /// No description provided for @discoverNoPlaylists.
  ///
  /// In en, this message translates to:
  /// **'No playlists yet. Favorite a song first to create one.'**
  String get discoverNoPlaylists;

  /// No description provided for @discoverPlayCount.
  ///
  /// In en, this message translates to:
  /// **'{count} plays'**
  String discoverPlayCount(String count);

  /// No description provided for @albumEmpty.
  ///
  /// In en, this message translates to:
  /// **'No tracks in this album'**
  String get albumEmpty;

  /// No description provided for @albumLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load album'**
  String get albumLoadFailed;

  /// No description provided for @artistEmpty.
  ///
  /// In en, this message translates to:
  /// **'No tracks for this artist'**
  String get artistEmpty;

  /// No description provided for @artistLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load artist'**
  String get artistLoadFailed;

  /// No description provided for @artistNotFound.
  ///
  /// In en, this message translates to:
  /// **'Artist not found'**
  String get artistNotFound;

  /// No description provided for @unknownArtist.
  ///
  /// In en, this message translates to:
  /// **'Unknown artist'**
  String get unknownArtist;

  /// No description provided for @artistSongCount.
  ///
  /// In en, this message translates to:
  /// **'{count} songs'**
  String artistSongCount(int count);

  /// No description provided for @albumYear.
  ///
  /// In en, this message translates to:
  /// **'{year}'**
  String albumYear(int year);

  /// No description provided for @settingsAppTitle.
  ///
  /// In en, this message translates to:
  /// **'App name'**
  String get settingsAppTitle;

  /// No description provided for @settingsAppTitleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Shown in the top bar when nothing is playing'**
  String get settingsAppTitleSubtitle;

  /// No description provided for @settingsAppTitleDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'App name'**
  String get settingsAppTitleDialogTitle;

  /// No description provided for @settingsAppTitleHint.
  ///
  /// In en, this message translates to:
  /// **'Enter a name'**
  String get settingsAppTitleHint;

  /// Default app name (brand title, localized)
  ///
  /// In en, this message translates to:
  /// **'Molia'**
  String get appName;

  /// No description provided for @libraryRecentContexts.
  ///
  /// In en, this message translates to:
  /// **'Recently Played'**
  String get libraryRecentContexts;

  /// No description provided for @libraryHistory.
  ///
  /// In en, this message translates to:
  /// **'Play History'**
  String get libraryHistory;

  /// No description provided for @libraryLocalSongs.
  ///
  /// In en, this message translates to:
  /// **'Local tracks'**
  String get libraryLocalSongs;

  /// No description provided for @libraryImportLocalSongs.
  ///
  /// In en, this message translates to:
  /// **'Import local tracks'**
  String get libraryImportLocalSongs;

  /// No description provided for @libraryImportLocalSongsDone.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} tracks'**
  String libraryImportLocalSongsDone(int count);

  /// No description provided for @libraryImportLocalSongsSkipped.
  ///
  /// In en, this message translates to:
  /// **'Imported {imported} tracks, {skipped} skipped'**
  String libraryImportLocalSongsSkipped(int imported, int skipped);

  /// No description provided for @localSongsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No local tracks yet'**
  String get localSongsEmpty;

  /// No description provided for @localSongsRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove from list'**
  String get localSongsRemove;

  /// No description provided for @localSongsRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Removes the entry only; the original file is kept.'**
  String get localSongsRemoveConfirm;

  /// No description provided for @libraryListEnd.
  ///
  /// In en, this message translates to:
  /// **'— End —'**
  String get libraryListEnd;

  /// No description provided for @settingsCacheTitle.
  ///
  /// In en, this message translates to:
  /// **'Cache management'**
  String get settingsCacheTitle;

  /// No description provided for @settingsCacheSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Audio, lyrics and artwork usage and policies'**
  String get settingsCacheSubtitle;

  /// No description provided for @cachePartitionAudio.
  ///
  /// In en, this message translates to:
  /// **'Audio cache'**
  String get cachePartitionAudio;

  /// No description provided for @cachePartitionLyrics.
  ///
  /// In en, this message translates to:
  /// **'Lyrics cache'**
  String get cachePartitionLyrics;

  /// No description provided for @cachePartitionArtwork.
  ///
  /// In en, this message translates to:
  /// **'Artwork cache'**
  String get cachePartitionArtwork;

  /// No description provided for @cacheUsage.
  ///
  /// In en, this message translates to:
  /// **'{size} · {count} items'**
  String cacheUsage(String size, int count);

  /// No description provided for @cacheUsageComputing.
  ///
  /// In en, this message translates to:
  /// **'Calculating…'**
  String get cacheUsageComputing;

  /// No description provided for @cachePolicyAudioEnabled.
  ///
  /// In en, this message translates to:
  /// **'Cache audio while playing'**
  String get cachePolicyAudioEnabled;

  /// No description provided for @cachePolicyAudioScope.
  ///
  /// In en, this message translates to:
  /// **'Cache on play'**
  String get cachePolicyAudioScope;

  /// No description provided for @cachePolicyAudioHint.
  ///
  /// In en, this message translates to:
  /// **'Written while playing on mobile; filled in by a background download on desktop. Cached tracks play offline and can be saved as downloads; the size limit and LRU eviction still apply.'**
  String get cachePolicyAudioHint;

  /// No description provided for @cachePolicyAudioMax.
  ///
  /// In en, this message translates to:
  /// **'Size limit'**
  String get cachePolicyAudioMax;

  /// No description provided for @cachePolicyLyricsTtl.
  ///
  /// In en, this message translates to:
  /// **'Keep lyrics for'**
  String get cachePolicyLyricsTtl;

  /// No description provided for @cachePolicyArtworkMax.
  ///
  /// In en, this message translates to:
  /// **'Max artwork objects'**
  String get cachePolicyArtworkMax;

  /// No description provided for @cachePolicyArtworkStale.
  ///
  /// In en, this message translates to:
  /// **'Expire artwork after'**
  String get cachePolicyArtworkStale;

  /// No description provided for @cacheUnlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get cacheUnlimited;

  /// No description provided for @cacheNeverExpire.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get cacheNeverExpire;

  /// No description provided for @cacheValueMb.
  ///
  /// In en, this message translates to:
  /// **'{value} MB'**
  String cacheValueMb(int value);

  /// No description provided for @cacheValueGb.
  ///
  /// In en, this message translates to:
  /// **'{value} GB'**
  String cacheValueGb(int value);

  /// No description provided for @cacheValueDays.
  ///
  /// In en, this message translates to:
  /// **'{value} days'**
  String cacheValueDays(int value);

  /// No description provided for @cacheValueItems.
  ///
  /// In en, this message translates to:
  /// **'{value}'**
  String cacheValueItems(int value);

  /// No description provided for @cacheUnitMb.
  ///
  /// In en, this message translates to:
  /// **'MB'**
  String get cacheUnitMb;

  /// No description provided for @cacheUnitDays.
  ///
  /// In en, this message translates to:
  /// **'days'**
  String get cacheUnitDays;

  /// No description provided for @cacheUnitItems.
  ///
  /// In en, this message translates to:
  /// **'items'**
  String get cacheUnitItems;

  /// No description provided for @cacheCustomHint.
  ///
  /// In en, this message translates to:
  /// **'0 = {label} · Range {min}–{max}'**
  String cacheCustomHint(String label, int min, int max);

  /// No description provided for @cacheAudioMaxSuggested.
  ///
  /// In en, this message translates to:
  /// **'Suggested {value} (internal storage ÷ 128)'**
  String cacheAudioMaxSuggested(String value);

  /// No description provided for @cacheCustomRangeError.
  ///
  /// In en, this message translates to:
  /// **'Enter an integer between {min} and {max}'**
  String cacheCustomRangeError(int min, int max);

  /// No description provided for @cacheClearPartition.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get cacheClearPartition;

  /// No description provided for @cacheClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear all caches'**
  String get cacheClearAll;

  /// No description provided for @cacheClearAllConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear all caches (audio / lyrics / artwork)? This cannot be undone.'**
  String get cacheClearAllConfirm;

  /// No description provided for @lyricsContentTitle.
  ///
  /// In en, this message translates to:
  /// **'Lyrics & outputs'**
  String get lyricsContentTitle;

  /// No description provided for @lyricsContentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Lyrics page, translation, offset and shared options'**
  String get lyricsContentSubtitle;

  /// No description provided for @lyricsPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Lyrics page'**
  String get lyricsPageTitle;

  /// No description provided for @lyricsPageTranslationSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show translation under each line in the lyrics page'**
  String get lyricsPageTranslationSubtitle;

  /// No description provided for @lyricsPageRomaSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show romanization under each line in the lyrics page'**
  String get lyricsPageRomaSubtitle;

  /// No description provided for @lyricsDisplaySharedTitle.
  ///
  /// In en, this message translates to:
  /// **'Lyric outputs'**
  String get lyricsDisplaySharedTitle;

  /// No description provided for @lyricsDisplayTranslation.
  ///
  /// In en, this message translates to:
  /// **'Translation'**
  String get lyricsDisplayTranslation;

  /// No description provided for @lyricsDisplayTranslationSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show translation in floating, notification and Bluetooth lyrics'**
  String get lyricsDisplayTranslationSubtitle;

  /// No description provided for @lyricsDisplayRoma.
  ///
  /// In en, this message translates to:
  /// **'Romanization'**
  String get lyricsDisplayRoma;

  /// No description provided for @lyricsDisplayRomaSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show romanization in floating, notification and Bluetooth lyrics'**
  String get lyricsDisplayRomaSubtitle;

  /// No description provided for @lyricsDisplayUnsynced.
  ///
  /// In en, this message translates to:
  /// **'Unsynced lyrics'**
  String get lyricsDisplayUnsynced;

  /// No description provided for @lyricsDisplayUnsyncedTitle.
  ///
  /// In en, this message translates to:
  /// **'Show song title'**
  String get lyricsDisplayUnsyncedTitle;

  /// No description provided for @lyricsDisplayUnsyncedHide.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get lyricsDisplayUnsyncedHide;

  /// No description provided for @lyricsDisplayUnsyncedFirstLine.
  ///
  /// In en, this message translates to:
  /// **'Show first line'**
  String get lyricsDisplayUnsyncedFirstLine;

  /// No description provided for @lyricsDisplayOffset.
  ///
  /// In en, this message translates to:
  /// **'Lyric offset'**
  String get lyricsDisplayOffset;

  /// No description provided for @lyricsDisplayOffsetValue.
  ///
  /// In en, this message translates to:
  /// **'{ms} ms'**
  String lyricsDisplayOffsetValue(int ms);

  /// No description provided for @lyricsDesktopTitle.
  ///
  /// In en, this message translates to:
  /// **'Floating lyrics'**
  String get lyricsDesktopTitle;

  /// No description provided for @lyricsDesktopEntrySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Floating window style, behavior and colors'**
  String get lyricsDesktopEntrySubtitle;

  /// No description provided for @lyricsDesktopEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable floating lyrics'**
  String get lyricsDesktopEnable;

  /// No description provided for @lyricsDesktopEnableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show the current line above other apps'**
  String get lyricsDesktopEnableSubtitle;

  /// No description provided for @lyricsDesktopPermissionNeeded.
  ///
  /// In en, this message translates to:
  /// **'Overlay permission required'**
  String get lyricsDesktopPermissionNeeded;

  /// No description provided for @lyricsDesktopPermissionGrant.
  ///
  /// In en, this message translates to:
  /// **'Grant'**
  String get lyricsDesktopPermissionGrant;

  /// No description provided for @lyricsDesktopPreview.
  ///
  /// In en, this message translates to:
  /// **'Style preview'**
  String get lyricsDesktopPreview;

  /// No description provided for @lyricsDesktopPreviewLine.
  ///
  /// In en, this message translates to:
  /// **'I can\'t just be an ordinary friend'**
  String get lyricsDesktopPreviewLine;

  /// No description provided for @lyricsDesktopPreviewTranslation.
  ///
  /// In en, this message translates to:
  /// **'我无法只是普通朋友'**
  String get lyricsDesktopPreviewTranslation;

  /// No description provided for @lyricsDesktopFontSize.
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get lyricsDesktopFontSize;

  /// No description provided for @lyricsDesktopOpacity.
  ///
  /// In en, this message translates to:
  /// **'Opacity'**
  String get lyricsDesktopOpacity;

  /// No description provided for @lyricsDesktopWidth.
  ///
  /// In en, this message translates to:
  /// **'Width'**
  String get lyricsDesktopWidth;

  /// No description provided for @lyricsDesktopMaxLines.
  ///
  /// In en, this message translates to:
  /// **'Visible lines'**
  String get lyricsDesktopMaxLines;

  /// No description provided for @lyricsDesktopAlign.
  ///
  /// In en, this message translates to:
  /// **'Horizontal align'**
  String get lyricsDesktopAlign;

  /// No description provided for @lyricsDesktopAlignVertical.
  ///
  /// In en, this message translates to:
  /// **'Vertical align'**
  String get lyricsDesktopAlignVertical;

  /// No description provided for @lyricsDesktopAlignLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get lyricsDesktopAlignLeft;

  /// No description provided for @lyricsDesktopAlignCenter.
  ///
  /// In en, this message translates to:
  /// **'Center'**
  String get lyricsDesktopAlignCenter;

  /// No description provided for @lyricsDesktopAlignRight.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get lyricsDesktopAlignRight;

  /// No description provided for @lyricsDesktopAlignTop.
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get lyricsDesktopAlignTop;

  /// No description provided for @lyricsDesktopAlignBottom.
  ///
  /// In en, this message translates to:
  /// **'Bottom'**
  String get lyricsDesktopAlignBottom;

  /// No description provided for @lyricsDesktopColorPlayed.
  ///
  /// In en, this message translates to:
  /// **'Current line color'**
  String get lyricsDesktopColorPlayed;

  /// No description provided for @lyricsDesktopColorUnplayed.
  ///
  /// In en, this message translates to:
  /// **'Other lines color'**
  String get lyricsDesktopColorUnplayed;

  /// No description provided for @lyricsDesktopColorShadow.
  ///
  /// In en, this message translates to:
  /// **'Shadow color'**
  String get lyricsDesktopColorShadow;

  /// No description provided for @lyricsDesktopSchemeSource.
  ///
  /// In en, this message translates to:
  /// **'Color source'**
  String get lyricsDesktopSchemeSource;

  /// No description provided for @lyricsDesktopSchemeAppTheme.
  ///
  /// In en, this message translates to:
  /// **'Follow app theme'**
  String get lyricsDesktopSchemeAppTheme;

  /// No description provided for @lyricsDesktopSchemeArtwork.
  ///
  /// In en, this message translates to:
  /// **'Follow album art'**
  String get lyricsDesktopSchemeArtwork;

  /// No description provided for @lyricsDesktopLock.
  ///
  /// In en, this message translates to:
  /// **'Lock position (click-through)'**
  String get lyricsDesktopLock;

  /// No description provided for @lyricsDesktopFreeze.
  ///
  /// In en, this message translates to:
  /// **'Freeze while screen off'**
  String get lyricsDesktopFreeze;

  /// No description provided for @lyricsDesktopPauseBehavior.
  ///
  /// In en, this message translates to:
  /// **'When paused'**
  String get lyricsDesktopPauseBehavior;

  /// No description provided for @lyricsDesktopHideOnPause.
  ///
  /// In en, this message translates to:
  /// **'Hide when paused'**
  String get lyricsDesktopHideOnPause;

  /// No description provided for @lyricsDesktopHideOnPauseSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Collapse the floating window while paused; it returns when playback resumes'**
  String get lyricsDesktopHideOnPauseSubtitle;

  /// No description provided for @lyricsDesktopPauseFallbackOverridden.
  ///
  /// In en, this message translates to:
  /// **'The window is hidden while paused, so this fallback is inactive'**
  String get lyricsDesktopPauseFallbackOverridden;

  /// No description provided for @lyricsDesktopNoLyrics.
  ///
  /// In en, this message translates to:
  /// **'Without lyrics'**
  String get lyricsDesktopNoLyrics;

  /// No description provided for @lyricsDesktopAnimation.
  ///
  /// In en, this message translates to:
  /// **'Line transition animation'**
  String get lyricsDesktopAnimation;

  /// No description provided for @lyricsDesktopBehaviorSection.
  ///
  /// In en, this message translates to:
  /// **'Behavior & controls'**
  String get lyricsDesktopBehaviorSection;

  /// No description provided for @lyricsSharedDisplaySection.
  ///
  /// In en, this message translates to:
  /// **'Lyric display'**
  String get lyricsSharedDisplaySection;

  /// No description provided for @lyricsDesktopResetPosition.
  ///
  /// In en, this message translates to:
  /// **'Reset position'**
  String get lyricsDesktopResetPosition;

  /// No description provided for @lyricsControlPlayPause.
  ///
  /// In en, this message translates to:
  /// **'Play / pause'**
  String get lyricsControlPlayPause;

  /// No description provided for @lyricsControlPrevious.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get lyricsControlPrevious;

  /// No description provided for @lyricsControlNext.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get lyricsControlNext;

  /// No description provided for @lyricsControlTranslation.
  ///
  /// In en, this message translates to:
  /// **'Translation'**
  String get lyricsControlTranslation;

  /// No description provided for @lyricsControlLock.
  ///
  /// In en, this message translates to:
  /// **'Lock'**
  String get lyricsControlLock;

  /// No description provided for @lyricsControlClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get lyricsControlClose;

  /// No description provided for @lyricsSystemMediaTitle.
  ///
  /// In en, this message translates to:
  /// **'System media lyrics'**
  String get lyricsSystemMediaTitle;

  /// No description provided for @lyricsSystemMediaSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Notification, lock screen and Bluetooth'**
  String get lyricsSystemMediaSubtitle;

  /// No description provided for @lyricsBehaviorKeep.
  ///
  /// In en, this message translates to:
  /// **'Keep'**
  String get lyricsBehaviorKeep;

  /// No description provided for @lyricsBehaviorTitle.
  ///
  /// In en, this message translates to:
  /// **'Song title'**
  String get lyricsBehaviorTitle;

  /// No description provided for @lyricsBehaviorClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get lyricsBehaviorClear;

  /// No description provided for @lyricsNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'Notification & lock screen'**
  String get lyricsNotificationTitle;

  /// No description provided for @lyricsNotificationEnable.
  ///
  /// In en, this message translates to:
  /// **'Show lyrics in notification'**
  String get lyricsNotificationEnable;

  /// No description provided for @lyricsNotificationEnableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Writes the current line into media metadata'**
  String get lyricsNotificationEnableSubtitle;

  /// No description provided for @lyricsMetadataTarget.
  ///
  /// In en, this message translates to:
  /// **'Show in'**
  String get lyricsMetadataTarget;

  /// No description provided for @lyricsMetadataTargetSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Subtitle'**
  String get lyricsMetadataTargetSubtitle;

  /// No description provided for @lyricsMetadataTargetArtist.
  ///
  /// In en, this message translates to:
  /// **'Artist'**
  String get lyricsMetadataTargetArtist;

  /// No description provided for @lyricsMetadataTargetTitle.
  ///
  /// In en, this message translates to:
  /// **'Title'**
  String get lyricsMetadataTargetTitle;

  /// No description provided for @lyricsMetadataTargetAlbum.
  ///
  /// In en, this message translates to:
  /// **'Album'**
  String get lyricsMetadataTargetAlbum;

  /// No description provided for @lyricsMetadataFormat.
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get lyricsMetadataFormat;

  /// No description provided for @lyricsMetadataFormatLyric.
  ///
  /// In en, this message translates to:
  /// **'Lyrics only'**
  String get lyricsMetadataFormatLyric;

  /// No description provided for @lyricsMetadataFormatLyricTitle.
  ///
  /// In en, this message translates to:
  /// **'Lyrics · title'**
  String get lyricsMetadataFormatLyricTitle;

  /// No description provided for @lyricsMetadataFormatTitleLyric.
  ///
  /// In en, this message translates to:
  /// **'Title · lyrics'**
  String get lyricsMetadataFormatTitleLyric;

  /// No description provided for @lyricsMetadataIncludeTranslation.
  ///
  /// In en, this message translates to:
  /// **'Include translation'**
  String get lyricsMetadataIncludeTranslation;

  /// No description provided for @lyricsMetadataPauseBehavior.
  ///
  /// In en, this message translates to:
  /// **'When paused'**
  String get lyricsMetadataPauseBehavior;

  /// No description provided for @lyricsBluetoothTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth lyrics'**
  String get lyricsBluetoothTitle;

  /// No description provided for @lyricsBluetoothEnable.
  ///
  /// In en, this message translates to:
  /// **'Show lyrics on car display'**
  String get lyricsBluetoothEnable;

  /// No description provided for @lyricsBluetoothEnableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Writes the current line into media metadata (also visible in notification & lock screen)'**
  String get lyricsBluetoothEnableSubtitle;

  /// No description provided for @lyricsBluetoothOnlyA2dp.
  ///
  /// In en, this message translates to:
  /// **'Only while Bluetooth audio is connected'**
  String get lyricsBluetoothOnlyA2dp;

  /// No description provided for @lyricsBluetoothStatusConnected.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth audio connected'**
  String get lyricsBluetoothStatusConnected;

  /// No description provided for @lyricsBluetoothStatusDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth audio not connected'**
  String get lyricsBluetoothStatusDisconnected;

  /// No description provided for @lyricsBluetoothUpdateInterval.
  ///
  /// In en, this message translates to:
  /// **'Update interval'**
  String get lyricsBluetoothUpdateInterval;

  /// No description provided for @lyricsBluetoothIntervalLine.
  ///
  /// In en, this message translates to:
  /// **'Every line'**
  String get lyricsBluetoothIntervalLine;

  /// No description provided for @lyricsBluetoothInterval1s.
  ///
  /// In en, this message translates to:
  /// **'Every second'**
  String get lyricsBluetoothInterval1s;

  /// No description provided for @lyricsBluetoothInterval2s.
  ///
  /// In en, this message translates to:
  /// **'Every 2 seconds'**
  String get lyricsBluetoothInterval2s;

  /// No description provided for @lyricsNotificationPermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Notification permission needed'**
  String get lyricsNotificationPermissionTitle;

  /// No description provided for @lyricsNotificationPermissionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications so the media card appears; tap to open system settings'**
  String get lyricsNotificationPermissionSubtitle;

  /// No description provided for @lyricsMediaSessionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'System media session unavailable: notification / lock-screen lyrics and playback controls are disabled'**
  String get lyricsMediaSessionUnavailable;

  /// No description provided for @lyricsDisplayUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Lyric outputs are not available on this platform'**
  String get lyricsDisplayUnsupported;

  /// No description provided for @colorPickerTitle.
  ///
  /// In en, this message translates to:
  /// **'Pick a color'**
  String get colorPickerTitle;

  /// No description provided for @colorPickerCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom color…'**
  String get colorPickerCustom;

  /// No description provided for @colorPickerHex.
  ///
  /// In en, this message translates to:
  /// **'Hex color'**
  String get colorPickerHex;

  /// No description provided for @colorPickerInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid color value'**
  String get colorPickerInvalid;

  /// No description provided for @colorPickerHue.
  ///
  /// In en, this message translates to:
  /// **'Hue'**
  String get colorPickerHue;

  /// No description provided for @colorPickerSaturation.
  ///
  /// In en, this message translates to:
  /// **'Saturation'**
  String get colorPickerSaturation;

  /// No description provided for @colorPickerBrightness.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get colorPickerBrightness;

  /// No description provided for @colorPickerOpacity.
  ///
  /// In en, this message translates to:
  /// **'Opacity'**
  String get colorPickerOpacity;

  /// No description provided for @lyricsColorSource.
  ///
  /// In en, this message translates to:
  /// **'Color'**
  String get lyricsColorSource;

  /// No description provided for @lyricsColorSourceCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get lyricsColorSourceCustom;

  /// No description provided for @lyricsColorSourcePrimary.
  ///
  /// In en, this message translates to:
  /// **'Primary'**
  String get lyricsColorSourcePrimary;

  /// No description provided for @lyricsColorSourceSecondary.
  ///
  /// In en, this message translates to:
  /// **'Secondary'**
  String get lyricsColorSourceSecondary;

  /// No description provided for @lyricsColorSourceTertiary.
  ///
  /// In en, this message translates to:
  /// **'Tertiary'**
  String get lyricsColorSourceTertiary;

  /// No description provided for @lyricsColorSourceOnSurface.
  ///
  /// In en, this message translates to:
  /// **'On surface'**
  String get lyricsColorSourceOnSurface;

  /// No description provided for @lyricsColorSourceOnSurfaceVariant.
  ///
  /// In en, this message translates to:
  /// **'Variant'**
  String get lyricsColorSourceOnSurfaceVariant;

  /// No description provided for @lyricsColorSourceSurface.
  ///
  /// In en, this message translates to:
  /// **'Surface'**
  String get lyricsColorSourceSurface;

  /// No description provided for @lyricsDesktopColorThemeHint.
  ///
  /// In en, this message translates to:
  /// **'The color source decides which scheme the theme-role rows use: app theme follows the appearance settings; album art updates live with the current track.'**
  String get lyricsDesktopColorThemeHint;

  /// No description provided for @statsTitle.
  ///
  /// In en, this message translates to:
  /// **'Listening Stats'**
  String get statsTitle;

  /// No description provided for @statsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Play counts, listening time, and activity heatmaps (stored on this device only)'**
  String get statsSubtitle;

  /// No description provided for @statsSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Plays / activity heatmaps / export'**
  String get statsSettingsSubtitle;

  /// No description provided for @statsRecordSwitch.
  ///
  /// In en, this message translates to:
  /// **'Record listening stats'**
  String get statsRecordSwitch;

  /// No description provided for @statsRecordSwitchSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Turn off to stop recording new plays; existing data is kept'**
  String get statsRecordSwitchSubtitle;

  /// No description provided for @statsRangeWeek.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get statsRangeWeek;

  /// No description provided for @statsRangeMonth.
  ///
  /// In en, this message translates to:
  /// **'30 days'**
  String get statsRangeMonth;

  /// No description provided for @statsRangeAll.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get statsRangeAll;

  /// No description provided for @statsRangeTitle.
  ///
  /// In en, this message translates to:
  /// **'Time range'**
  String get statsRangeTitle;

  /// No description provided for @statsValueDuration.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get statsValueDuration;

  /// No description provided for @statsValueCount.
  ///
  /// In en, this message translates to:
  /// **'Plays'**
  String get statsValueCount;

  /// No description provided for @statsPlays.
  ///
  /// In en, this message translates to:
  /// **'Valid plays'**
  String get statsPlays;

  /// No description provided for @statsListened.
  ///
  /// In en, this message translates to:
  /// **'Listening time'**
  String get statsListened;

  /// No description provided for @statsTracks.
  ///
  /// In en, this message translates to:
  /// **'Tracks played'**
  String get statsTracks;

  /// No description provided for @statsSince.
  ///
  /// In en, this message translates to:
  /// **'Since'**
  String get statsSince;

  /// No description provided for @statsCompleteRate.
  ///
  /// In en, this message translates to:
  /// **'Completion rate'**
  String get statsCompleteRate;

  /// No description provided for @statsSkipRate.
  ///
  /// In en, this message translates to:
  /// **'Skip rate'**
  String get statsSkipRate;

  /// No description provided for @statsSources.
  ///
  /// In en, this message translates to:
  /// **'Sources'**
  String get statsSources;

  /// No description provided for @statsTopTracks.
  ///
  /// In en, this message translates to:
  /// **'Most played'**
  String get statsTopTracks;

  /// No description provided for @statsTopArtists.
  ///
  /// In en, this message translates to:
  /// **'Top artists'**
  String get statsTopArtists;

  /// No description provided for @statsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No listening history yet'**
  String get statsEmpty;

  /// No description provided for @statsEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Play some songs and come back'**
  String get statsEmptyHint;

  /// No description provided for @statsExport.
  ///
  /// In en, this message translates to:
  /// **'Export listening data'**
  String get statsExport;

  /// No description provided for @statsExportSubtitle.
  ///
  /// In en, this message translates to:
  /// **'JSON file (summary + last {limit} events)'**
  String statsExportSubtitle(int limit);

  /// No description provided for @statsExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed'**
  String get statsExportFailed;

  /// No description provided for @statsClear.
  ///
  /// In en, this message translates to:
  /// **'Clear stats'**
  String get statsClear;

  /// No description provided for @statsClearConfirm.
  ///
  /// In en, this message translates to:
  /// **'This will delete all listening stat events. This cannot be undone.'**
  String get statsClearConfirm;

  /// No description provided for @statsCleared.
  ///
  /// In en, this message translates to:
  /// **'Listening stats cleared'**
  String get statsCleared;

  /// No description provided for @statsPlaysCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 play} other{{count} plays}}'**
  String statsPlaysCount(int count);

  /// No description provided for @statsDurationSeconds.
  ///
  /// In en, this message translates to:
  /// **'{count} s'**
  String statsDurationSeconds(int count);

  /// No description provided for @statsDurationMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count} min'**
  String statsDurationMinutes(int count);

  /// No description provided for @statsDurationHours.
  ///
  /// In en, this message translates to:
  /// **'{hours} h {minutes} min'**
  String statsDurationHours(int hours, int minutes);

  /// No description provided for @statsDaySummary.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 play} other{{count} plays}} · {duration}'**
  String statsDaySummary(int count, String duration);

  /// No description provided for @statsTooltip.
  ///
  /// In en, this message translates to:
  /// **'{date} · {value}'**
  String statsTooltip(String date, String value);

  /// No description provided for @statsEventListened.
  ///
  /// In en, this message translates to:
  /// **'Listened {duration}'**
  String statsEventListened(String duration);

  /// No description provided for @aiDjTitle.
  ///
  /// In en, this message translates to:
  /// **'AI DJ'**
  String get aiDjTitle;

  /// No description provided for @aiDjSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'AI-powered radio with your own API key (off by default)'**
  String get aiDjSettingsSubtitle;

  /// No description provided for @aiDjNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'AI service is not configured yet'**
  String get aiDjNotConfigured;

  /// No description provided for @aiDjRequestFailed.
  ///
  /// In en, this message translates to:
  /// **'AI request failed. Try again later.'**
  String get aiDjRequestFailed;

  /// No description provided for @aiDjUnauthorized.
  ///
  /// In en, this message translates to:
  /// **'Invalid API key or permission denied'**
  String get aiDjUnauthorized;

  /// No description provided for @aiDjRateLimited.
  ///
  /// In en, this message translates to:
  /// **'Rate limited. Try again later.'**
  String get aiDjRateLimited;

  /// No description provided for @aiDjBadResponse.
  ///
  /// In en, this message translates to:
  /// **'The AI response could not be parsed'**
  String get aiDjBadResponse;

  /// No description provided for @aiDjNothingResolved.
  ///
  /// In en, this message translates to:
  /// **'No playable tracks in this batch'**
  String get aiDjNothingResolved;

  /// No description provided for @aiDjStatusOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get aiDjStatusOff;

  /// No description provided for @aiDjStatusPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing…'**
  String get aiDjStatusPreparing;

  /// No description provided for @aiDjStatusPlaying.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get aiDjStatusPlaying;

  /// No description provided for @aiDjStatusError.
  ///
  /// In en, this message translates to:
  /// **'Paused (queue kept)'**
  String get aiDjStatusError;

  /// No description provided for @aiDjToggle.
  ///
  /// In en, this message translates to:
  /// **'AI DJ mode'**
  String get aiDjToggle;

  /// No description provided for @aiDjToggleSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keeps AI-picked songs coming and extends the queue automatically'**
  String get aiDjToggleSubtitle;

  /// No description provided for @aiDjFeedMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get aiDjFeedMore;

  /// No description provided for @aiDjStopKeepQueue.
  ///
  /// In en, this message translates to:
  /// **'Keep playing'**
  String get aiDjStopKeepQueue;

  /// No description provided for @aiDjStopClearQueue.
  ///
  /// In en, this message translates to:
  /// **'Clear queue & stop'**
  String get aiDjStopClearQueue;

  /// No description provided for @aiDjStopDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Exit AI DJ?'**
  String get aiDjStopDialogTitle;

  /// No description provided for @aiDjConsentTitle.
  ///
  /// In en, this message translates to:
  /// **'Before you start'**
  String get aiDjConsentTitle;

  /// No description provided for @aiDjConsentBody.
  ///
  /// In en, this message translates to:
  /// **'When enabled, your listening profile (aggregated stats, the latest 200 play events, and the list of already-played tracks) will be sent to the AI service you configure in order to generate recommendations. Data goes straight to that service with no relay through this app, and no bundled API key is provided. Turning the mode off stops continuation; clearing the config disconnects it.'**
  String get aiDjConsentBody;

  /// No description provided for @aiDjAgree.
  ///
  /// In en, this message translates to:
  /// **'Agree & start'**
  String get aiDjAgree;

  /// No description provided for @aiDjConfigTitle.
  ///
  /// In en, this message translates to:
  /// **'AI service'**
  String get aiDjConfigTitle;

  /// No description provided for @aiDjBaseUrl.
  ///
  /// In en, this message translates to:
  /// **'Base URL'**
  String get aiDjBaseUrl;

  /// No description provided for @aiDjApiKey.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get aiDjApiKey;

  /// No description provided for @aiDjModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get aiDjModel;

  /// No description provided for @aiDjPresetCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get aiDjPresetCustom;

  /// No description provided for @aiDjTestConnection.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get aiDjTestConnection;

  /// No description provided for @aiDjTestSucceeded.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get aiDjTestSucceeded;

  /// No description provided for @aiDjTestSaved.
  ///
  /// In en, this message translates to:
  /// **'Connected — config saved'**
  String get aiDjTestSaved;

  /// No description provided for @aiDjSaveConfig.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get aiDjSaveConfig;

  /// No description provided for @aiDjClearConfig.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get aiDjClearConfig;

  /// No description provided for @aiDjConfigSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get aiDjConfigSaved;

  /// No description provided for @aiDjQueued.
  ///
  /// In en, this message translates to:
  /// **'{count} queued this session'**
  String aiDjQueued(int count);

  /// No description provided for @aiDjSkippedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} skipped'**
  String aiDjSkippedCount(int count);

  /// No description provided for @aiDjLikedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} liked'**
  String aiDjLikedCount(int count);

  /// No description provided for @aiDjUnresolved.
  ///
  /// In en, this message translates to:
  /// **'{count} not found on your sources'**
  String aiDjUnresolved(int count);

  /// No description provided for @aiDjRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get aiDjRetry;

  /// No description provided for @aiDjOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Set up AI service'**
  String get aiDjOpenSettings;

  /// No description provided for @aiDjDiscoverSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Let AI pick songs from your listening history'**
  String get aiDjDiscoverSubtitle;

  /// No description provided for @aiDjGenerating.
  ///
  /// In en, this message translates to:
  /// **'Generating recommendations…'**
  String get aiDjGenerating;

  /// No description provided for @aiDjBatchFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t generate a batch'**
  String get aiDjBatchFailed;

  /// No description provided for @aiDjRefreshBatch.
  ///
  /// In en, this message translates to:
  /// **'New batch'**
  String get aiDjRefreshBatch;

  /// No description provided for @aiDjStatusIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get aiDjStatusIdle;

  /// No description provided for @aiDjTodayTitle.
  ///
  /// In en, this message translates to:
  /// **'Today\'s picks'**
  String get aiDjTodayTitle;

  /// No description provided for @aiDjViewAll.
  ///
  /// In en, this message translates to:
  /// **'View all'**
  String get aiDjViewAll;

  /// No description provided for @aiDjLastUpdated.
  ///
  /// In en, this message translates to:
  /// **'Updated {time}'**
  String aiDjLastUpdated(String time);

  /// No description provided for @aiDjUpdatedJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get aiDjUpdatedJustNow;

  /// No description provided for @aiDjUpdatedMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String aiDjUpdatedMinutesAgo(int count);

  /// No description provided for @aiDjUpdatedHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} h ago'**
  String aiDjUpdatedHoursAgo(int count);

  /// No description provided for @aiDjUpdatedYesterday.
  ///
  /// In en, this message translates to:
  /// **'yesterday {time}'**
  String aiDjUpdatedYesterday(String time);

  /// No description provided for @aiDjUpdatedDate.
  ///
  /// In en, this message translates to:
  /// **'{month}/{day}'**
  String aiDjUpdatedDate(int month, int day);

  /// No description provided for @aiDjPlayAll.
  ///
  /// In en, this message translates to:
  /// **'Play all'**
  String get aiDjPlayAll;

  /// No description provided for @aiDjEnqueueAll.
  ///
  /// In en, this message translates to:
  /// **'Add to queue'**
  String get aiDjEnqueueAll;

  /// No description provided for @aiDjInQueue.
  ///
  /// In en, this message translates to:
  /// **'In queue'**
  String get aiDjInQueue;

  /// No description provided for @aiDjItemActions.
  ///
  /// In en, this message translates to:
  /// **'Recommendation actions'**
  String get aiDjItemActions;

  /// No description provided for @aiDjReplaceItem.
  ///
  /// In en, this message translates to:
  /// **'Swap this one'**
  String get aiDjReplaceItem;

  /// No description provided for @aiDjNotInterested.
  ///
  /// In en, this message translates to:
  /// **'Not interested'**
  String get aiDjNotInterested;

  /// No description provided for @aiDjFeedbackTitle.
  ///
  /// In en, this message translates to:
  /// **'This round'**
  String get aiDjFeedbackTitle;

  /// No description provided for @aiDjFeedbackLiked.
  ///
  /// In en, this message translates to:
  /// **'Liked'**
  String get aiDjFeedbackLiked;

  /// No description provided for @aiDjFeedbackSkipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped'**
  String get aiDjFeedbackSkipped;

  /// No description provided for @aiDjUpstreamTitle.
  ///
  /// In en, this message translates to:
  /// **'Data sent this time'**
  String get aiDjUpstreamTitle;

  /// No description provided for @aiDjUpstreamBody.
  ///
  /// In en, this message translates to:
  /// **'Latest {events} play events · top {artists} artists · {exclusions} already-played excluded'**
  String aiDjUpstreamBody(int events, int artists, int exclusions);

  /// No description provided for @aiDjUpstreamHint.
  ///
  /// In en, this message translates to:
  /// **'Only the stats above plus titles/artists — no play URLs, no device info.'**
  String get aiDjUpstreamHint;

  /// No description provided for @aiDjCacheTtlTitle.
  ///
  /// In en, this message translates to:
  /// **'Recommendation cache'**
  String get aiDjCacheTtlTitle;

  /// No description provided for @aiDjCacheTtlDays.
  ///
  /// In en, this message translates to:
  /// **'{days} days'**
  String aiDjCacheTtlDays(int days);

  /// No description provided for @aiDjCacheTtlForever.
  ///
  /// In en, this message translates to:
  /// **'Forever'**
  String get aiDjCacheTtlForever;

  /// No description provided for @aiDjCacheTtlHint.
  ///
  /// In en, this message translates to:
  /// **'An expired list stops feeding the radio; the next extension generates a new batch (no interruption, no notice).'**
  String get aiDjCacheTtlHint;

  /// No description provided for @aiDjGenerate.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get aiDjGenerate;

  /// No description provided for @aiDjEmptyList.
  ///
  /// In en, this message translates to:
  /// **'No recommendations yet'**
  String get aiDjEmptyList;

  /// No description provided for @aiDjEmptyListHint.
  ///
  /// In en, this message translates to:
  /// **'Generate today\'s picks — playable any time.'**
  String get aiDjEmptyListHint;

  /// No description provided for @aiDjEnqueueEmpty.
  ///
  /// In en, this message translates to:
  /// **'Everything here is already queued'**
  String get aiDjEnqueueEmpty;

  /// No description provided for @settingsSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Cross-device sync'**
  String get settingsSyncTitle;

  /// No description provided for @settingsSyncItemSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Playlists, sources, settings and credentials'**
  String get settingsSyncItemSubtitle;

  /// No description provided for @syncGeneralSection.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get syncGeneralSection;

  /// No description provided for @syncTrustModelTitle.
  ///
  /// In en, this message translates to:
  /// **'Trust model'**
  String get syncTrustModelTitle;

  /// No description provided for @syncEnabledTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable sync'**
  String get syncEnabledTitle;

  /// No description provided for @syncEnabledSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Exchange data with devices that share your passphrase'**
  String get syncEnabledSubtitle;

  /// No description provided for @syncDeviceNameTitle.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get syncDeviceNameTitle;

  /// No description provided for @syncPassphraseTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync passphrase'**
  String get syncPassphraseTitle;

  /// No description provided for @syncPassphraseNotSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get syncPassphraseNotSet;

  /// No description provided for @syncPassphraseTrustHint.
  ///
  /// In en, this message translates to:
  /// **'Passphrase is the trust root; every holder is fully trusted. Reset it if leaked.'**
  String get syncPassphraseTrustHint;

  /// No description provided for @syncPassphraseCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy passphrase'**
  String get syncPassphraseCopy;

  /// No description provided for @syncPassphraseReset.
  ///
  /// In en, this message translates to:
  /// **'Reset passphrase'**
  String get syncPassphraseReset;

  /// No description provided for @syncPassphraseResetConfirm.
  ///
  /// In en, this message translates to:
  /// **'All devices must re-enter the new passphrase. Continue?'**
  String get syncPassphraseResetConfirm;

  /// No description provided for @syncPassphraseJoin.
  ///
  /// In en, this message translates to:
  /// **'Join with existing passphrase'**
  String get syncPassphraseJoin;

  /// No description provided for @syncPassphraseJoinTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter sync passphrase'**
  String get syncPassphraseJoinTitle;

  /// No description provided for @syncPassphraseJoinHint.
  ///
  /// In en, this message translates to:
  /// **'Enter the passphrase shown on another device'**
  String get syncPassphraseJoinHint;

  /// No description provided for @syncPassphraseInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid passphrase (at least 16 characters)'**
  String get syncPassphraseInvalid;

  /// No description provided for @syncSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get syncSave;

  /// No description provided for @syncSyncNow.
  ///
  /// In en, this message translates to:
  /// **'Sync now'**
  String get syncSyncNow;

  /// No description provided for @syncSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get syncSyncing;

  /// No description provided for @syncNever.
  ///
  /// In en, this message translates to:
  /// **'Never synced'**
  String get syncNever;

  /// No description provided for @syncLastResultOk.
  ///
  /// In en, this message translates to:
  /// **'Last sync {time} · {applied} applied'**
  String syncLastResultOk(String time, int applied);

  /// No description provided for @syncLastResultFail.
  ///
  /// In en, this message translates to:
  /// **'Last sync failed: {error}'**
  String syncLastResultFail(String error);

  /// No description provided for @syncContentSection.
  ///
  /// In en, this message translates to:
  /// **'What to sync'**
  String get syncContentSection;

  /// No description provided for @syncCategoryPlaylists.
  ///
  /// In en, this message translates to:
  /// **'Playlists & favorites'**
  String get syncCategoryPlaylists;

  /// No description provided for @syncCategorySources.
  ///
  /// In en, this message translates to:
  /// **'Sources (scripts & config)'**
  String get syncCategorySources;

  /// No description provided for @syncCategorySettings.
  ///
  /// In en, this message translates to:
  /// **'App settings'**
  String get syncCategorySettings;

  /// No description provided for @syncCategoryStatistics.
  ///
  /// In en, this message translates to:
  /// **'Play statistics'**
  String get syncCategoryStatistics;

  /// No description provided for @syncCategoryHistory.
  ///
  /// In en, this message translates to:
  /// **'Play history'**
  String get syncCategoryHistory;

  /// No description provided for @syncCategorySession.
  ///
  /// In en, this message translates to:
  /// **'Last playback session'**
  String get syncCategorySession;

  /// No description provided for @syncCategoryCredentials.
  ///
  /// In en, this message translates to:
  /// **'AI DJ & credentials'**
  String get syncCategoryCredentials;

  /// No description provided for @syncTransportSection.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get syncTransportSection;

  /// No description provided for @syncLanTitle.
  ///
  /// In en, this message translates to:
  /// **'LAN direct'**
  String get syncLanTitle;

  /// No description provided for @syncLanSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Device-to-device on the same Wi-Fi, no server'**
  String get syncLanSubtitle;

  /// No description provided for @syncWebdavTitle.
  ///
  /// In en, this message translates to:
  /// **'WebDAV / cloud'**
  String get syncWebdavTitle;

  /// No description provided for @syncWebdavSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sync across networks via your own WebDAV'**
  String get syncWebdavSubtitle;

  /// No description provided for @syncWebdavConfigTitle.
  ///
  /// In en, this message translates to:
  /// **'WebDAV settings'**
  String get syncWebdavConfigTitle;

  /// No description provided for @syncWebdavServer.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get syncWebdavServer;

  /// No description provided for @syncWebdavUsername.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get syncWebdavUsername;

  /// No description provided for @syncWebdavPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get syncWebdavPassword;

  /// No description provided for @syncWebdavRemoteDir.
  ///
  /// In en, this message translates to:
  /// **'Remote directory'**
  String get syncWebdavRemoteDir;

  /// No description provided for @syncWebdavNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get syncWebdavNotConfigured;

  /// No description provided for @syncLogSection.
  ///
  /// In en, this message translates to:
  /// **'Sync log'**
  String get syncLogSection;

  /// No description provided for @syncLogEmpty.
  ///
  /// In en, this message translates to:
  /// **'No records yet'**
  String get syncLogEmpty;

  /// No description provided for @syncLogApplied.
  ///
  /// In en, this message translates to:
  /// **'{applied} applied, {skipped} skipped'**
  String syncLogApplied(int applied, int skipped);

  /// No description provided for @syncLogFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String syncLogFailed(String error);

  /// No description provided for @syncDeviceNameDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get syncDeviceNameDialogTitle;

  /// No description provided for @syncRenameHint.
  ///
  /// In en, this message translates to:
  /// **'Shown on other devices'**
  String get syncRenameHint;

  /// No description provided for @syncDeviceNameEmpty.
  ///
  /// In en, this message translates to:
  /// **'Name cannot be empty'**
  String get syncDeviceNameEmpty;

  /// No description provided for @syncCategorySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Turning it off stops pushing and applying this data on this device'**
  String get syncCategorySubtitle;

  /// No description provided for @syncGeneratedHint.
  ///
  /// In en, this message translates to:
  /// **'Passphrase generated; enter it on other devices to join'**
  String get syncGeneratedHint;

  /// No description provided for @settingsUpdateTitle.
  ///
  /// In en, this message translates to:
  /// **'About & updates'**
  String get settingsUpdateTitle;

  /// No description provided for @settingsUpdateSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Current version {version}'**
  String settingsUpdateSubtitle(String version);

  /// No description provided for @settingsUpdateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Update available: {version}'**
  String settingsUpdateAvailable(String version);

  /// No description provided for @updateSettingsSection.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get updateSettingsSection;

  /// No description provided for @updateChannelTitle.
  ///
  /// In en, this message translates to:
  /// **'Update channel'**
  String get updateChannelTitle;

  /// No description provided for @updateChannelSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Stable gets releases only; Beta is early access'**
  String get updateChannelSubtitle;

  /// No description provided for @updateChannelStable.
  ///
  /// In en, this message translates to:
  /// **'Stable'**
  String get updateChannelStable;

  /// No description provided for @updateChannelBeta.
  ///
  /// In en, this message translates to:
  /// **'Beta'**
  String get updateChannelBeta;

  /// No description provided for @updateAutoCheckTitle.
  ///
  /// In en, this message translates to:
  /// **'Check for updates automatically'**
  String get updateAutoCheckTitle;

  /// No description provided for @updateAutoCheckSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Silent check at startup, at most once a day'**
  String get updateAutoCheckSubtitle;

  /// No description provided for @updateCheckTitle.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updateCheckTitle;

  /// No description provided for @updateStatusIdle.
  ///
  /// In en, this message translates to:
  /// **'Not checked yet'**
  String get updateStatusIdle;

  /// No description provided for @updateStatusChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get updateStatusChecking;

  /// No description provided for @updateStatusUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get updateStatusUpToDate;

  /// No description provided for @updateStatusAvailable.
  ///
  /// In en, this message translates to:
  /// **'New version {version} available'**
  String updateStatusAvailable(String version);

  /// No description provided for @updateStatusDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading…'**
  String get updateStatusDownloading;

  /// No description provided for @updateStatusDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Ready to install'**
  String get updateStatusDownloaded;

  /// No description provided for @updateStatusInstalling.
  ///
  /// In en, this message translates to:
  /// **'Installing…'**
  String get updateStatusInstalling;

  /// No description provided for @updateLastChecked.
  ///
  /// In en, this message translates to:
  /// **'Last checked {time}'**
  String updateLastChecked(String time);

  /// No description provided for @updateReleaseSection.
  ///
  /// In en, this message translates to:
  /// **'New version'**
  String get updateReleaseSection;

  /// No description provided for @updateReleaseTitle.
  ///
  /// In en, this message translates to:
  /// **'Molia {version}'**
  String updateReleaseTitle(String version);

  /// No description provided for @updateReleaseDate.
  ///
  /// In en, this message translates to:
  /// **'Released {date}'**
  String updateReleaseDate(String date);

  /// No description provided for @updateReleaseDateUnknown.
  ///
  /// In en, this message translates to:
  /// **'Release date unknown'**
  String get updateReleaseDateUnknown;

  /// No description provided for @updateCancelDownload.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get updateCancelDownload;

  /// No description provided for @updateInstallingHint.
  ///
  /// In en, this message translates to:
  /// **'Handed to the installer — follow the system prompts.'**
  String get updateInstallingHint;

  /// No description provided for @updateIosHint.
  ///
  /// In en, this message translates to:
  /// **'iOS updates come from the App Store; in-app install is not available.'**
  String get updateIosHint;

  /// No description provided for @updateReloadNow.
  ///
  /// In en, this message translates to:
  /// **'Reload now'**
  String get updateReloadNow;

  /// No description provided for @updateGrantInstallPermission.
  ///
  /// In en, this message translates to:
  /// **'Grant permission'**
  String get updateGrantInstallPermission;

  /// No description provided for @updateInstallNow.
  ///
  /// In en, this message translates to:
  /// **'Install now'**
  String get updateInstallNow;

  /// No description provided for @updateDownloadAndInstall.
  ///
  /// In en, this message translates to:
  /// **'Download and install'**
  String get updateDownloadAndInstall;

  /// No description provided for @updateOpenDownloadPage.
  ///
  /// In en, this message translates to:
  /// **'Open download page'**
  String get updateOpenDownloadPage;

  /// No description provided for @updateAdvancedSection.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get updateAdvancedSection;

  /// No description provided for @updateManifestOverrideTitle.
  ///
  /// In en, this message translates to:
  /// **'Manifest URL'**
  String get updateManifestOverrideTitle;

  /// No description provided for @updateManifestOverrideDefault.
  ///
  /// In en, this message translates to:
  /// **'Default (official GitHub release)'**
  String get updateManifestOverrideDefault;

  /// No description provided for @updateManifestOverrideHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to use the official URL'**
  String get updateManifestOverrideHint;

  /// No description provided for @updateDownloadPrefixTitle.
  ///
  /// In en, this message translates to:
  /// **'Download mirror prefix'**
  String get updateDownloadPrefixTitle;

  /// No description provided for @updateDownloadPrefixDefault.
  ///
  /// In en, this message translates to:
  /// **'Default (GitHub direct)'**
  String get updateDownloadPrefixDefault;

  /// No description provided for @updateDownloadPrefixHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. https://gh-proxy.com/ (verify unofficial mirrors yourself)'**
  String get updateDownloadPrefixHint;

  /// No description provided for @updateAboutSection.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get updateAboutSection;

  /// No description provided for @updateCurrentVersion.
  ///
  /// In en, this message translates to:
  /// **'Current version'**
  String get updateCurrentVersion;

  /// No description provided for @updatePlatformTitle.
  ///
  /// In en, this message translates to:
  /// **'Platform'**
  String get updatePlatformTitle;

  /// No description provided for @updateErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network error — update check failed'**
  String get updateErrorNetwork;

  /// No description provided for @updateErrorManifest.
  ///
  /// In en, this message translates to:
  /// **'Invalid update manifest'**
  String get updateErrorManifest;

  /// No description provided for @updateErrorUnsupported.
  ///
  /// In en, this message translates to:
  /// **'In-app updates are not supported on this platform'**
  String get updateErrorUnsupported;

  /// No description provided for @updateErrorChecksum.
  ///
  /// In en, this message translates to:
  /// **'Package checksum mismatch; file deleted'**
  String get updateErrorChecksum;

  /// No description provided for @updateErrorPermission.
  ///
  /// In en, this message translates to:
  /// **'Allow \"Install unknown apps\" to install updates'**
  String get updateErrorPermission;

  /// No description provided for @updateErrorNotWritable.
  ///
  /// In en, this message translates to:
  /// **'Install directory is read-only; download and replace manually'**
  String get updateErrorNotWritable;

  /// No description provided for @updateErrorInstall.
  ///
  /// In en, this message translates to:
  /// **'Install failed'**
  String get updateErrorInstall;

  /// No description provided for @updateDownloadProgress.
  ///
  /// In en, this message translates to:
  /// **'Downloaded {percent}% ({receivedMb} MB, {speedMb} MB/s)'**
  String updateDownloadProgress(
      String percent, String receivedMb, String speedMb);

  /// No description provided for @trackInfoTabTitle.
  ///
  /// In en, this message translates to:
  /// **'Song info'**
  String get trackInfoTabTitle;

  /// No description provided for @trackInfoEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing playing'**
  String get trackInfoEmpty;

  /// No description provided for @trackInfoQuality.
  ///
  /// In en, this message translates to:
  /// **'Playing quality'**
  String get trackInfoQuality;

  /// No description provided for @trackInfoQualityAvailable.
  ///
  /// In en, this message translates to:
  /// **'Available qualities'**
  String get trackInfoQualityAvailable;

  /// No description provided for @trackInfoQualityUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get trackInfoQualityUnknown;

  /// No description provided for @trackInfoChannel.
  ///
  /// In en, this message translates to:
  /// **'Channel'**
  String get trackInfoChannel;

  /// No description provided for @trackInfoChannelUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown channel'**
  String get trackInfoChannelUnknown;

  /// No description provided for @trackInfoAlbum.
  ///
  /// In en, this message translates to:
  /// **'Album'**
  String get trackInfoAlbum;

  /// No description provided for @trackInfoArtist.
  ///
  /// In en, this message translates to:
  /// **'Artist'**
  String get trackInfoArtist;

  /// No description provided for @trackInfoDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get trackInfoDuration;

  /// No description provided for @trackInfoTrackId.
  ///
  /// In en, this message translates to:
  /// **'Track ID'**
  String get trackInfoTrackId;

  /// No description provided for @trackInfoIdCopied.
  ///
  /// In en, this message translates to:
  /// **'Track ID copied'**
  String get trackInfoIdCopied;

  /// No description provided for @localDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Local data'**
  String get localDataTitle;

  /// No description provided for @trackInfoCacheResolve.
  ///
  /// In en, this message translates to:
  /// **'Resolved link cache'**
  String get trackInfoCacheResolve;

  /// No description provided for @trackInfoCacheNone.
  ///
  /// In en, this message translates to:
  /// **'Not cached'**
  String get trackInfoCacheNone;

  /// No description provided for @trackInfoCacheEntries.
  ///
  /// In en, this message translates to:
  /// **'{count} entries'**
  String trackInfoCacheEntries(int count);

  /// No description provided for @trackInfoCacheCleared.
  ///
  /// In en, this message translates to:
  /// **'Cleared {size}'**
  String trackInfoCacheCleared(String size);

  /// No description provided for @trackInfoCachePlaying.
  ///
  /// In en, this message translates to:
  /// **'Playing — audio cache can be cleared later'**
  String get trackInfoCachePlaying;

  /// No description provided for @trackActionCommentsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Hot and latest comments'**
  String get trackActionCommentsSubtitle;

  /// No description provided for @trackActionSwapSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Find this track\'s audio or lyrics on another source'**
  String get trackActionSwapSubtitle;

  /// No description provided for @trackInfoSource.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get trackInfoSource;

  /// No description provided for @trackInfoLyricsSource.
  ///
  /// In en, this message translates to:
  /// **'Lyrics source'**
  String get trackInfoLyricsSource;

  /// No description provided for @trackInfoLyricsSourceNone.
  ///
  /// In en, this message translates to:
  /// **'No lyrics yet'**
  String get trackInfoLyricsSourceNone;

  /// No description provided for @trackInfoAlbumOpen.
  ///
  /// In en, this message translates to:
  /// **'View album'**
  String get trackInfoAlbumOpen;

  /// No description provided for @trackInfoArtistOpen.
  ///
  /// In en, this message translates to:
  /// **'View artist'**
  String get trackInfoArtistOpen;

  /// No description provided for @trackInfoSourceUnknownId.
  ///
  /// In en, this message translates to:
  /// **'Unknown track ID'**
  String get trackInfoSourceUnknownId;

  /// No description provided for @sharePlatformPage.
  ///
  /// In en, this message translates to:
  /// **'Share platform page'**
  String get sharePlatformPage;

  /// No description provided for @openPlatformPage.
  ///
  /// In en, this message translates to:
  /// **'Open platform page'**
  String get openPlatformPage;

  /// No description provided for @shareTrackFile.
  ///
  /// In en, this message translates to:
  /// **'Share song file'**
  String get shareTrackFile;

  /// No description provided for @downloadAndShare.
  ///
  /// In en, this message translates to:
  /// **'Download & share'**
  String get downloadAndShare;

  /// No description provided for @platformPageUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This source has no platform page'**
  String get platformPageUnavailable;

  /// No description provided for @shareDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading — sharing when done'**
  String get shareDownloading;

  /// No description provided for @localDataCacheSection.
  ///
  /// In en, this message translates to:
  /// **'Cache usage'**
  String get localDataCacheSection;

  /// No description provided for @localDataStateCached.
  ///
  /// In en, this message translates to:
  /// **'Cached'**
  String get localDataStateCached;

  /// No description provided for @localDataOfflineAvailable.
  ///
  /// In en, this message translates to:
  /// **'Available offline'**
  String get localDataOfflineAvailable;

  /// No description provided for @localDataTransferToFolder.
  ///
  /// In en, this message translates to:
  /// **'Save a copy to folder'**
  String get localDataTransferToFolder;

  /// No description provided for @localDataTransferHint.
  ///
  /// In en, this message translates to:
  /// **'Cached · transfers without network'**
  String get localDataTransferHint;

  /// No description provided for @localDataAudioPlatformHint.
  ///
  /// In en, this message translates to:
  /// **'Playback caching is off here; a cache copy is written in the background'**
  String get localDataAudioPlatformHint;

  /// No description provided for @trackCacheClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get trackCacheClearAll;

  /// No description provided for @trackCacheClearConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear \"{part}\"?'**
  String trackCacheClearConfirm(String part);

  /// No description provided for @trackCacheClearAllConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear all cached data for this track?'**
  String get trackCacheClearAllConfirm;

  /// No description provided for @trackCacheClearHint.
  ///
  /// In en, this message translates to:
  /// **'Only cached copies are removed; downloads and playback are unaffected.'**
  String get trackCacheClearHint;

  /// No description provided for @cacheClearPart.
  ///
  /// In en, this message translates to:
  /// **'Clear \"{part}\"?'**
  String cacheClearPart(String part);

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @trackCacheEmpty.
  ///
  /// In en, this message translates to:
  /// **'Nothing cached for this track'**
  String get trackCacheEmpty;

  /// No description provided for @trackCacheAudioWriting.
  ///
  /// In en, this message translates to:
  /// **'Audio writing {size}'**
  String trackCacheAudioWriting(String size);

  /// No description provided for @cacheAudioPlatformUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Audio caching isn\'t available on this platform'**
  String get cacheAudioPlatformUnsupported;

  /// No description provided for @cacheAudioDisabled.
  ///
  /// In en, this message translates to:
  /// **'Audio caching is off'**
  String get cacheAudioDisabled;

  /// No description provided for @downloadAudioSection.
  ///
  /// In en, this message translates to:
  /// **'Audio'**
  String get downloadAudioSection;

  /// No description provided for @downloadQualityLabel.
  ///
  /// In en, this message translates to:
  /// **'Quality'**
  String get downloadQualityLabel;

  /// No description provided for @downloadQualityCached.
  ///
  /// In en, this message translates to:
  /// **'Cached'**
  String get downloadQualityCached;

  /// No description provided for @downloadExtrasSection.
  ///
  /// In en, this message translates to:
  /// **'Extras'**
  String get downloadExtrasSection;

  /// No description provided for @downloadCoverPart.
  ///
  /// In en, this message translates to:
  /// **'Cover'**
  String get downloadCoverPart;

  /// No description provided for @downloadPartDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get downloadPartDownload;

  /// No description provided for @downloadPartRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get downloadPartRemove;

  /// No description provided for @downloadAll.
  ///
  /// In en, this message translates to:
  /// **'Download all'**
  String get downloadAll;

  /// No description provided for @downloadFromCache.
  ///
  /// In en, this message translates to:
  /// **'Using local cache'**
  String get downloadFromCache;

  /// No description provided for @downloadLyricsDone.
  ///
  /// In en, this message translates to:
  /// **'Lyrics downloaded'**
  String get downloadLyricsDone;

  /// No description provided for @downloadCoverDone.
  ///
  /// In en, this message translates to:
  /// **'Cover downloaded'**
  String get downloadCoverDone;

  /// No description provided for @downloadNoArtwork.
  ///
  /// In en, this message translates to:
  /// **'No cover for this track'**
  String get downloadNoArtwork;

  /// No description provided for @downloadNoLyrics.
  ///
  /// In en, this message translates to:
  /// **'No lyrics found'**
  String get downloadNoLyrics;

  /// No description provided for @downloadSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Download settings'**
  String get downloadSettingsTitle;

  /// No description provided for @downloadSettingsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Save location, file names and tag embedding'**
  String get downloadSettingsSubtitle;

  /// No description provided for @downloadSaveLocation.
  ///
  /// In en, this message translates to:
  /// **'Save location'**
  String get downloadSaveLocation;

  /// No description provided for @downloadSaveLocationDefault.
  ///
  /// In en, this message translates to:
  /// **'Default (system Downloads)'**
  String get downloadSaveLocationDefault;

  /// No description provided for @downloadSaveLocationFixedHint.
  ///
  /// In en, this message translates to:
  /// **'Fixed to the app folder on this platform; files are visible in the Files app'**
  String get downloadSaveLocationFixedHint;

  /// No description provided for @downloadPickDirectory.
  ///
  /// In en, this message translates to:
  /// **'Choose folder'**
  String get downloadPickDirectory;

  /// No description provided for @downloadFilenameTemplate.
  ///
  /// In en, this message translates to:
  /// **'File name format'**
  String get downloadFilenameTemplate;

  /// No description provided for @downloadFilenameTemplateHint.
  ///
  /// In en, this message translates to:
  /// **'Variables: artist / title / album'**
  String get downloadFilenameTemplateHint;

  /// No description provided for @downloadFilenamePreview.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get downloadFilenamePreview;

  /// No description provided for @downloadReset.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get downloadReset;

  /// No description provided for @downloadEmbedTags.
  ///
  /// In en, this message translates to:
  /// **'Embed lyrics & cover tags'**
  String get downloadEmbedTags;

  /// No description provided for @downloadEmbedTagsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Write tags into the audio file (MP3 / FLAC) so other players can read them; sidecar files remain when writing fails'**
  String get downloadEmbedTagsSubtitle;

  /// No description provided for @downloadPublishToPublicDir.
  ///
  /// In en, this message translates to:
  /// **'Publish to system Downloads'**
  String get downloadPublishToPublicDir;

  /// No description provided for @downloadPublishToPublicDirSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Also copy finished downloads into the system Downloads folder (Android public storage) so file managers and other players can see them; playback still uses the in-app copy'**
  String get downloadPublishToPublicDirSubtitle;

  /// No description provided for @downloadLocationInfo.
  ///
  /// In en, this message translates to:
  /// **'Download folder'**
  String get downloadLocationInfo;

  /// No description provided for @downloadLocationUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Downloading is not supported on this platform'**
  String get downloadLocationUnsupported;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @lyricsEmptyState.
  ///
  /// In en, this message translates to:
  /// **'No lyrics for this one yet — try another source? (´･ω･`)'**
  String get lyricsEmptyState;

  /// No description provided for @lyricsDisplaySettingsAction.
  ///
  /// In en, this message translates to:
  /// **'Lyrics display settings'**
  String get lyricsDisplaySettingsAction;

  /// No description provided for @lyricsSwapAction.
  ///
  /// In en, this message translates to:
  /// **'Change lyrics'**
  String get lyricsSwapAction;

  /// No description provided for @lyricsCopyModeAction.
  ///
  /// In en, this message translates to:
  /// **'Copy lyrics mode'**
  String get lyricsCopyModeAction;

  /// No description provided for @lyricsCopyModeExit.
  ///
  /// In en, this message translates to:
  /// **'Exit copy mode'**
  String get lyricsCopyModeExit;

  /// No description provided for @commentsTitle.
  ///
  /// In en, this message translates to:
  /// **'Comments'**
  String get commentsTitle;

  /// No description provided for @commentsTabHot.
  ///
  /// In en, this message translates to:
  /// **'Hot'**
  String get commentsTabHot;

  /// No description provided for @commentsTabHotCount.
  ///
  /// In en, this message translates to:
  /// **'Hot ({count})'**
  String commentsTabHotCount(int count);

  /// No description provided for @commentsTabLatest.
  ///
  /// In en, this message translates to:
  /// **'Latest'**
  String get commentsTabLatest;

  /// No description provided for @commentsTabLatestCount.
  ///
  /// In en, this message translates to:
  /// **'Latest ({count})'**
  String commentsTabLatestCount(int count);

  /// No description provided for @commentsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No comments yet'**
  String get commentsEmpty;

  /// No description provided for @commentsUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Comments are not available for this channel'**
  String get commentsUnsupported;

  /// No description provided for @commentsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load comments'**
  String get commentsLoadFailed;

  /// No description provided for @commentsLoadMoreFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load more comments'**
  String get commentsLoadMoreFailed;

  /// No description provided for @commentsNoMore.
  ///
  /// In en, this message translates to:
  /// **'No more comments'**
  String get commentsNoMore;

  /// No description provided for @commentsRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh comments'**
  String get commentsRefresh;

  /// No description provided for @commentsIpLocation.
  ///
  /// In en, this message translates to:
  /// **'IP: {location}'**
  String commentsIpLocation(String location);

  /// No description provided for @commentsQuotedAuthor.
  ///
  /// In en, this message translates to:
  /// **'{name}: '**
  String commentsQuotedAuthor(String name);

  /// No description provided for @commentsLikedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} likes'**
  String commentsLikedCount(int count);

  /// No description provided for @commentsTimeJustNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get commentsTimeJustNow;

  /// No description provided for @commentsTimeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String commentsTimeMinutesAgo(int count);

  /// No description provided for @commentsTimeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count} h ago'**
  String commentsTimeHoursAgo(int count);

  /// No description provided for @downloadStatusNotDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Not downloaded'**
  String get downloadStatusNotDownloaded;

  /// No description provided for @downloadStatusDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading'**
  String get downloadStatusDownloading;

  /// No description provided for @downloadStatusDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded'**
  String get downloadStatusDownloaded;

  /// No description provided for @downloadAction.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get downloadAction;

  /// No description provided for @downloadCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel download'**
  String get downloadCancel;

  /// No description provided for @downloadDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete download'**
  String get downloadDelete;

  /// No description provided for @downloadDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the local copy? Audio, lyrics and cover files will be removed.'**
  String get downloadDeleteConfirm;

  /// No description provided for @downloadDeleteConfirmMixed.
  ///
  /// In en, this message translates to:
  /// **'Delete the local copies? Audio, lyrics and cover files will be removed; imported local tracks are only removed from the list.'**
  String get downloadDeleteConfirmMixed;

  /// No description provided for @localSongsCachedTag.
  ///
  /// In en, this message translates to:
  /// **'Cached'**
  String get localSongsCachedTag;

  /// No description provided for @localSongsCachedRemove.
  ///
  /// In en, this message translates to:
  /// **'Clear cache'**
  String get localSongsCachedRemove;

  /// No description provided for @localSongsCachedRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Clear this track\'s audio cache? Only the cached copy is removed; downloads and imported files are unaffected.'**
  String get localSongsCachedRemoveConfirm;

  /// No description provided for @localSongsMixedRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove the selected items? Downloads delete files, imported items are only removed from the list, cached copies are cleared.'**
  String get localSongsMixedRemoveConfirm;

  /// No description provided for @downloadShare.
  ///
  /// In en, this message translates to:
  /// **'Share / export'**
  String get downloadShare;

  /// No description provided for @downloadProgressPercent.
  ///
  /// In en, this message translates to:
  /// **'{percent}%'**
  String downloadProgressPercent(int percent);

  /// No description provided for @downloadCompleted.
  ///
  /// In en, this message translates to:
  /// **'Download complete'**
  String get downloadCompleted;

  /// No description provided for @downloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed: {message}'**
  String downloadFailed(String message);

  /// No description provided for @downloadUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Downloads are not supported on this platform'**
  String get downloadUnsupported;

  /// No description provided for @downloadAlreadyExists.
  ///
  /// In en, this message translates to:
  /// **'This track is already downloaded'**
  String get downloadAlreadyExists;

  /// No description provided for @downloadCancelled.
  ///
  /// In en, this message translates to:
  /// **'Download cancelled'**
  String get downloadCancelled;

  /// No description provided for @downloadDataSaverTitle.
  ///
  /// In en, this message translates to:
  /// **'Data saver is active'**
  String get downloadDataSaverTitle;

  /// No description provided for @downloadDataSaverConfirm.
  ///
  /// In en, this message translates to:
  /// **'You are on mobile data with data saver enabled. Downloading will use mobile data. Continue?'**
  String get downloadDataSaverConfirm;

  /// No description provided for @downloadContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get downloadContinue;

  /// No description provided for @downloadFileMissing.
  ///
  /// In en, this message translates to:
  /// **'The local file is missing and may have been deleted'**
  String get downloadFileMissing;

  /// No description provided for @downloadSourceLocal.
  ///
  /// In en, this message translates to:
  /// **'Local download'**
  String get downloadSourceLocal;

  /// No description provided for @downloadsManageTitle.
  ///
  /// In en, this message translates to:
  /// **'Downloads'**
  String get downloadsManageTitle;

  /// No description provided for @downloadsManageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Task queue, batch download and file maintenance'**
  String get downloadsManageSubtitle;

  /// No description provided for @downloadsActiveSection.
  ///
  /// In en, this message translates to:
  /// **'In progress'**
  String get downloadsActiveSection;

  /// No description provided for @downloadsActiveEmpty.
  ///
  /// In en, this message translates to:
  /// **'No downloads in progress'**
  String get downloadsActiveEmpty;

  /// No description provided for @downloadsActiveCount.
  ///
  /// In en, this message translates to:
  /// **'{count} task(s)'**
  String downloadsActiveCount(int count);

  /// No description provided for @downloadsBatchSection.
  ///
  /// In en, this message translates to:
  /// **'Batch download'**
  String get downloadsBatchSection;

  /// No description provided for @downloadsBatchQueue.
  ///
  /// In en, this message translates to:
  /// **'Download current queue'**
  String get downloadsBatchQueue;

  /// No description provided for @downloadsBatchQueueSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{count} track(s); skips downloaded and local tracks'**
  String downloadsBatchQueueSubtitle(int count);

  /// No description provided for @downloadsBatchStarted.
  ///
  /// In en, this message translates to:
  /// **'Batch download started ({count})'**
  String downloadsBatchStarted(int count);

  /// No description provided for @downloadsBatchDone.
  ///
  /// In en, this message translates to:
  /// **'Batch finished: {done} succeeded, {failed} failed'**
  String downloadsBatchDone(int done, int failed);

  /// No description provided for @downloadsMaintenanceSection.
  ///
  /// In en, this message translates to:
  /// **'File maintenance'**
  String get downloadsMaintenanceSection;

  /// No description provided for @downloadsCleanupParts.
  ///
  /// In en, this message translates to:
  /// **'Remove unfinished downloads'**
  String get downloadsCleanupParts;

  /// No description provided for @downloadsCleanupPartsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Leftover .part files from crashes; finished downloads are untouched'**
  String get downloadsCleanupPartsSubtitle;

  /// No description provided for @downloadsCleanupPartsDone.
  ///
  /// In en, this message translates to:
  /// **'Removed {count} unfinished file(s)'**
  String downloadsCleanupPartsDone(int count);

  /// No description provided for @downloadsCleanupOrphans.
  ///
  /// In en, this message translates to:
  /// **'Remove orphan files'**
  String get downloadsCleanupOrphans;

  /// No description provided for @downloadsCleanupOrphansSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Delete files in the download folder that no record references'**
  String get downloadsCleanupOrphansSubtitle;

  /// No description provided for @downloadsCleanupOrphansDone.
  ///
  /// In en, this message translates to:
  /// **'Removed {count} orphan file(s)'**
  String downloadsCleanupOrphansDone(int count);

  /// No description provided for @downloadsBatchPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Download a playlist'**
  String get downloadsBatchPlaylist;

  /// No description provided for @downloadsBatchPlaylistSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pick a playlist and download it in batch (skips downloaded and local tracks)'**
  String get downloadsBatchPlaylistSubtitle;

  /// No description provided for @downloadsPickPlaylist.
  ///
  /// In en, this message translates to:
  /// **'Choose a playlist'**
  String get downloadsPickPlaylist;

  /// No description provided for @downloadsMigrateLegacy.
  ///
  /// In en, this message translates to:
  /// **'Move downloads to the new location'**
  String get downloadsMigrateLegacy;

  /// No description provided for @downloadsMigrateLegacySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Move files from the legacy app folder into the current download folder'**
  String get downloadsMigrateLegacySubtitle;

  /// No description provided for @downloadsMigrateLegacyDone.
  ///
  /// In en, this message translates to:
  /// **'Moved {moved}, failed {failed}'**
  String downloadsMigrateLegacyDone(int moved, int failed);

  /// No description provided for @downloadsPublishPublic.
  ///
  /// In en, this message translates to:
  /// **'Publish to system Downloads'**
  String get downloadsPublishPublic;

  /// No description provided for @downloadsPublishPublicSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Copy downloads that have no public copy yet into the system Downloads folder (Android)'**
  String get downloadsPublishPublicSubtitle;

  /// No description provided for @downloadsPublishPublicDone.
  ///
  /// In en, this message translates to:
  /// **'{published} published, {failed} failed'**
  String downloadsPublishPublicDone(int published, int failed);

  /// No description provided for @downloadsNoResume.
  ///
  /// In en, this message translates to:
  /// **'No resume support: platform links are usually one-time signed URLs; re-downloading is more reliable'**
  String get downloadsNoResume;

  /// No description provided for @downloadsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No downloaded tracks yet'**
  String get downloadsEmpty;

  /// No description provided for @sleepTimerTitle.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer'**
  String get sleepTimerTitle;

  /// No description provided for @sleepTimerHint.
  ///
  /// In en, this message translates to:
  /// **'Pauses playback when the timer ends'**
  String get sleepTimerHint;

  /// No description provided for @sleepTimerCountdownSection.
  ///
  /// In en, this message translates to:
  /// **'Countdown'**
  String get sleepTimerCountdownSection;

  /// No description provided for @sleepTimerOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get sleepTimerOff;

  /// No description provided for @sleepTimerRemaining.
  ///
  /// In en, this message translates to:
  /// **'{time} left'**
  String sleepTimerRemaining(String time);

  /// No description provided for @sleepTimerAfterTrack.
  ///
  /// In en, this message translates to:
  /// **'Pause after current track'**
  String get sleepTimerAfterTrack;

  /// No description provided for @sleepTimerMinutesShort.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String sleepTimerMinutesShort(int minutes);

  /// No description provided for @sleepTimerCancel.
  ///
  /// In en, this message translates to:
  /// **'Turn off timer'**
  String get sleepTimerCancel;

  /// No description provided for @sleepTimerArmedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer on · pausing in {time}'**
  String sleepTimerArmedSnackbar(String time);

  /// No description provided for @sleepTimerArmedAfterTrack.
  ///
  /// In en, this message translates to:
  /// **'Sleep timer on · pausing after this track'**
  String get sleepTimerArmedAfterTrack;

  /// No description provided for @sleepTimerHourLabel.
  ///
  /// In en, this message translates to:
  /// **'Hours'**
  String get sleepTimerHourLabel;

  /// No description provided for @sleepTimerMinuteLabel.
  ///
  /// In en, this message translates to:
  /// **'Minutes'**
  String get sleepTimerMinuteLabel;

  /// No description provided for @sleepTimerCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom duration…'**
  String get sleepTimerCustom;

  /// No description provided for @sleepTimerCustomTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom duration'**
  String get sleepTimerCustomTitle;

  /// No description provided for @sleepTimerCustomInvalid.
  ///
  /// In en, this message translates to:
  /// **'Duration must be between 1 minute and 10 hours'**
  String get sleepTimerCustomInvalid;

  /// No description provided for @sleepTimerCustomConfirm.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get sleepTimerCustomConfirm;

  /// No description provided for @trayShowWindow.
  ///
  /// In en, this message translates to:
  /// **'Show window'**
  String get trayShowWindow;

  /// No description provided for @trayPrevious.
  ///
  /// In en, this message translates to:
  /// **'Previous track'**
  String get trayPrevious;

  /// No description provided for @trayNext.
  ///
  /// In en, this message translates to:
  /// **'Next track'**
  String get trayNext;

  /// No description provided for @trayQuit.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get trayQuit;

  /// No description provided for @settingsDesktopSection.
  ///
  /// In en, this message translates to:
  /// **'Desktop'**
  String get settingsDesktopSection;

  /// No description provided for @settingsCloseToTray.
  ///
  /// In en, this message translates to:
  /// **'Minimize to tray on close'**
  String get settingsCloseToTray;

  /// No description provided for @settingsCloseToTraySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keep playing in the background; reopen or quit from the tray icon'**
  String get settingsCloseToTraySubtitle;

  /// No description provided for @settingsTrayLinuxHint.
  ///
  /// In en, this message translates to:
  /// **'The tray icon needs a system tray host; GNOME requires the AppIndicator extension. Without one, closing quits'**
  String get settingsTrayLinuxHint;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
