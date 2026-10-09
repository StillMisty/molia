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
  /// **'Copy Lyrics Mode: Single repeat active, auto-scroll disabled.'**
  String get lyricsCopyModeSnackbar;

  /// No description provided for @centerCurrentLine.
  ///
  /// In en, this message translates to:
  /// **'Center Current Line'**
  String get centerCurrentLine;

  /// No description provided for @exitCopyModeResumeScroll.
  ///
  /// In en, this message translates to:
  /// **'Exit Copy Mode & Resume Scroll'**
  String get exitCopyModeResumeScroll;

  /// No description provided for @enterCopyLyricsMode.
  ///
  /// In en, this message translates to:
  /// **'Enter Copy Lyrics Mode (Single Repeat)'**
  String get enterCopyLyricsMode;

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
  /// **'System default'**
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

  /// No description provided for @settingsDynamicColor.
  ///
  /// In en, this message translates to:
  /// **'Dynamic color'**
  String get settingsDynamicColor;

  /// No description provided for @settingsDynamicColorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Derive theme colors from album art'**
  String get settingsDynamicColorSubtitle;

  /// No description provided for @settingsMonetColor.
  ///
  /// In en, this message translates to:
  /// **'Monet color'**
  String get settingsMonetColor;

  /// No description provided for @settingsMonetColorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use wallpaper colors provided by the system (Android 12+)'**
  String get settingsMonetColorSubtitle;

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
  /// **'Theme color'**
  String get settingsSeedColor;

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

  /// No description provided for @settingsCurrentQuality.
  ///
  /// In en, this message translates to:
  /// **'Now playing quality'**
  String get settingsCurrentQuality;

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

  /// No description provided for @settingsSourcesSection.
  ///
  /// In en, this message translates to:
  /// **'Sources'**
  String get settingsSourcesSection;

  /// No description provided for @settingsSourcesItemSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Import LX Music source scripts to search and play songs from third-party platforms'**
  String get settingsSourcesItemSubtitle;

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

  /// No description provided for @copyLyricsAsSingleLineTitle.
  ///
  /// In en, this message translates to:
  /// **'Copy lyrics as single line'**
  String get copyLyricsAsSingleLineTitle;

  /// No description provided for @copyLyricsAsSingleLineSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Replaces line breaks with spaces when copying'**
  String get copyLyricsAsSingleLineSubtitle;

  /// No description provided for @dataManagementTitle.
  ///
  /// In en, this message translates to:
  /// **'Data Management'**
  String get dataManagementTitle;

  /// No description provided for @exportDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Export Recent Plays'**
  String get exportDataTitle;

  /// No description provided for @exportDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Export recent play history as a JSON file'**
  String get exportDataSubtitle;

  /// No description provided for @importDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Import Recent Plays'**
  String get importDataTitle;

  /// No description provided for @importDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Import recent play history from an exported JSON file'**
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

  /// No description provided for @languageDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Select Language'**
  String get languageDialogTitle;

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

  /// No description provided for @failedToChangeLanguage.
  ///
  /// In en, this message translates to:
  /// **'Failed to change language: {error}'**
  String failedToChangeLanguage(String error);

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
  /// **'Select lyrics fragments for analysis or sharing'**
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
  /// **'Generating analysis...'**
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

  /// No description provided for @sourcesTitle.
  ///
  /// In en, this message translates to:
  /// **'Source Management'**
  String get sourcesTitle;

  /// No description provided for @anyListenEntry.
  ///
  /// In en, this message translates to:
  /// **'any-listen'**
  String get anyListenEntry;

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
  /// **'This quality is preferred when resolving a track URL, with automatic fallback when unavailable.'**
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

  /// No description provided for @sourcesMoveUp.
  ///
  /// In en, this message translates to:
  /// **'Move up'**
  String get sourcesMoveUp;

  /// No description provided for @sourcesMoveDown.
  ///
  /// In en, this message translates to:
  /// **'Move down'**
  String get sourcesMoveDown;

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

  /// No description provided for @settingsLyricsDisplayTitle.
  ///
  /// In en, this message translates to:
  /// **'Lyrics display'**
  String get settingsLyricsDisplayTitle;

  /// No description provided for @settingsLyricsDisplaySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Floating lyrics, notification & Bluetooth'**
  String get settingsLyricsDisplaySubtitle;

  /// No description provided for @lyricsDisplaySharedTitle.
  ///
  /// In en, this message translates to:
  /// **'Shared'**
  String get lyricsDisplaySharedTitle;

  /// No description provided for @lyricsDisplayTranslation.
  ///
  /// In en, this message translates to:
  /// **'Translation'**
  String get lyricsDisplayTranslation;

  /// No description provided for @lyricsDisplayTranslationSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show translation under the current line'**
  String get lyricsDisplayTranslationSubtitle;

  /// No description provided for @lyricsDisplayRoma.
  ///
  /// In en, this message translates to:
  /// **'Romanization'**
  String get lyricsDisplayRoma;

  /// No description provided for @lyricsDisplayRomaSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show romanized lyrics under the current line'**
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

  /// No description provided for @lyricsDesktopSingleLine.
  ///
  /// In en, this message translates to:
  /// **'Current line only'**
  String get lyricsDesktopSingleLine;

  /// No description provided for @lyricsDesktopAlign.
  ///
  /// In en, this message translates to:
  /// **'Text align'**
  String get lyricsDesktopAlign;

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

  /// No description provided for @lyricsDesktopControls.
  ///
  /// In en, this message translates to:
  /// **'Control bar buttons'**
  String get lyricsDesktopControls;

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
  /// **'Uses the media notification subtitle (no modules needed)'**
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

  /// No description provided for @lyricsDisplayUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Lyric outputs are not available on this platform'**
  String get lyricsDisplayUnsupported;
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
