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
    Locale('zh'),
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

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

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

  /// No description provided for @searchClose.
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get searchClose;

  /// No description provided for @searchResultsAnnouncement.
  ///
  /// In en, this message translates to:
  /// **'{count} results available'**
  String searchResultsAnnouncement(int count);

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
  /// **'Copy mode: single repeat is on and auto-follow is paused; your settings return when you exit.'**
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

  /// No description provided for @settingsBaseColorWallpaperActive.
  ///
  /// In en, this message translates to:
  /// **'Source: system wallpaper'**
  String get settingsBaseColorWallpaperActive;

  /// No description provided for @settingsBaseColorAccentActive.
  ///
  /// In en, this message translates to:
  /// **'Source: system theme color'**
  String get settingsBaseColorAccentActive;

  /// No description provided for @settingsPureBlack.
  ///
  /// In en, this message translates to:
  /// **'Pure black background'**
  String get settingsPureBlack;

  /// No description provided for @settingsPureBlackSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Pure black background in dark mode — saves power on OLED'**
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
  /// **'Pick colors from the current song’s artwork; base colors when there is none'**
  String get settingsFollowArtworkSubtitle;

  /// No description provided for @coverTitle.
  ///
  /// In en, this message translates to:
  /// **'Song cover'**
  String get coverTitle;

  /// No description provided for @coverFollowSong.
  ///
  /// In en, this message translates to:
  /// **'Song artwork'**
  String get coverFollowSong;

  /// No description provided for @coverCustomized.
  ///
  /// In en, this message translates to:
  /// **'Customized'**
  String get coverCustomized;

  /// No description provided for @coverChooseImage.
  ///
  /// In en, this message translates to:
  /// **'Choose image'**
  String get coverChooseImage;

  /// No description provided for @coverChangeImage.
  ///
  /// In en, this message translates to:
  /// **'Change image'**
  String get coverChangeImage;

  /// No description provided for @coverResetSong.
  ///
  /// In en, this message translates to:
  /// **'Restore song artwork'**
  String get coverResetSong;

  /// No description provided for @coverResetToDefault.
  ///
  /// In en, this message translates to:
  /// **'Use default cover'**
  String get coverResetToDefault;

  /// No description provided for @coverRestored.
  ///
  /// In en, this message translates to:
  /// **'Cover restored'**
  String get coverRestored;

  /// No description provided for @coverDefaultRestored.
  ///
  /// In en, this message translates to:
  /// **'Molia mark restored'**
  String get coverDefaultRestored;

  /// No description provided for @coverUpdated.
  ///
  /// In en, this message translates to:
  /// **'Cover updated'**
  String get coverUpdated;

  /// No description provided for @coverUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t update the cover. Try again'**
  String get coverUpdateFailed;

  /// No description provided for @coverUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t read this image. Choose another'**
  String get coverUnreadable;

  /// No description provided for @coverDefaultTitle.
  ///
  /// In en, this message translates to:
  /// **'Default cover'**
  String get coverDefaultTitle;

  /// No description provided for @coverDefaultSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Shown when a song has no artwork'**
  String get coverDefaultSubtitle;

  /// No description provided for @coverResetDefault.
  ///
  /// In en, this message translates to:
  /// **'Restore the Molia mark'**
  String get coverResetDefault;

  /// No description provided for @coverDefaultUpdated.
  ///
  /// In en, this message translates to:
  /// **'Default cover updated'**
  String get coverDefaultUpdated;

  /// No description provided for @settingsSyncCustomCovers.
  ///
  /// In en, this message translates to:
  /// **'Sync custom covers'**
  String get settingsSyncCustomCovers;

  /// No description provided for @settingsSyncCustomCoversSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sends cover images to your other devices'**
  String get settingsSyncCustomCoversSubtitle;

  /// No description provided for @coverLabel.
  ///
  /// In en, this message translates to:
  /// **'Cover'**
  String get coverLabel;

  /// No description provided for @coverViewOriginal.
  ///
  /// In en, this message translates to:
  /// **'View original'**
  String get coverViewOriginal;

  /// No description provided for @coverSaveOriginal.
  ///
  /// In en, this message translates to:
  /// **'Save original'**
  String get coverSaveOriginal;

  /// No description provided for @coverLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t load the cover. Try again'**
  String get coverLoadFailed;

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
  /// **'No available fonts found'**
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
  /// **'Used the next time playback starts; current playback is unaffected'**
  String get settingsDefaultPlayModeSubtitle;

  /// No description provided for @settingsRestoreSessionTitle.
  ///
  /// In en, this message translates to:
  /// **'Resume last playback'**
  String get settingsRestoreSessionTitle;

  /// No description provided for @settingsRestoreSessionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Remembers track, queue and position'**
  String get settingsRestoreSessionSubtitle;

  /// No description provided for @settingsPlayWithOtherApps.
  ///
  /// In en, this message translates to:
  /// **'Play with other apps'**
  String get settingsPlayWithOtherApps;

  /// No description provided for @settingsPlayWithOtherAppsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Navigation and videos won\'t interrupt music'**
  String get settingsPlayWithOtherAppsSubtitle;

  /// No description provided for @settingsLibraryAddPosition.
  ///
  /// In en, this message translates to:
  /// **'Position of added songs'**
  String get settingsLibraryAddPosition;

  /// No description provided for @settingsLibraryAddPositionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Top or bottom of favorites and playlists'**
  String get settingsLibraryAddPositionSubtitle;

  /// No description provided for @settingsLibraryAddPositionTop.
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get settingsLibraryAddPositionTop;

  /// No description provided for @settingsLibraryAddPositionBottom.
  ///
  /// In en, this message translates to:
  /// **'Bottom'**
  String get settingsLibraryAddPositionBottom;

  /// No description provided for @settingsAutoSourceSwap.
  ///
  /// In en, this message translates to:
  /// **'Auto source switch'**
  String get settingsAutoSourceSwap;

  /// No description provided for @settingsAutoSourceSwapSubtitle.
  ///
  /// In en, this message translates to:
  /// **'On playback failure, look for the same song in another source'**
  String get settingsAutoSourceSwapSubtitle;

  /// No description provided for @settingsDataSaverTitle.
  ///
  /// In en, this message translates to:
  /// **'Data saver'**
  String get settingsDataSaverTitle;

  /// No description provided for @settingsDataSaverSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Lower audio quality and load fewer covers on mobile data'**
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
  /// **'Stop loading new artwork; show a placeholder when not cached'**
  String get settingsDataSaverCoversSubtitle;

  /// No description provided for @settingsSourcesItemSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Import LX Music source scripts to search more platforms'**
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

  /// No description provided for @settingsBottomNavKeepHome.
  ///
  /// In en, this message translates to:
  /// **'This page is the startup page — change “Startup page” first'**
  String get settingsBottomNavKeepHome;

  /// No description provided for @settingsStartupPageTitle.
  ///
  /// In en, this message translates to:
  /// **'Startup page'**
  String get settingsStartupPageTitle;

  /// No description provided for @settingsStartupPageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Page opened when the app starts'**
  String get settingsStartupPageSubtitle;

  /// No description provided for @settingsStartupPageHidden.
  ///
  /// In en, this message translates to:
  /// **'“{page}” is hidden; the app opens “{effective}” instead'**
  String settingsStartupPageHidden(String page, String effective);

  /// No description provided for @playModeListLoop.
  ///
  /// In en, this message translates to:
  /// **'Repeat all'**
  String get playModeListLoop;

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

  /// No description provided for @settingsHapticsTitle.
  ///
  /// In en, this message translates to:
  /// **'Vibration feedback'**
  String get settingsHapticsTitle;

  /// No description provided for @settingsHapticsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Light vibration on taps such as navigation and playback'**
  String get settingsHapticsSubtitle;

  /// No description provided for @settingsGeneralTitle.
  ///
  /// In en, this message translates to:
  /// **'General settings'**
  String get settingsGeneralTitle;

  /// No description provided for @settingsGeneralSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Language, app name and bottom navigation'**
  String get settingsGeneralSubtitle;

  /// No description provided for @settingsDataSection.
  ///
  /// In en, this message translates to:
  /// **'Data'**
  String get settingsDataSection;

  /// No description provided for @dataManagementTitle.
  ///
  /// In en, this message translates to:
  /// **'Data & storage'**
  String get dataManagementTitle;

  /// No description provided for @settingsDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Cache, downloads and data import/export'**
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
  /// **'Full backup: playlists, sources, settings, stats, history, sign-in info and keys (keep the file safe)'**
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
  /// **'Importing merges the backup with local data; matching entries are replaced by the backup. This cannot be undone.\n\nMake sure the file is a backup exported from Molia.'**
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

  /// No description provided for @savedToPath.
  ///
  /// In en, this message translates to:
  /// **'Saved to {path}'**
  String savedToPath(String path);

  /// No description provided for @savedToDownloads.
  ///
  /// In en, this message translates to:
  /// **'Saved to Downloads: {path}'**
  String savedToDownloads(String path);

  /// No description provided for @savedToFilesApp.
  ///
  /// In en, this message translates to:
  /// **'Saved to Files: {path}'**
  String savedToFilesApp(String path);

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save. Try again.'**
  String get saveFailed;

  /// No description provided for @fileInDownloads.
  ///
  /// In en, this message translates to:
  /// **'File is in Downloads: {path}'**
  String fileInDownloads(String path);

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

  /// No description provided for @lyricsPosterAction.
  ///
  /// In en, this message translates to:
  /// **'Lyrics poster'**
  String get lyricsPosterAction;

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
  /// **'Playing'**
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

  /// No description provided for @libraryLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load your library'**
  String get libraryLoadFailed;

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
  /// **'Playing'**
  String get nowPlayingSection;

  /// No description provided for @nowPlayingPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get nowPlayingPaused;

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
  /// **'any-listen is a self-hosted music service. Once enabled, its online sources appear in search.'**
  String get anyListenIntroBody;

  /// No description provided for @anyListenIntroHint.
  ///
  /// In en, this message translates to:
  /// **'This integration has not been tested against a real server and may not work yet.'**
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
  /// **'Address of your any-listen service'**
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
  /// **'Access password (optional)'**
  String get anyListenToken;

  /// No description provided for @anyListenTokenPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'After a successful test, paste the access password provided by the server'**
  String get anyListenTokenPlaceholder;

  /// No description provided for @anyListenTokenShow.
  ///
  /// In en, this message translates to:
  /// **'Show access password'**
  String get anyListenTokenShow;

  /// No description provided for @anyListenTokenHide.
  ///
  /// In en, this message translates to:
  /// **'Hide access password'**
  String get anyListenTokenHide;

  /// No description provided for @anyListenEnable.
  ///
  /// In en, this message translates to:
  /// **'Enable any-listen source'**
  String get anyListenEnable;

  /// No description provided for @anyListenEnableSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When off, it is hidden from search and makes no network requests'**
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
  /// **'Download a script from a link'**
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
  /// **'Play at this quality when available; fall back automatically otherwise'**
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
  /// **'Discover and search follow this order; new channels go to the end, and disabled channels disappear.'**
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

  /// No description provided for @sourcesScriptActions.
  ///
  /// In en, this message translates to:
  /// **'Source script actions'**
  String get sourcesScriptActions;

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
  /// **'Source scripts are executable code from third parties; once imported they run on this device and can access the network.\nOnly import scripts from trusted sources. Their availability and legality are the provider’s responsibility.'**
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
  /// **'Paste the full source script'**
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

  /// No description provided for @searchLoadMoreFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load more results'**
  String get searchLoadMoreFailed;

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
  /// **'Albums and playlists you listen to will show up here.'**
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

  /// No description provided for @tableColumnArtist.
  ///
  /// In en, this message translates to:
  /// **'Artist'**
  String get tableColumnArtist;

  /// No description provided for @tableColumnAlbum.
  ///
  /// In en, this message translates to:
  /// **'Album'**
  String get tableColumnAlbum;

  /// No description provided for @tableColumnPlayedAt.
  ///
  /// In en, this message translates to:
  /// **'Played at'**
  String get tableColumnPlayedAt;

  /// No description provided for @tableColumnDuration.
  ///
  /// In en, this message translates to:
  /// **'Duration'**
  String get tableColumnDuration;

  /// No description provided for @viewAllResults.
  ///
  /// In en, this message translates to:
  /// **'View all results'**
  String get viewAllResults;

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

  /// No description provided for @playAllShuffled.
  ///
  /// In en, this message translates to:
  /// **'Shuffle all'**
  String get playAllShuffled;

  /// No description provided for @nextTrackTooltip.
  ///
  /// In en, this message translates to:
  /// **'Next track'**
  String get nextTrackTooltip;

  /// No description provided for @previousTrackTooltip.
  ///
  /// In en, this message translates to:
  /// **'Previous track'**
  String get previousTrackTooltip;

  /// No description provided for @playerBarVolume.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get playerBarVolume;

  /// No description provided for @playerBarVolumePercent.
  ///
  /// In en, this message translates to:
  /// **'{percent}%'**
  String playerBarVolumePercent(int percent);

  /// No description provided for @playerBarMute.
  ///
  /// In en, this message translates to:
  /// **'Mute'**
  String get playerBarMute;

  /// No description provided for @playerBarUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get playerBarUnmute;

  /// No description provided for @playerBarQueue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get playerBarQueue;

  /// No description provided for @queuePanelNowPlaying.
  ///
  /// In en, this message translates to:
  /// **'Playing'**
  String get queuePanelNowPlaying;

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
  /// **'This song is already in the list. Changing the source replaces the existing version.'**
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
  /// **'Import from playlist or favorites link'**
  String get playlistImportFromLink;

  /// No description provided for @playlistImportChannel.
  ///
  /// In en, this message translates to:
  /// **'Platform'**
  String get playlistImportChannel;

  /// No description provided for @playlistImportEmpty.
  ///
  /// In en, this message translates to:
  /// **'Playlist or favorites has no importable tracks'**
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
  /// **'Paste a playlist or favorites link or ID'**
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
  /// **'Audio, lyric and artwork usage and cleanup rules'**
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
  /// **'Cache what you play'**
  String get cachePolicyAudioScope;

  /// No description provided for @cachePolicyAudioHint.
  ///
  /// In en, this message translates to:
  /// **'Songs are cached as they play, so they can play offline or be saved as downloads; the oldest cache is cleared when the limit is reached.'**
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
  /// **'Suggested: {value}'**
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
  /// **'Clear all caches (audio, lyrics and artwork)? This cannot be undone.'**
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
  /// **'Lock position (mouse clicks pass through)'**
  String get lyricsDesktopLock;

  /// No description provided for @lyricsDesktopFreeze.
  ///
  /// In en, this message translates to:
  /// **'Pause updates while the screen is off'**
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
  /// **'The whole window is hidden while paused, so this setting has no effect'**
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

  /// No description provided for @lyricsDesktopScrollMode.
  ///
  /// In en, this message translates to:
  /// **'Long line scrolling'**
  String get lyricsDesktopScrollMode;

  /// No description provided for @lyricsDesktopScrollModeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Follow singing: text moves with the highlight; Constant: scrolls at a steady speed'**
  String get lyricsDesktopScrollModeSubtitle;

  /// No description provided for @lyricsDesktopScrollFollow.
  ///
  /// In en, this message translates to:
  /// **'Follow singing'**
  String get lyricsDesktopScrollFollow;

  /// No description provided for @lyricsDesktopScrollConstant.
  ///
  /// In en, this message translates to:
  /// **'Constant speed'**
  String get lyricsDesktopScrollConstant;

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
  /// **'Sync the current lyric to system playback controls'**
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
  /// **'Show the current lyric on the car head unit, notification shade and lock screen'**
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
  /// **'Allow notifications so media controls can stay visible; tap to open system settings'**
  String get lyricsNotificationPermissionSubtitle;

  /// No description provided for @lyricsMediaSessionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'System media controls failed to start: notification/lock-screen lyrics and playback controls are unavailable'**
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
  /// **'“Follow app theme” changes with the appearance settings; “Follow artwork” picks colors from the current song and updates live.'**
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
  /// **'AI radio with your own key'**
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
  /// **'AI keeps picking songs into the queue and continues when it ends'**
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
  /// **'When enabled, your listening profile (stats summary, the latest 50 plays, and songs already heard) is sent to the AI service you configure to generate recommendations. Data goes directly to that service, not through this app, and no built-in key is provided.\nTurning the mode off stops recommendations; clearing the config disconnects it.'**
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
  /// **'{count} recommendations left in the queue'**
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
  /// **'Latest {events} plays · {artists} frequent artists · {exclusions} already-heard songs excluded'**
  String aiDjUpstreamBody(int events, int artists, int exclusions);

  /// No description provided for @aiDjUpstreamHint.
  ///
  /// In en, this message translates to:
  /// **'Only the stats above plus song and artist names — no play links or device information.'**
  String get aiDjUpstreamHint;

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

  /// No description provided for @aiDjPreferencesTitle.
  ///
  /// In en, this message translates to:
  /// **'Recommendation preferences'**
  String get aiDjPreferencesTitle;

  /// No description provided for @aiDjPreferencesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Styles, scenes and what gets sent'**
  String get aiDjPreferencesSubtitle;

  /// No description provided for @aiDjBatchSize.
  ///
  /// In en, this message translates to:
  /// **'{count} per batch'**
  String aiDjBatchSize(int count);

  /// No description provided for @aiDjBatchSizeTitle.
  ///
  /// In en, this message translates to:
  /// **'Batch size'**
  String get aiDjBatchSizeTitle;

  /// No description provided for @aiDjFeedBatch.
  ///
  /// In en, this message translates to:
  /// **'Add a batch to the queue'**
  String get aiDjFeedBatch;

  /// No description provided for @aiDjSectionsNone.
  ///
  /// In en, this message translates to:
  /// **'Preferences only'**
  String get aiDjSectionsNone;

  /// No description provided for @aiDjFeedDone.
  ///
  /// In en, this message translates to:
  /// **'Batch added to the queue'**
  String get aiDjFeedDone;

  /// No description provided for @aiDjUnresolvedRetried.
  ///
  /// In en, this message translates to:
  /// **'Searched again'**
  String get aiDjUnresolvedRetried;

  /// No description provided for @aiDjHistoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Recommendation history'**
  String get aiDjHistoryTitle;

  /// No description provided for @aiDjHistoryEntry.
  ///
  /// In en, this message translates to:
  /// **'History ({count})'**
  String aiDjHistoryEntry(int count);

  /// No description provided for @aiDjHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No batch history yet'**
  String get aiDjHistoryEmpty;

  /// No description provided for @aiDjHistoryEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Every generated batch is kept here.'**
  String get aiDjHistoryEmptyHint;

  /// No description provided for @aiDjHistoryPlay.
  ///
  /// In en, this message translates to:
  /// **'Play this batch'**
  String get aiDjHistoryPlay;

  /// No description provided for @aiDjHistoryEnqueue.
  ///
  /// In en, this message translates to:
  /// **'Add to queue'**
  String get aiDjHistoryEnqueue;

  /// No description provided for @aiDjHistorySetActive.
  ///
  /// In en, this message translates to:
  /// **'Set as current'**
  String get aiDjHistorySetActive;

  /// No description provided for @aiDjHistoryDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete this batch'**
  String get aiDjHistoryDelete;

  /// No description provided for @aiDjHistoryActive.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get aiDjHistoryActive;

  /// No description provided for @aiDjHistoryClear.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get aiDjHistoryClear;

  /// No description provided for @aiDjHistoryClearTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear recommendation history?'**
  String get aiDjHistoryClearTitle;

  /// No description provided for @aiDjHistoryClearBody.
  ///
  /// In en, this message translates to:
  /// **'Only history records are removed; the playing queue is not affected. The current batch is kept.'**
  String get aiDjHistoryClearBody;

  /// No description provided for @aiDjHistoryCleared.
  ///
  /// In en, this message translates to:
  /// **'Recommendation history cleared'**
  String get aiDjHistoryCleared;

  /// No description provided for @aiDjHistoryExpand.
  ///
  /// In en, this message translates to:
  /// **'View tracks'**
  String get aiDjHistoryExpand;

  /// No description provided for @aiDjHistoryCollapse.
  ///
  /// In en, this message translates to:
  /// **'Hide tracks'**
  String get aiDjHistoryCollapse;

  /// No description provided for @aiDjHistoryItems.
  ///
  /// In en, this message translates to:
  /// **'{count} tracks'**
  String aiDjHistoryItems(int count);

  /// No description provided for @aiDjHistoryUnresolved.
  ///
  /// In en, this message translates to:
  /// **'{count} not found'**
  String aiDjHistoryUnresolved(int count);

  /// No description provided for @aiDjHistorySource.
  ///
  /// In en, this message translates to:
  /// **'From {origin}'**
  String aiDjHistorySource(String origin);

  /// No description provided for @aiDjOriginRefresh.
  ///
  /// In en, this message translates to:
  /// **'a refresh'**
  String get aiDjOriginRefresh;

  /// No description provided for @aiDjOriginAutoFeed.
  ///
  /// In en, this message translates to:
  /// **'auto-feed'**
  String get aiDjOriginAutoFeed;

  /// No description provided for @aiDjOriginManualFeed.
  ///
  /// In en, this message translates to:
  /// **'a manual top-up'**
  String get aiDjOriginManualFeed;

  /// No description provided for @aiDjHistoryLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'This batch is damaged and cannot be opened'**
  String get aiDjHistoryLoadFailed;

  /// No description provided for @aiDjMoreLikeThis.
  ///
  /// In en, this message translates to:
  /// **'More like this'**
  String get aiDjMoreLikeThis;

  /// No description provided for @aiDjRetryUnresolved.
  ///
  /// In en, this message translates to:
  /// **'Search again'**
  String get aiDjRetryUnresolved;

  /// No description provided for @aiDjTransparencyTitle.
  ///
  /// In en, this message translates to:
  /// **'What gets sent to AI'**
  String get aiDjTransparencyTitle;

  /// No description provided for @aiDjViewPrompt.
  ///
  /// In en, this message translates to:
  /// **'View exact prompt'**
  String get aiDjViewPrompt;

  /// No description provided for @aiDjSystemPrompt.
  ///
  /// In en, this message translates to:
  /// **'System prompt'**
  String get aiDjSystemPrompt;

  /// No description provided for @aiDjUserPrompt.
  ///
  /// In en, this message translates to:
  /// **'User prompt'**
  String get aiDjUserPrompt;

  /// No description provided for @aiDjCopyPrompt.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get aiDjCopyPrompt;

  /// No description provided for @aiDjPromptCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get aiDjPromptCopied;

  /// No description provided for @aiDjPromptTabPreview.
  ///
  /// In en, this message translates to:
  /// **'This batch'**
  String get aiDjPromptTabPreview;

  /// No description provided for @aiDjPromptTabLastSent.
  ///
  /// In en, this message translates to:
  /// **'Last sent'**
  String get aiDjPromptTabLastSent;

  /// No description provided for @aiDjPromptTabLastRaw.
  ///
  /// In en, this message translates to:
  /// **'Last reply'**
  String get aiDjPromptTabLastRaw;

  /// No description provided for @aiDjPromptUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Preview isn\'t available right now'**
  String get aiDjPromptUnavailable;

  /// No description provided for @aiDjLastSentPrompt.
  ///
  /// In en, this message translates to:
  /// **'Last prompt sent'**
  String get aiDjLastSentPrompt;

  /// No description provided for @aiDjLastRawResponse.
  ///
  /// In en, this message translates to:
  /// **'Last AI response'**
  String get aiDjLastRawResponse;

  /// No description provided for @aiDjNoLastPrompt.
  ///
  /// In en, this message translates to:
  /// **'Nothing sent yet'**
  String get aiDjNoLastPrompt;

  /// No description provided for @aiDjNoLastResponse.
  ///
  /// In en, this message translates to:
  /// **'No response yet'**
  String get aiDjNoLastResponse;

  /// No description provided for @aiDjPromptPrivacyHint.
  ///
  /// In en, this message translates to:
  /// **'No play links, device information or API key.'**
  String get aiDjPromptPrivacyHint;

  /// No description provided for @aiDjSendSummary.
  ///
  /// In en, this message translates to:
  /// **'Sending: {sections}'**
  String aiDjSendSummary(String sections);

  /// No description provided for @aiDjAutoFeedTitle.
  ///
  /// In en, this message translates to:
  /// **'Auto-fill near the end of the queue'**
  String get aiDjAutoFeedTitle;

  /// No description provided for @aiDjAutoFeedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Adds a batch automatically with 5 tracks left, without interrupting playback'**
  String get aiDjAutoFeedSubtitle;

  /// No description provided for @aiDjAutoFeedFailed.
  ///
  /// In en, this message translates to:
  /// **'Auto-fill failed; it will retry later'**
  String get aiDjAutoFeedFailed;

  /// No description provided for @aiDjAutoFeedHalted.
  ///
  /// In en, this message translates to:
  /// **'Auto-fill paused after {count} failures in a row'**
  String aiDjAutoFeedHalted(int count);

  /// No description provided for @aiDjAutoFeedResume.
  ///
  /// In en, this message translates to:
  /// **'Resume auto-fill'**
  String get aiDjAutoFeedResume;

  /// No description provided for @aiDjGenerationStatus.
  ///
  /// In en, this message translates to:
  /// **'Generating recommendations'**
  String get aiDjGenerationStatus;

  /// No description provided for @aiDjPhaseProfile.
  ///
  /// In en, this message translates to:
  /// **'Reading your taste'**
  String get aiDjPhaseProfile;

  /// No description provided for @aiDjPhaseModel.
  ///
  /// In en, this message translates to:
  /// **'AI is picking songs'**
  String get aiDjPhaseModel;

  /// No description provided for @aiDjPhaseResolving.
  ///
  /// In en, this message translates to:
  /// **'Finding songs {done}/{total}'**
  String aiDjPhaseResolving(int done, int total);

  /// No description provided for @aiDjWaitingSeconds.
  ///
  /// In en, this message translates to:
  /// **'Waiting {seconds}s'**
  String aiDjWaitingSeconds(int seconds);

  /// No description provided for @aiDjCancelGeneration.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get aiDjCancelGeneration;

  /// No description provided for @aiDjReplacing.
  ///
  /// In en, this message translates to:
  /// **'Swapping…'**
  String get aiDjReplacing;

  /// No description provided for @aiDjPrefsGenerationGroup.
  ///
  /// In en, this message translates to:
  /// **'Generation'**
  String get aiDjPrefsGenerationGroup;

  /// No description provided for @aiDjPrefsStylesGroup.
  ///
  /// In en, this message translates to:
  /// **'Styles'**
  String get aiDjPrefsStylesGroup;

  /// No description provided for @aiDjPrefsScenesGroup.
  ///
  /// In en, this message translates to:
  /// **'Scenes'**
  String get aiDjPrefsScenesGroup;

  /// No description provided for @aiDjPrefsLanguagesGroup.
  ///
  /// In en, this message translates to:
  /// **'Languages'**
  String get aiDjPrefsLanguagesGroup;

  /// No description provided for @aiDjPrefsEraGroup.
  ///
  /// In en, this message translates to:
  /// **'Era'**
  String get aiDjPrefsEraGroup;

  /// No description provided for @aiDjPrefsExtraGroup.
  ///
  /// In en, this message translates to:
  /// **'Extra request'**
  String get aiDjPrefsExtraGroup;

  /// No description provided for @aiDjPrefsExtraHint.
  ///
  /// In en, this message translates to:
  /// **'Up to 120 characters, sent to AI with your request'**
  String get aiDjPrefsExtraHint;

  /// No description provided for @aiDjPrefsOnlyUnheardTitle.
  ///
  /// In en, this message translates to:
  /// **'Only unheard tracks'**
  String get aiDjPrefsOnlyUnheardTitle;

  /// No description provided for @aiDjPrefsOnlyUnheardSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Skip tracks you have already played'**
  String get aiDjPrefsOnlyUnheardSubtitle;

  /// No description provided for @aiDjPrefsExplorationTitle.
  ///
  /// In en, this message translates to:
  /// **'Exploration'**
  String get aiDjPrefsExplorationTitle;

  /// No description provided for @aiDjExplorationSafe.
  ///
  /// In en, this message translates to:
  /// **'Safe'**
  String get aiDjExplorationSafe;

  /// No description provided for @aiDjExplorationBalanced.
  ///
  /// In en, this message translates to:
  /// **'Balanced'**
  String get aiDjExplorationBalanced;

  /// No description provided for @aiDjExplorationSurprise.
  ///
  /// In en, this message translates to:
  /// **'Surprise'**
  String get aiDjExplorationSurprise;

  /// No description provided for @aiDjStylePop.
  ///
  /// In en, this message translates to:
  /// **'Pop'**
  String get aiDjStylePop;

  /// No description provided for @aiDjStyleRock.
  ///
  /// In en, this message translates to:
  /// **'Rock'**
  String get aiDjStyleRock;

  /// No description provided for @aiDjStyleElectronic.
  ///
  /// In en, this message translates to:
  /// **'Electronic'**
  String get aiDjStyleElectronic;

  /// No description provided for @aiDjStyleFolk.
  ///
  /// In en, this message translates to:
  /// **'Folk'**
  String get aiDjStyleFolk;

  /// No description provided for @aiDjStyleRap.
  ///
  /// In en, this message translates to:
  /// **'Rap'**
  String get aiDjStyleRap;

  /// No description provided for @aiDjStyleRnb.
  ///
  /// In en, this message translates to:
  /// **'R&B'**
  String get aiDjStyleRnb;

  /// No description provided for @aiDjStyleJazz.
  ///
  /// In en, this message translates to:
  /// **'Jazz'**
  String get aiDjStyleJazz;

  /// No description provided for @aiDjStyleClassical.
  ///
  /// In en, this message translates to:
  /// **'Classical'**
  String get aiDjStyleClassical;

  /// No description provided for @aiDjStyleMetal.
  ///
  /// In en, this message translates to:
  /// **'Metal'**
  String get aiDjStyleMetal;

  /// No description provided for @aiDjStyleAcg.
  ///
  /// In en, this message translates to:
  /// **'ACG'**
  String get aiDjStyleAcg;

  /// No description provided for @aiDjStyleInstrumental.
  ///
  /// In en, this message translates to:
  /// **'Instrumental'**
  String get aiDjStyleInstrumental;

  /// No description provided for @aiDjStyleChineseStyle.
  ///
  /// In en, this message translates to:
  /// **'Chinese style'**
  String get aiDjStyleChineseStyle;

  /// No description provided for @aiDjSceneCommute.
  ///
  /// In en, this message translates to:
  /// **'Commute'**
  String get aiDjSceneCommute;

  /// No description provided for @aiDjSceneFocus.
  ///
  /// In en, this message translates to:
  /// **'Focus'**
  String get aiDjSceneFocus;

  /// No description provided for @aiDjSceneRelax.
  ///
  /// In en, this message translates to:
  /// **'Relax'**
  String get aiDjSceneRelax;

  /// No description provided for @aiDjSceneWorkout.
  ///
  /// In en, this message translates to:
  /// **'Workout'**
  String get aiDjSceneWorkout;

  /// No description provided for @aiDjSceneSleep.
  ///
  /// In en, this message translates to:
  /// **'Sleep'**
  String get aiDjSceneSleep;

  /// No description provided for @aiDjSceneWeekend.
  ///
  /// In en, this message translates to:
  /// **'Weekend'**
  String get aiDjSceneWeekend;

  /// No description provided for @aiDjLanguageMandarin.
  ///
  /// In en, this message translates to:
  /// **'Mandarin'**
  String get aiDjLanguageMandarin;

  /// No description provided for @aiDjLanguageCantonese.
  ///
  /// In en, this message translates to:
  /// **'Cantonese'**
  String get aiDjLanguageCantonese;

  /// No description provided for @aiDjLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get aiDjLanguageEnglish;

  /// No description provided for @aiDjLanguageJapanese.
  ///
  /// In en, this message translates to:
  /// **'Japanese'**
  String get aiDjLanguageJapanese;

  /// No description provided for @aiDjLanguageKorean.
  ///
  /// In en, this message translates to:
  /// **'Korean'**
  String get aiDjLanguageKorean;

  /// No description provided for @aiDjLanguageInstrumental.
  ///
  /// In en, this message translates to:
  /// **'Instrumental'**
  String get aiDjLanguageInstrumental;

  /// No description provided for @aiDjEraAny.
  ///
  /// In en, this message translates to:
  /// **'Any'**
  String get aiDjEraAny;

  /// No description provided for @aiDjEraRecent3.
  ///
  /// In en, this message translates to:
  /// **'Last 3 years'**
  String get aiDjEraRecent3;

  /// No description provided for @aiDjEra2010s.
  ///
  /// In en, this message translates to:
  /// **'2010s'**
  String get aiDjEra2010s;

  /// No description provided for @aiDjEra2000s.
  ///
  /// In en, this message translates to:
  /// **'2000s'**
  String get aiDjEra2000s;

  /// No description provided for @aiDjEraBefore90.
  ///
  /// In en, this message translates to:
  /// **'Before the 90s'**
  String get aiDjEraBefore90;

  /// No description provided for @aiDjPrefsAutoSaveHint.
  ///
  /// In en, this message translates to:
  /// **'Changes save automatically and apply to the next batch.'**
  String get aiDjPrefsAutoSaveHint;

  /// No description provided for @aiDjPrefsReset.
  ///
  /// In en, this message translates to:
  /// **'Restore defaults'**
  String get aiDjPrefsReset;

  /// No description provided for @aiDjPrefsResetTitle.
  ///
  /// In en, this message translates to:
  /// **'Restore default preferences?'**
  String get aiDjPrefsResetTitle;

  /// No description provided for @aiDjPrefsResetBody.
  ///
  /// In en, this message translates to:
  /// **'Styles, scenes and sending scope return to defaults; saved recommendations are not affected.'**
  String get aiDjPrefsResetBody;

  /// No description provided for @aiDjPrefsResetDone.
  ///
  /// In en, this message translates to:
  /// **'Default preferences restored'**
  String get aiDjPrefsResetDone;

  /// No description provided for @aiDjPrefsDataScope.
  ///
  /// In en, this message translates to:
  /// **'What gets sent'**
  String get aiDjPrefsDataScope;

  /// No description provided for @aiDjScopeHint.
  ///
  /// In en, this message translates to:
  /// **'Unchecked items are not sent; favorites and playlists are off by default.'**
  String get aiDjScopeHint;

  /// No description provided for @aiDjScopeSummary.
  ///
  /// In en, this message translates to:
  /// **'Listening summary'**
  String get aiDjScopeSummary;

  /// No description provided for @aiDjScopeTopArtists.
  ///
  /// In en, this message translates to:
  /// **'Frequent artists'**
  String get aiDjScopeTopArtists;

  /// No description provided for @aiDjScopeTopTracks.
  ///
  /// In en, this message translates to:
  /// **'Frequent tracks'**
  String get aiDjScopeTopTracks;

  /// No description provided for @aiDjScopeTimeAndSource.
  ///
  /// In en, this message translates to:
  /// **'Time and source breakdown'**
  String get aiDjScopeTimeAndSource;

  /// No description provided for @aiDjScopeRecentEvents.
  ///
  /// In en, this message translates to:
  /// **'Recent plays'**
  String get aiDjScopeRecentEvents;

  /// No description provided for @aiDjScopeListenedExclusions.
  ///
  /// In en, this message translates to:
  /// **'Already-heard exclusion list'**
  String get aiDjScopeListenedExclusions;

  /// No description provided for @aiDjScopeFavorites.
  ///
  /// In en, this message translates to:
  /// **'Favorite tracks'**
  String get aiDjScopeFavorites;

  /// No description provided for @aiDjScopePlaylists.
  ///
  /// In en, this message translates to:
  /// **'Your playlists'**
  String get aiDjScopePlaylists;

  /// No description provided for @aiDjScopeFavoritesConfirm.
  ///
  /// In en, this message translates to:
  /// **'This reads the titles and artists of up to 100 favorite tracks so they are not recommended again.'**
  String get aiDjScopeFavoritesConfirm;

  /// No description provided for @aiDjScopePlaylistsConfirm.
  ///
  /// In en, this message translates to:
  /// **'This reads the names, titles and artists of up to 10 of your playlists so they are not recommended again.'**
  String get aiDjScopePlaylistsConfirm;

  /// No description provided for @aiDjSeedsTitle.
  ///
  /// In en, this message translates to:
  /// **'More like these'**
  String get aiDjSeedsTitle;

  /// No description provided for @aiDjSeedsHint.
  ///
  /// In en, this message translates to:
  /// **'Cleared after the next successful batch'**
  String get aiDjSeedsHint;

  /// No description provided for @aiDjSeedsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No “More like this” picks yet'**
  String get aiDjSeedsEmpty;

  /// No description provided for @aiDjClearMemory.
  ///
  /// In en, this message translates to:
  /// **'Clear AI memory'**
  String get aiDjClearMemory;

  /// No description provided for @aiDjClearMemoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear AI memory?'**
  String get aiDjClearMemoryTitle;

  /// No description provided for @aiDjClearMemoryBody.
  ///
  /// In en, this message translates to:
  /// **'This deletes long-term “not interested”, “liked” and “more like these” entries. This round\'s feedback is cleared too.'**
  String get aiDjClearMemoryBody;

  /// No description provided for @aiDjMemoryCleared.
  ///
  /// In en, this message translates to:
  /// **'AI memory cleared'**
  String get aiDjMemoryCleared;

  /// No description provided for @aiDjFeedbackMemory.
  ///
  /// In en, this message translates to:
  /// **'Long-term memory'**
  String get aiDjFeedbackMemory;

  /// No description provided for @aiDjFeedbackThisRound.
  ///
  /// In en, this message translates to:
  /// **'This round'**
  String get aiDjFeedbackThisRound;

  /// No description provided for @aiDjSeedLabel.
  ///
  /// In en, this message translates to:
  /// **'More like · {label}'**
  String aiDjSeedLabel(String label);

  /// No description provided for @settingsSyncTitle.
  ///
  /// In en, this message translates to:
  /// **'Cross-device sync'**
  String get settingsSyncTitle;

  /// No description provided for @settingsSyncItemSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Playlists, sources, settings and keys'**
  String get settingsSyncItemSubtitle;

  /// No description provided for @syncLocalSection.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get syncLocalSection;

  /// No description provided for @syncLocalSectionHint.
  ///
  /// In en, this message translates to:
  /// **'Other devices need this information to reach this device; these addresses are also used for nearby pairing.'**
  String get syncLocalSectionHint;

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
  /// **'Any device that knows the passphrase can read and write all synced data; reset it if leaked.'**
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

  /// No description provided for @syncNever.
  ///
  /// In en, this message translates to:
  /// **'Never synced'**
  String get syncNever;

  /// No description provided for @syncStatusSyncedPeers.
  ///
  /// In en, this message translates to:
  /// **'Synced with {count} devices'**
  String syncStatusSyncedPeers(int count);

  /// No description provided for @syncRelativeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get syncRelativeJustNow;

  /// No description provided for @syncRelativeMinutes.
  ///
  /// In en, this message translates to:
  /// **'{count} min ago'**
  String syncRelativeMinutes(int count);

  /// No description provided for @syncRelativeHours.
  ///
  /// In en, this message translates to:
  /// **'{count} h ago'**
  String syncRelativeHours(int count);

  /// No description provided for @syncRelativeDays.
  ///
  /// In en, this message translates to:
  /// **'{count} d ago'**
  String syncRelativeDays(int count);

  /// No description provided for @syncOutcomeOk.
  ///
  /// In en, this message translates to:
  /// **'Synced'**
  String get syncOutcomeOk;

  /// No description provided for @syncOutcomeNoChanges.
  ///
  /// In en, this message translates to:
  /// **'No changes'**
  String get syncOutcomeNoChanges;

  /// No description provided for @syncOutcomeNoPeers.
  ///
  /// In en, this message translates to:
  /// **'No other device found'**
  String get syncOutcomeNoPeers;

  /// No description provided for @syncOutcomePartial.
  ///
  /// In en, this message translates to:
  /// **'Partly failed'**
  String get syncOutcomePartial;

  /// No description provided for @syncOutcomeFailed.
  ///
  /// In en, this message translates to:
  /// **'Sync failed'**
  String get syncOutcomeFailed;

  /// No description provided for @syncTriggerStartup.
  ///
  /// In en, this message translates to:
  /// **'startup'**
  String get syncTriggerStartup;

  /// No description provided for @syncTriggerDebounce.
  ///
  /// In en, this message translates to:
  /// **'data changed'**
  String get syncTriggerDebounce;

  /// No description provided for @syncTriggerTimer.
  ///
  /// In en, this message translates to:
  /// **'scheduled'**
  String get syncTriggerTimer;

  /// No description provided for @syncTriggerIncoming.
  ///
  /// In en, this message translates to:
  /// **'sent by another device'**
  String get syncTriggerIncoming;

  /// No description provided for @syncTriggerResume.
  ///
  /// In en, this message translates to:
  /// **'resumed'**
  String get syncTriggerResume;

  /// No description provided for @syncTriggerPause.
  ///
  /// In en, this message translates to:
  /// **'before background'**
  String get syncTriggerPause;

  /// No description provided for @syncTriggerNetwork.
  ///
  /// In en, this message translates to:
  /// **'network changed'**
  String get syncTriggerNetwork;

  /// No description provided for @syncTriggerDiscovery.
  ///
  /// In en, this message translates to:
  /// **'device found'**
  String get syncTriggerDiscovery;

  /// No description provided for @syncTriggerCheck.
  ///
  /// In en, this message translates to:
  /// **'opened sync page'**
  String get syncTriggerCheck;

  /// No description provided for @syncTriggerManual.
  ///
  /// In en, this message translates to:
  /// **'manual'**
  String get syncTriggerManual;

  /// No description provided for @syncActivitySection.
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get syncActivitySection;

  /// No description provided for @syncActivityTitle.
  ///
  /// In en, this message translates to:
  /// **'Last 24 hours'**
  String get syncActivityTitle;

  /// No description provided for @syncActivityRounds.
  ///
  /// In en, this message translates to:
  /// **'{rounds} runs, {effective} with changes · {bytes} transferred'**
  String syncActivityRounds(int rounds, int effective, String bytes);

  /// No description provided for @syncActivityEnvironment.
  ///
  /// In en, this message translates to:
  /// **'{level} · {network} · {powerSave}'**
  String syncActivityEnvironment(
    String level,
    String network,
    String powerSave,
  );

  /// No description provided for @syncLevelActive.
  ///
  /// In en, this message translates to:
  /// **'active'**
  String get syncLevelActive;

  /// No description provided for @syncLevelIdle.
  ///
  /// In en, this message translates to:
  /// **'idle'**
  String get syncLevelIdle;

  /// No description provided for @syncLevelBackground.
  ///
  /// In en, this message translates to:
  /// **'background'**
  String get syncLevelBackground;

  /// No description provided for @syncLevelPowerSave.
  ///
  /// In en, this message translates to:
  /// **'power save'**
  String get syncLevelPowerSave;

  /// No description provided for @syncLevelUnknown.
  ///
  /// In en, this message translates to:
  /// **'not running'**
  String get syncLevelUnknown;

  /// No description provided for @syncNetworkCellular.
  ///
  /// In en, this message translates to:
  /// **'cellular'**
  String get syncNetworkCellular;

  /// No description provided for @syncNetworkOther.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi / other'**
  String get syncNetworkOther;

  /// No description provided for @syncPowerSaveOn.
  ///
  /// In en, this message translates to:
  /// **'power save on'**
  String get syncPowerSaveOn;

  /// No description provided for @syncPowerSaveOff.
  ///
  /// In en, this message translates to:
  /// **'power save off'**
  String get syncPowerSaveOff;

  /// No description provided for @syncCellularSection.
  ///
  /// In en, this message translates to:
  /// **'Cellular'**
  String get syncCellularSection;

  /// No description provided for @syncCellularPauseTitle.
  ///
  /// In en, this message translates to:
  /// **'Pause automatic sync on cellular'**
  String get syncCellularPauseTitle;

  /// No description provided for @syncCellularPauseSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When off, mobile data syncs only small items (settings, playlists); stats and history wait for Wi-Fi'**
  String get syncCellularPauseSubtitle;

  /// No description provided for @syncAppliedItems.
  ///
  /// In en, this message translates to:
  /// **'{applied} updated'**
  String syncAppliedItems(int applied);

  /// No description provided for @syncPeerCount.
  ///
  /// In en, this message translates to:
  /// **'{count} devices'**
  String syncPeerCount(int count);

  /// No description provided for @syncFailedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} failures'**
  String syncFailedCount(int count);

  /// No description provided for @syncBytes.
  ///
  /// In en, this message translates to:
  /// **'↓{inbound} ↑{outbound}'**
  String syncBytes(String inbound, String outbound);

  /// No description provided for @syncRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get syncRetry;

  /// No description provided for @syncContentSection.
  ///
  /// In en, this message translates to:
  /// **'What to sync'**
  String get syncContentSection;

  /// No description provided for @syncContentAllOn.
  ///
  /// In en, this message translates to:
  /// **'All categories'**
  String get syncContentAllOn;

  /// No description provided for @syncContentOffCount.
  ///
  /// In en, this message translates to:
  /// **'{count} turned off'**
  String syncContentOffCount(int count);

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

  /// No description provided for @syncCategoryCovers.
  ///
  /// In en, this message translates to:
  /// **'Custom covers'**
  String get syncCategoryCovers;

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
  /// **'Last playback state'**
  String get syncCategorySession;

  /// No description provided for @syncCategoryCredentials.
  ///
  /// In en, this message translates to:
  /// **'AI radio and keys'**
  String get syncCategoryCredentials;

  /// No description provided for @syncTransportSection.
  ///
  /// In en, this message translates to:
  /// **'Transport'**
  String get syncTransportSection;

  /// No description provided for @syncTransportAllOffHint.
  ///
  /// In en, this message translates to:
  /// **'Sync does not run while both methods are off; turn one on to start.'**
  String get syncTransportAllOffHint;

  /// No description provided for @syncLanTitle.
  ///
  /// In en, this message translates to:
  /// **'LAN direct'**
  String get syncLanTitle;

  /// No description provided for @syncWebdavTitle.
  ///
  /// In en, this message translates to:
  /// **'WebDAV / cloud'**
  String get syncWebdavTitle;

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
  /// **'Cloud folder'**
  String get syncWebdavRemoteDir;

  /// No description provided for @syncWebdavNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get syncWebdavNotConfigured;

  /// No description provided for @syncTransportRunning.
  ///
  /// In en, this message translates to:
  /// **'running'**
  String get syncTransportRunning;

  /// No description provided for @syncTransportStopped.
  ///
  /// In en, this message translates to:
  /// **'stopped'**
  String get syncTransportStopped;

  /// No description provided for @syncTransportDisabled.
  ///
  /// In en, this message translates to:
  /// **'turned off'**
  String get syncTransportDisabled;

  /// No description provided for @syncTransportNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'not configured'**
  String get syncTransportNotConfigured;

  /// No description provided for @syncTransportStartFailed.
  ///
  /// In en, this message translates to:
  /// **'failed to start'**
  String get syncTransportStartFailed;

  /// No description provided for @syncLogTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync log'**
  String get syncLogTitle;

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

  /// No description provided for @syncLogFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String syncLogFailed(String error);

  /// No description provided for @syncAdvancedTitle.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get syncAdvancedTitle;

  /// No description provided for @syncAdvancedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Device name, passphrase, and network addresses'**
  String get syncAdvancedSubtitle;

  /// No description provided for @syncPeersSection.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get syncPeersSection;

  /// No description provided for @syncPeersHint.
  ///
  /// In en, this message translates to:
  /// **'Turn on LAN sync, then tap a device under Nearby devices to pair. If nothing appears, check LAN permission or use a manual address.'**
  String get syncPeersHint;

  /// No description provided for @syncPeersEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No paired devices yet'**
  String get syncPeersEmptyTitle;

  /// No description provided for @syncPeersEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tap a device under Nearby devices, or add an address in Advanced settings'**
  String get syncPeersEmptySubtitle;

  /// No description provided for @syncNearbySection.
  ///
  /// In en, this message translates to:
  /// **'Nearby devices'**
  String get syncNearbySection;

  /// No description provided for @syncNearbyTapToPair.
  ///
  /// In en, this message translates to:
  /// **'Tap to pair'**
  String get syncNearbyTapToPair;

  /// No description provided for @syncNearbyHasGroup.
  ///
  /// In en, this message translates to:
  /// **'The other device is already in a sync group'**
  String get syncNearbyHasGroup;

  /// No description provided for @syncNearbyLanOffTitle.
  ///
  /// In en, this message translates to:
  /// **'LAN sync is off'**
  String get syncNearbyLanOffTitle;

  /// No description provided for @syncNearbyLanOffHint.
  ///
  /// In en, this message translates to:
  /// **'Turn on LAN sync above and nearby devices will appear here.'**
  String get syncNearbyLanOffHint;

  /// No description provided for @syncNearbySearching.
  ///
  /// In en, this message translates to:
  /// **'Looking for nearby devices…'**
  String get syncNearbySearching;

  /// No description provided for @syncNearbySearchHint.
  ///
  /// In en, this message translates to:
  /// **'Make sure the other device has Molia open and LAN sync on'**
  String get syncNearbySearchHint;

  /// No description provided for @syncNearbyRescan.
  ///
  /// In en, this message translates to:
  /// **'Search again'**
  String get syncNearbyRescan;

  /// No description provided for @syncNearbyEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No devices found'**
  String get syncNearbyEmptyTitle;

  /// No description provided for @syncNearbyEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Ask the other device to open Molia and turn on LAN sync'**
  String get syncNearbyEmptyHint;

  /// No description provided for @syncNearbyFooter.
  ///
  /// In en, this message translates to:
  /// **'Only accept devices you know. Accepting lets the other device read all synced data (including keys). If nothing appears, add an address in Advanced settings.'**
  String get syncNearbyFooter;

  /// No description provided for @syncNearbyPairTitle.
  ///
  /// In en, this message translates to:
  /// **'Pair with “{name}”'**
  String syncNearbyPairTitle(String name);

  /// No description provided for @syncNearbyContacting.
  ///
  /// In en, this message translates to:
  /// **'Contacting the other device…'**
  String get syncNearbyContacting;

  /// No description provided for @syncNearbyCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Confirmation code'**
  String get syncNearbyCodeLabel;

  /// No description provided for @syncNearbyCheckCode.
  ///
  /// In en, this message translates to:
  /// **'Check that the other device shows the same numbers'**
  String get syncNearbyCheckCode;

  /// No description provided for @syncNearbyWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the other device to accept…'**
  String get syncNearbyWaiting;

  /// No description provided for @syncNearbyJoined.
  ///
  /// In en, this message translates to:
  /// **'Joined the sync group'**
  String get syncNearbyJoined;

  /// No description provided for @syncNearbySameGroup.
  ///
  /// In en, this message translates to:
  /// **'Already in the same sync group'**
  String get syncNearbySameGroup;

  /// No description provided for @syncNearbyResultRejected.
  ///
  /// In en, this message translates to:
  /// **'The other device rejected the request. You can try again later.'**
  String get syncNearbyResultRejected;

  /// No description provided for @syncNearbyResultExpired.
  ///
  /// In en, this message translates to:
  /// **'The pairing request expired. Tap the device to try again.'**
  String get syncNearbyResultExpired;

  /// No description provided for @syncNearbyResultConflict.
  ///
  /// In en, this message translates to:
  /// **'The devices are in different sync groups. Reset one device’s passphrase and try again.'**
  String get syncNearbyResultConflict;

  /// No description provided for @syncNearbyResultUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t reach the device. Make sure both devices are on the same network with LAN sync on.'**
  String get syncNearbyResultUnreachable;

  /// No description provided for @syncNearbyResultBusy.
  ///
  /// In en, this message translates to:
  /// **'The other device is handling another request. Try again shortly.'**
  String get syncNearbyResultBusy;

  /// No description provided for @syncNearbyResultUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This device doesn’t support one-tap pairing yet. Update Molia and try again.'**
  String get syncNearbyResultUnsupported;

  /// No description provided for @syncNearbyResultUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Pairing is unavailable. Make sure both devices have LAN sync on and try again.'**
  String get syncNearbyResultUnavailable;

  /// No description provided for @syncNearbyResultCancelled.
  ///
  /// In en, this message translates to:
  /// **'Pairing cancelled. Tap the device to try again.'**
  String get syncNearbyResultCancelled;

  /// No description provided for @syncNearbyIncomingJoinTitle.
  ///
  /// In en, this message translates to:
  /// **'“{name}” wants to join your sync group'**
  String syncNearbyIncomingJoinTitle(String name);

  /// No description provided for @syncNearbyIncomingInviteTitle.
  ///
  /// In en, this message translates to:
  /// **'“{name}” invited you to join their sync group'**
  String syncNearbyIncomingInviteTitle(String name);

  /// No description provided for @syncNearbyIncomingJoinWarning.
  ///
  /// In en, this message translates to:
  /// **'If you accept, the other device can read all synced data (including scripts and keys). Only accept devices you know.'**
  String get syncNearbyIncomingJoinWarning;

  /// No description provided for @syncNearbyIncomingInviteWarning.
  ///
  /// In en, this message translates to:
  /// **'Accepting joins their sync group and switches this device to their passphrase. The other device can then read all synced data (including scripts and keys).'**
  String get syncNearbyIncomingInviteWarning;

  /// No description provided for @syncNearbyAccept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get syncNearbyAccept;

  /// No description provided for @syncNearbyReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get syncNearbyReject;

  /// No description provided for @syncNearbyIncomingRejected.
  ///
  /// In en, this message translates to:
  /// **'Pairing request rejected'**
  String get syncNearbyIncomingRejected;

  /// No description provided for @syncNearbyIncomingExpired.
  ///
  /// In en, this message translates to:
  /// **'The pairing request expired'**
  String get syncNearbyIncomingExpired;

  /// No description provided for @syncNearbyIncomingFailed.
  ///
  /// In en, this message translates to:
  /// **'Pairing didn’t finish. Ask the other device to try again.'**
  String get syncNearbyIncomingFailed;

  /// No description provided for @syncNearbyIncomingNotCompleted.
  ///
  /// In en, this message translates to:
  /// **'Accepted, but the other device hasn’t finished pairing. If it doesn’t join, ask it to try again.'**
  String get syncNearbyIncomingNotCompleted;

  /// No description provided for @syncNearbyManualProbeSent.
  ///
  /// In en, this message translates to:
  /// **'Looking for this device; tap it under Nearby devices to pair'**
  String get syncNearbyManualProbeSent;

  /// No description provided for @syncPeerThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device · {id}'**
  String syncPeerThisDevice(String id);

  /// No description provided for @syncPeerThisDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'This device ID'**
  String get syncPeerThisDeviceTitle;

  /// No description provided for @syncPeerNever.
  ///
  /// In en, this message translates to:
  /// **'Not connected yet'**
  String get syncPeerNever;

  /// No description provided for @syncSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing…'**
  String get syncSyncing;

  /// No description provided for @syncPeerConnectedSince.
  ///
  /// In en, this message translates to:
  /// **'Connected · last synced {time}'**
  String syncPeerConnectedSince(String time);

  /// No description provided for @syncPeerDisconnectedSince.
  ///
  /// In en, this message translates to:
  /// **'Not connected · last synced {time}'**
  String syncPeerDisconnectedSince(String time);

  /// No description provided for @syncPeerCloudSyncedSince.
  ///
  /// In en, this message translates to:
  /// **'Synced to cloud · last synced {time}'**
  String syncPeerCloudSyncedSince(String time);

  /// No description provided for @syncPeerCloudNotSyncedSince.
  ///
  /// In en, this message translates to:
  /// **'Not synced to cloud · last synced {time}'**
  String syncPeerCloudNotSyncedSince(String time);

  /// No description provided for @syncPeerLastSuccess.
  ///
  /// In en, this message translates to:
  /// **'Last synced {time}'**
  String syncPeerLastSuccess(String time);

  /// No description provided for @syncPeerLastAttempt.
  ///
  /// In en, this message translates to:
  /// **'Last attempt {time}'**
  String syncPeerLastAttempt(String time);

  /// No description provided for @syncPeerLostSince.
  ///
  /// In en, this message translates to:
  /// **'Lost · last synced {time}'**
  String syncPeerLostSince(String time);

  /// No description provided for @syncPeerNameSeparator.
  ///
  /// In en, this message translates to:
  /// **', '**
  String get syncPeerNameSeparator;

  /// No description provided for @syncRoundNoConnectedPeers.
  ///
  /// In en, this message translates to:
  /// **'No devices connected this round'**
  String get syncRoundNoConnectedPeers;

  /// No description provided for @syncRoundNoRecords.
  ///
  /// In en, this message translates to:
  /// **'No connection records yet'**
  String get syncRoundNoRecords;

  /// No description provided for @syncRoundSynced.
  ///
  /// In en, this message translates to:
  /// **'Synced this round: {names}'**
  String syncRoundSynced(String names);

  /// No description provided for @syncRoundSyncedMore.
  ///
  /// In en, this message translates to:
  /// **'Synced this round: {names} and {count} more'**
  String syncRoundSyncedMore(String names, int count);

  /// No description provided for @syncPeerBehind.
  ///
  /// In en, this message translates to:
  /// **'{count} pending'**
  String syncPeerBehind(int count);

  /// No description provided for @syncPeerBehindBytes.
  ///
  /// In en, this message translates to:
  /// **'{count} pending (~{size})'**
  String syncPeerBehindBytes(int count, String size);

  /// No description provided for @syncPeerClockSkew.
  ///
  /// In en, this message translates to:
  /// **'device time differs by {minutes} min'**
  String syncPeerClockSkew(int minutes);

  /// No description provided for @syncPeerLastError.
  ///
  /// In en, this message translates to:
  /// **'Last error: {error}'**
  String syncPeerLastError(String error);

  /// No description provided for @syncTransportPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'LAN permission missing'**
  String get syncTransportPermissionDenied;

  /// No description provided for @syncLanPermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Grant LAN permission'**
  String get syncLanPermissionTitle;

  /// No description provided for @syncLanPermissionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Android 17+ needs the nearby-devices permission to reach other devices'**
  String get syncLanPermissionSubtitle;

  /// No description provided for @syncLanPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Permission not granted: LAN sync is unavailable (manual addresses cannot work around it). Switch to WebDAV instead.'**
  String get syncLanPermissionDenied;

  /// No description provided for @syncLanPermissionNeeded.
  ///
  /// In en, this message translates to:
  /// **'LAN permission required'**
  String get syncLanPermissionNeeded;

  /// No description provided for @syncLanPermissionGrant.
  ///
  /// In en, this message translates to:
  /// **'Grant'**
  String get syncLanPermissionGrant;

  /// No description provided for @syncOpenSystemSettings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get syncOpenSystemSettings;

  /// No description provided for @syncPeerHostLabel.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get syncPeerHostLabel;

  /// No description provided for @syncPeerHostHint.
  ///
  /// In en, this message translates to:
  /// **'e.g. 192.168.1.23 or 2409:8a55::5'**
  String get syncPeerHostHint;

  /// No description provided for @syncPeerNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name (optional)'**
  String get syncPeerNameLabel;

  /// No description provided for @syncPeerHostInvalid.
  ///
  /// In en, this message translates to:
  /// **'Address cannot be empty'**
  String get syncPeerHostInvalid;

  /// No description provided for @syncPeerDelete.
  ///
  /// In en, this message translates to:
  /// **'Remove device'**
  String get syncPeerDelete;

  /// No description provided for @syncPeerDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Removes it from this device only; it does not revoke sync access. If it still has the sync passphrase and is online, it will appear again. To stop syncing with it, change the sync passphrase.'**
  String get syncPeerDeleteConfirm;

  /// No description provided for @syncPeerRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed from this device'**
  String get syncPeerRemoved;

  /// No description provided for @syncPeerManual.
  ///
  /// In en, this message translates to:
  /// **'added manually'**
  String get syncPeerManual;

  /// No description provided for @syncPeerLost.
  ///
  /// In en, this message translates to:
  /// **'Lost'**
  String get syncPeerLost;

  /// No description provided for @syncPeerLostHint.
  ///
  /// In en, this message translates to:
  /// **'This device has not connected for over 180 days (it may have been reinstalled or retired). You can remove it from this device, or clean up its cloud sync files; local data is unaffected.'**
  String get syncPeerLostHint;

  /// No description provided for @syncPeerCleanupRemote.
  ///
  /// In en, this message translates to:
  /// **'Clean up cloud files'**
  String get syncPeerCleanupRemote;

  /// No description provided for @syncPeerCleanupRemoteHint.
  ///
  /// In en, this message translates to:
  /// **'Delete this device’s sync files on WebDAV'**
  String get syncPeerCleanupRemoteHint;

  /// No description provided for @syncPeerCleanupRemoteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Deletes this device’s sync files on WebDAV; local data is unaffected. Files are written again when the device comes back online. LAN connections have no cloud files.'**
  String get syncPeerCleanupRemoteConfirm;

  /// No description provided for @syncPeerCleanupRemoteDone.
  ///
  /// In en, this message translates to:
  /// **'Cloud files cleaned up'**
  String get syncPeerCleanupRemoteDone;

  /// No description provided for @syncPeerCleanupRemoteNone.
  ///
  /// In en, this message translates to:
  /// **'No cloud files to clean up'**
  String get syncPeerCleanupRemoteNone;

  /// No description provided for @syncPeerCleanupRemoteFailed.
  ///
  /// In en, this message translates to:
  /// **'Cleanup failed: {error}'**
  String syncPeerCleanupRemoteFailed(Object error);

  /// No description provided for @syncPeerNotContacted.
  ///
  /// In en, this message translates to:
  /// **'Not connected yet — it retries automatically when the device is online'**
  String get syncPeerNotContacted;

  /// No description provided for @syncPeerCandidatesTitle.
  ///
  /// In en, this message translates to:
  /// **'{count} available addresses'**
  String syncPeerCandidatesTitle(int count);

  /// No description provided for @syncPeerCandidatesSubtitle.
  ///
  /// In en, this message translates to:
  /// **'not connected yet · tap to view or remove'**
  String get syncPeerCandidatesSubtitle;

  /// No description provided for @syncLocalAddressCopied.
  ///
  /// In en, this message translates to:
  /// **'Address copied'**
  String get syncLocalAddressCopied;

  /// No description provided for @syncLocalAddressesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No available network address'**
  String get syncLocalAddressesEmptyTitle;

  /// No description provided for @syncLocalAddressesHint.
  ///
  /// In en, this message translates to:
  /// **'These addresses are used by other devices to reach this one.'**
  String get syncLocalAddressesHint;

  /// No description provided for @syncLocalAddressesEmpty.
  ///
  /// In en, this message translates to:
  /// **'No usable LAN address found; check the network connection.'**
  String get syncLocalAddressesEmpty;

  /// No description provided for @syncLocalProbePort.
  ///
  /// In en, this message translates to:
  /// **'Discovery port'**
  String get syncLocalProbePort;

  /// No description provided for @syncLocalProbePortUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Unavailable; add a device address manually'**
  String get syncLocalProbePortUnavailable;

  /// No description provided for @syncLocalProbePortPerFamily.
  ///
  /// In en, this message translates to:
  /// **'{v4} (IPv4) / {v6} (IPv6)'**
  String syncLocalProbePortPerFamily(String v4, String v6);

  /// No description provided for @syncLocalHttpPort.
  ///
  /// In en, this message translates to:
  /// **'Connection port'**
  String get syncLocalHttpPort;

  /// No description provided for @syncLocalHttpPortUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Not started yet'**
  String get syncLocalHttpPortUnavailable;

  /// No description provided for @syncPeerDeviceId.
  ///
  /// In en, this message translates to:
  /// **'Device {id}'**
  String syncPeerDeviceId(String id);

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
  /// **'When off, this device neither uploads nor receives this data'**
  String get syncCategorySubtitle;

  /// No description provided for @syncIssueDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Sync issue'**
  String get syncIssueDialogTitle;

  /// No description provided for @syncIssueUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown reason — retry first; if it keeps failing, check the sync log'**
  String get syncIssueUnknown;

  /// No description provided for @syncIssueNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Sync transport is not configured'**
  String get syncIssueNotConfigured;

  /// No description provided for @syncIssueStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Transport failed to start'**
  String get syncIssueStartFailed;

  /// No description provided for @syncIssuePermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'LAN permission missing (Android 17+ needs the nearby-devices permission)'**
  String get syncIssuePermissionDenied;

  /// No description provided for @syncIssueNoPassphrase.
  ///
  /// In en, this message translates to:
  /// **'No sync passphrase set'**
  String get syncIssueNoPassphrase;

  /// No description provided for @syncIssueAllPeersUnreachable.
  ///
  /// In en, this message translates to:
  /// **'No device can be reached'**
  String get syncIssueAllPeersUnreachable;

  /// No description provided for @syncIssuePullFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to read sync data'**
  String get syncIssuePullFailed;

  /// No description provided for @syncIssuePushFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to upload local changes'**
  String get syncIssuePushFailed;

  /// No description provided for @syncIssueApplyFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to receive sync data {count} time(s)'**
  String syncIssueApplyFailed(int count);

  /// No description provided for @syncIssuePeerReadFailed.
  ///
  /// In en, this message translates to:
  /// **'{peer}: failed to read sync data'**
  String syncIssuePeerReadFailed(String peer);

  /// No description provided for @syncIssuePeerDecryptFailed.
  ///
  /// In en, this message translates to:
  /// **'{peer}: passphrase mismatch or corrupted data'**
  String syncIssuePeerDecryptFailed(String peer);

  /// No description provided for @syncIssuePeerPushFailed.
  ///
  /// In en, this message translates to:
  /// **'{peer}: upload failed'**
  String syncIssuePeerPushFailed(String peer);

  /// No description provided for @syncIssueBroadcastUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Auto-discovery failed (blocked by network policy)'**
  String get syncIssueBroadcastUnavailable;

  /// No description provided for @syncIssueProbePortUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Auto-discovery unavailable; add a device address manually'**
  String get syncIssueProbePortUnavailable;

  /// No description provided for @syncIssueDiscoverySilent.
  ///
  /// In en, this message translates to:
  /// **'No other device found (the network may be isolated)'**
  String get syncIssueDiscoverySilent;

  /// No description provided for @syncIssueWebdavDirFailed.
  ///
  /// In en, this message translates to:
  /// **'WebDAV folder unavailable'**
  String get syncIssueWebdavDirFailed;

  /// No description provided for @syncIssueWebdavListFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to read the WebDAV folder'**
  String get syncIssueWebdavListFailed;

  /// No description provided for @syncIssueWebdavReadFailed.
  ///
  /// In en, this message translates to:
  /// **'{peer}: failed to read sync data'**
  String syncIssueWebdavReadFailed(String peer);

  /// No description provided for @syncIssueWebdavDecryptFailed.
  ///
  /// In en, this message translates to:
  /// **'{peer}: passphrase mismatch or corrupted data'**
  String syncIssueWebdavDecryptFailed(String peer);

  /// No description provided for @syncIssueWebdavUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to upload sync data to WebDAV'**
  String get syncIssueWebdavUploadFailed;

  /// No description provided for @syncIssueDeleteRemoteFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to clean up cloud files for {peer}'**
  String syncIssueDeleteRemoteFailed(String peer);

  /// No description provided for @syncIssueInternal.
  ///
  /// In en, this message translates to:
  /// **'Sync error'**
  String get syncIssueInternal;

  /// No description provided for @syncActionGrantPermission.
  ///
  /// In en, this message translates to:
  /// **'Grant permission'**
  String get syncActionGrantPermission;

  /// No description provided for @syncActionConfigure.
  ///
  /// In en, this message translates to:
  /// **'Configure'**
  String get syncActionConfigure;

  /// No description provided for @syncActionConfigurePassphrase.
  ///
  /// In en, this message translates to:
  /// **'Set passphrase'**
  String get syncActionConfigurePassphrase;

  /// No description provided for @syncActionAddManualPeer.
  ///
  /// In en, this message translates to:
  /// **'Add manual address'**
  String get syncActionAddManualPeer;

  /// No description provided for @syncActionUseWebdav.
  ///
  /// In en, this message translates to:
  /// **'Use WebDAV'**
  String get syncActionUseWebdav;

  /// No description provided for @syncWebdavEnabled.
  ///
  /// In en, this message translates to:
  /// **'WebDAV enabled'**
  String get syncWebdavEnabled;

  /// No description provided for @syncConfigureOnSettingsPage.
  ///
  /// In en, this message translates to:
  /// **'Set the passphrase on the sync settings page'**
  String get syncConfigureOnSettingsPage;

  /// No description provided for @syncPeerUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown device'**
  String get syncPeerUnknown;

  /// No description provided for @syncPeerDeviceIdCopied.
  ///
  /// In en, this message translates to:
  /// **'Full device ID copied'**
  String get syncPeerDeviceIdCopied;

  /// No description provided for @syncPeerHostFormatInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid address (use an IP or hostname, without a port)'**
  String get syncPeerHostFormatInvalid;

  /// No description provided for @syncPeerPortInvalid.
  ///
  /// In en, this message translates to:
  /// **'Port must be 1–65535'**
  String get syncPeerPortInvalid;

  /// No description provided for @syncPeerAdded.
  ///
  /// In en, this message translates to:
  /// **'Device added'**
  String get syncPeerAdded;

  /// No description provided for @syncPeerUpdated.
  ///
  /// In en, this message translates to:
  /// **'Device updated'**
  String get syncPeerUpdated;

  /// No description provided for @syncPeerUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Not connected: make sure the device is online on the same network, or update its address'**
  String get syncPeerUnreachable;

  /// No description provided for @syncPeerProbePortLabel.
  ///
  /// In en, this message translates to:
  /// **'Discovery port'**
  String get syncPeerProbePortLabel;

  /// No description provided for @syncPeerProbePortHint.
  ///
  /// In en, this message translates to:
  /// **'Default {port}'**
  String syncPeerProbePortHint(int port);

  /// No description provided for @syncPeerAlreadyAdded.
  ///
  /// In en, this message translates to:
  /// **'Already in the list — name and port updated'**
  String get syncPeerAlreadyAdded;

  /// No description provided for @syncManualConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect manually'**
  String get syncManualConnect;

  /// No description provided for @syncManualConnectSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter the device address manually when auto-discovery fails'**
  String get syncManualConnectSubtitle;

  /// No description provided for @syncManualConnectHint.
  ///
  /// In en, this message translates to:
  /// **'Enter an address here when auto-discovery fails. Unpaired devices appear under Nearby devices and pair with one tap.'**
  String get syncManualConnectHint;

  /// No description provided for @syncNetworkAddresses.
  ///
  /// In en, this message translates to:
  /// **'Network addresses'**
  String get syncNetworkAddresses;

  /// No description provided for @syncNetworkAddressesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} available'**
  String syncNetworkAddressesCount(int count);

  /// No description provided for @syncPeerAddressCount.
  ///
  /// In en, this message translates to:
  /// **'{count} addresses'**
  String syncPeerAddressCount(int count);

  /// No description provided for @syncPeerAddressEdit.
  ///
  /// In en, this message translates to:
  /// **'Update address'**
  String get syncPeerAddressEdit;

  /// No description provided for @syncPeerAddressDelete.
  ///
  /// In en, this message translates to:
  /// **'Remove address'**
  String get syncPeerAddressDelete;

  /// No description provided for @syncPeerAddressDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Removes this address from the list; a connected device is unaffected.'**
  String get syncPeerAddressDeleteConfirm;

  /// No description provided for @syncPeerAddressUpdated.
  ///
  /// In en, this message translates to:
  /// **'Address updated'**
  String get syncPeerAddressUpdated;

  /// No description provided for @syncPeerAddressRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed from the address list'**
  String get syncPeerAddressRemoved;

  /// No description provided for @syncPeerContactQueued.
  ///
  /// In en, this message translates to:
  /// **'Device added — it will connect shortly'**
  String get syncPeerContactQueued;

  /// No description provided for @syncPeerAddedOffline.
  ///
  /// In en, this message translates to:
  /// **'{name} added — not reachable yet, it will retry'**
  String syncPeerAddedOffline(String name);

  /// No description provided for @syncPeerConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected to {name}'**
  String syncPeerConnected(String name);

  /// No description provided for @syncPeerContacting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get syncPeerContacting;

  /// No description provided for @syncLanPermissionPermanentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Permission permanently denied — enable nearby-devices in system settings'**
  String get syncLanPermissionPermanentSubtitle;

  /// No description provided for @syncLogHint.
  ///
  /// In en, this message translates to:
  /// **'Results of recent sync rounds; tap a failed row for the reason and next steps'**
  String get syncLogHint;

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

  /// No description provided for @updateMacosHint.
  ///
  /// In en, this message translates to:
  /// **'Download macOS builds from the release page; in-app updates are not available.'**
  String get updateMacosHint;

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
  /// **'Update information URL'**
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

  /// No description provided for @updateGithubTitle.
  ///
  /// In en, this message translates to:
  /// **'GitHub repository'**
  String get updateGithubTitle;

  /// No description provided for @updateErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Network error — update check failed'**
  String get updateErrorNetwork;

  /// No description provided for @updateErrorManifest.
  ///
  /// In en, this message translates to:
  /// **'Invalid update information'**
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
    String percent,
    String receivedMb,
    String speedMb,
  );

  /// No description provided for @trackInfoTabTitle.
  ///
  /// In en, this message translates to:
  /// **'Details'**
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
  /// **'Playback link cache'**
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
  /// **'This platform does not write a playback cache; one is added after playback'**
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
  /// **'Only the cache is cleared; downloads and playback are unaffected.'**
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
  /// **'Already cached — no download needed'**
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

  /// No description provided for @downloadSaveLocationSharedHint.
  ///
  /// In en, this message translates to:
  /// **'Used for downloads and exports'**
  String get downloadSaveLocationSharedHint;

  /// No description provided for @downloadSaveLocationAndroid.
  ///
  /// In en, this message translates to:
  /// **'Downloads › Molia'**
  String get downloadSaveLocationAndroid;

  /// No description provided for @downloadSaveLocationIos.
  ///
  /// In en, this message translates to:
  /// **'Files › On My iPhone › Molia'**
  String get downloadSaveLocationIos;

  /// No description provided for @downloadSaveLocationFixedHintAndroid.
  ///
  /// In en, this message translates to:
  /// **'The playback copy stays in the app; a copy is also saved to Downloads after each download'**
  String get downloadSaveLocationFixedHintAndroid;

  /// No description provided for @downloadSaveLocationFixedHintAndroidOff.
  ///
  /// In en, this message translates to:
  /// **'Public copy is off; files stay in the app. Turn on “Publish to system Downloads” below'**
  String get downloadSaveLocationFixedHintAndroidOff;

  /// No description provided for @downloadSaveLocationFixedHintIos.
  ///
  /// In en, this message translates to:
  /// **'Files are visible in Files › On My iPhone › Molia'**
  String get downloadSaveLocationFixedHintIos;

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
  /// **'Write tags into the audio file (MP3 / FLAC) so other players can read them; the original file is kept if writing fails'**
  String get downloadEmbedTagsSubtitle;

  /// No description provided for @downloadPublishToPublicDir.
  ///
  /// In en, this message translates to:
  /// **'Publish to system Downloads'**
  String get downloadPublishToPublicDir;

  /// No description provided for @downloadPublishToPublicDirSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Also save a copy to the system Downloads folder (Android) so file managers and other players can see it'**
  String get downloadPublishToPublicDirSubtitle;

  /// No description provided for @downloadNotifications.
  ///
  /// In en, this message translates to:
  /// **'Download notifications'**
  String get downloadNotifications;

  /// No description provided for @downloadNotificationsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Show download progress in the notification shade and keep downloading in the background (Android; notification permission required)'**
  String get downloadNotificationsSubtitle;

  /// No description provided for @downloadLocationInfo.
  ///
  /// In en, this message translates to:
  /// **'Download folder'**
  String get downloadLocationInfo;

  /// No description provided for @downloadPlaybackLocation.
  ///
  /// In en, this message translates to:
  /// **'Playback copy'**
  String get downloadPlaybackLocation;

  /// No description provided for @downloadPublicCopyLocation.
  ///
  /// In en, this message translates to:
  /// **'Also saved to'**
  String get downloadPublicCopyLocation;

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
  /// **'No lyrics found — try another source?'**
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

  /// No description provided for @commentsPullToRetry.
  ///
  /// In en, this message translates to:
  /// **'Pull down to retry'**
  String get commentsPullToRetry;

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
  /// **'Delete the download? Audio, lyrics and cover files will be removed.'**
  String get downloadDeleteConfirm;

  /// No description provided for @downloadDeleteConfirmMixed.
  ///
  /// In en, this message translates to:
  /// **'Delete the downloads? Audio, lyrics and cover files will be removed; imported songs are only removed from the list.'**
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
  /// **'Clear this song’s audio cache? Only the cache is removed; downloads and imported files are unaffected.'**
  String get localSongsCachedRemoveConfirm;

  /// No description provided for @localSongsMixedRemoveConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove the selected items? Downloads delete files, imported items are only removed from the list, and cached copies are cleared.'**
  String get localSongsMixedRemoveConfirm;

  /// No description provided for @downloadShare.
  ///
  /// In en, this message translates to:
  /// **'Share file'**
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
  /// **'Remove temporary files left by interrupted downloads; finished downloads are untouched'**
  String get downloadsCleanupPartsSubtitle;

  /// No description provided for @downloadsCleanupPartsDone.
  ///
  /// In en, this message translates to:
  /// **'Removed {count} unfinished file(s)'**
  String downloadsCleanupPartsDone(int count);

  /// No description provided for @downloadsCleanupOrphans.
  ///
  /// In en, this message translates to:
  /// **'Remove leftover files'**
  String get downloadsCleanupOrphans;

  /// No description provided for @downloadsCleanupOrphansSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Delete files in the download folder that no record points to'**
  String get downloadsCleanupOrphansSubtitle;

  /// No description provided for @downloadsCleanupOrphansDone.
  ///
  /// In en, this message translates to:
  /// **'Removed {count} leftover file(s)'**
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

  /// No description provided for @downloadsPublishPublic.
  ///
  /// In en, this message translates to:
  /// **'Copy to public Downloads folder'**
  String get downloadsPublishPublic;

  /// No description provided for @downloadsPublishPublicSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Copy downloads that are not in the system Downloads folder yet (Android)'**
  String get downloadsPublishPublicSubtitle;

  /// No description provided for @downloadsPublishPublicDone.
  ///
  /// In en, this message translates to:
  /// **'Copied {published}, failed {failed}'**
  String downloadsPublishPublicDone(int published, int failed);

  /// No description provided for @downloadsNoResume.
  ///
  /// In en, this message translates to:
  /// **'Failed downloads start over (platform links usually expire quickly).'**
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

  /// No description provided for @settingsShortcutsTitle.
  ///
  /// In en, this message translates to:
  /// **'Shortcuts'**
  String get settingsShortcutsTitle;

  /// No description provided for @settingsShortcutsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enable and customize in-app and global shortcuts'**
  String get settingsShortcutsSubtitle;

  /// No description provided for @shortcutsInAppSection.
  ///
  /// In en, this message translates to:
  /// **'In-app shortcuts'**
  String get shortcutsInAppSection;

  /// No description provided for @shortcutsInAppHint.
  ///
  /// In en, this message translates to:
  /// **'Active while the window is focused; tap a binding to re-record it'**
  String get shortcutsInAppHint;

  /// No description provided for @shortcutsGlobalSection.
  ///
  /// In en, this message translates to:
  /// **'Global shortcuts'**
  String get shortcutsGlobalSection;

  /// No description provided for @shortcutsGlobalHint.
  ///
  /// In en, this message translates to:
  /// **'Global shortcuts work even when the window is in the background; must include Ctrl / Alt / Shift'**
  String get shortcutsGlobalHint;

  /// No description provided for @shortcutsGlobalUnsupportedKey.
  ///
  /// In en, this message translates to:
  /// **'Global shortcuts only support letters, digits, F1–F12 and space'**
  String get shortcutsGlobalUnsupportedKey;

  /// No description provided for @shortcutsGlobalFailed.
  ///
  /// In en, this message translates to:
  /// **'Some global shortcuts could not be enabled: {detail}'**
  String shortcutsGlobalFailed(String detail);

  /// No description provided for @shortcutsGlobalLinuxHint.
  ///
  /// In en, this message translates to:
  /// **'On Linux these are provided through the desktop portal; minimal desktops may not support it and will report a failure'**
  String get shortcutsGlobalLinuxHint;

  /// No description provided for @shortcutsEnabledSwitch.
  ///
  /// In en, this message translates to:
  /// **'Enable in-app shortcuts'**
  String get shortcutsEnabledSwitch;

  /// No description provided for @shortcutsGlobalEnabledSwitch.
  ///
  /// In en, this message translates to:
  /// **'Enable global shortcuts'**
  String get shortcutsGlobalEnabledSwitch;

  /// No description provided for @shortcutsResetAll.
  ///
  /// In en, this message translates to:
  /// **'Reset to defaults'**
  String get shortcutsResetAll;

  /// No description provided for @shortcutsRecording.
  ///
  /// In en, this message translates to:
  /// **'Press a new key… (Esc to cancel)'**
  String get shortcutsRecording;

  /// No description provided for @shortcutsConflict.
  ///
  /// In en, this message translates to:
  /// **'Already used by “{action}”'**
  String shortcutsConflict(Object action);

  /// No description provided for @shortcutsGlobalNeedsModifier.
  ///
  /// In en, this message translates to:
  /// **'Global shortcuts must include Ctrl / Alt / Shift'**
  String get shortcutsGlobalNeedsModifier;

  /// No description provided for @shortcutsSwapDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Replace shortcut?'**
  String get shortcutsSwapDialogTitle;

  /// No description provided for @shortcutsSwapDialogMessage.
  ///
  /// In en, this message translates to:
  /// **'“{action}” already uses this combination. Replacing will swap the two shortcuts.'**
  String shortcutsSwapDialogMessage(String action);

  /// No description provided for @shortcutsSwapConfirm.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get shortcutsSwapConfirm;

  /// No description provided for @shortcutsSwapDone.
  ///
  /// In en, this message translates to:
  /// **'Swapped shortcuts with “{action}”'**
  String shortcutsSwapDone(String action);

  /// No description provided for @shortcutActionPlayPause.
  ///
  /// In en, this message translates to:
  /// **'Play / pause'**
  String get shortcutActionPlayPause;

  /// No description provided for @shortcutActionSeekBackward.
  ///
  /// In en, this message translates to:
  /// **'Seek back 5s'**
  String get shortcutActionSeekBackward;

  /// No description provided for @shortcutActionSeekForward.
  ///
  /// In en, this message translates to:
  /// **'Seek forward 5s'**
  String get shortcutActionSeekForward;

  /// No description provided for @shortcutActionPrevious.
  ///
  /// In en, this message translates to:
  /// **'Previous track'**
  String get shortcutActionPrevious;

  /// No description provided for @shortcutActionNext.
  ///
  /// In en, this message translates to:
  /// **'Next track'**
  String get shortcutActionNext;

  /// No description provided for @shortcutActionVolumeUp.
  ///
  /// In en, this message translates to:
  /// **'Volume up'**
  String get shortcutActionVolumeUp;

  /// No description provided for @shortcutActionVolumeDown.
  ///
  /// In en, this message translates to:
  /// **'Volume down'**
  String get shortcutActionVolumeDown;

  /// No description provided for @shortcutActionMute.
  ///
  /// In en, this message translates to:
  /// **'Mute toggle'**
  String get shortcutActionMute;

  /// No description provided for @shortcutActionSearch.
  ///
  /// In en, this message translates to:
  /// **'Focus search'**
  String get shortcutActionSearch;

  /// No description provided for @shortcutActionDestination1.
  ///
  /// In en, this message translates to:
  /// **'Go to page 1'**
  String get shortcutActionDestination1;

  /// No description provided for @shortcutActionDestination2.
  ///
  /// In en, this message translates to:
  /// **'Go to page 2'**
  String get shortcutActionDestination2;

  /// No description provided for @shortcutActionDestination3.
  ///
  /// In en, this message translates to:
  /// **'Go to page 3'**
  String get shortcutActionDestination3;

  /// No description provided for @shortcutActionCloseQueue.
  ///
  /// In en, this message translates to:
  /// **'Close queue panel'**
  String get shortcutActionCloseQueue;

  /// No description provided for @shortcutActionShowWindow.
  ///
  /// In en, this message translates to:
  /// **'Show main window'**
  String get shortcutActionShowWindow;

  /// No description provided for @settingsRememberWindowBounds.
  ///
  /// In en, this message translates to:
  /// **'Remember window position and size'**
  String get settingsRememberWindowBounds;

  /// No description provided for @settingsRememberWindowBoundsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Reopen at the last position, size and maximized state'**
  String get settingsRememberWindowBoundsSubtitle;

  /// No description provided for @settingsTrayLinuxHint.
  ///
  /// In en, this message translates to:
  /// **'GNOME and similar desktops need a tray extension to show the icon; without a tray, closing the window quits the app'**
  String get settingsTrayLinuxHint;

  /// No description provided for @sourcesPlatformAccounts.
  ///
  /// In en, this message translates to:
  /// **'Platform accounts'**
  String get sourcesPlatformAccounts;

  /// No description provided for @biliAccountTitle.
  ///
  /// In en, this message translates to:
  /// **'Bilibili account'**
  String get biliAccountTitle;

  /// No description provided for @biliAccountTileLoggedOut.
  ///
  /// In en, this message translates to:
  /// **'Sign in to prefer Bilibili captions as lyrics'**
  String get biliAccountTileLoggedOut;

  /// No description provided for @biliAccountTileLoggedIn.
  ///
  /// In en, this message translates to:
  /// **'Signed in · Bilibili captions are preferred for lyrics'**
  String get biliAccountTileLoggedIn;

  /// No description provided for @biliAccountLoginIntro.
  ///
  /// In en, this message translates to:
  /// **'Playback works without signing in. After signing in, captions on Bilibili videos are used as lyrics first.'**
  String get biliAccountLoginIntro;

  /// No description provided for @biliAccountLoginAction.
  ///
  /// In en, this message translates to:
  /// **'Sign in with QR code'**
  String get biliAccountLoginAction;

  /// No description provided for @biliAccountQrHint.
  ///
  /// In en, this message translates to:
  /// **'Scan with the Bilibili app'**
  String get biliAccountQrHint;

  /// No description provided for @biliAccountQrScanned.
  ///
  /// In en, this message translates to:
  /// **'Scanned. Confirm on your phone.'**
  String get biliAccountQrScanned;

  /// No description provided for @biliAccountQrExpired.
  ///
  /// In en, this message translates to:
  /// **'QR code expired'**
  String get biliAccountQrExpired;

  /// No description provided for @biliAccountQrRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh QR code'**
  String get biliAccountQrRefresh;

  /// No description provided for @biliAccountQrFailed.
  ///
  /// In en, this message translates to:
  /// **'Sign-in failed. Try again.'**
  String get biliAccountQrFailed;

  /// No description provided for @biliAccountLoginSuccess.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get biliAccountLoginSuccess;

  /// No description provided for @biliAccountLoginPersistFailed.
  ///
  /// In en, this message translates to:
  /// **'Signed in, but the sign-in info could not be saved. You will need to sign in again after restart.'**
  String get biliAccountLoginPersistFailed;

  /// No description provided for @biliAccountStatusSection.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get biliAccountStatusSection;

  /// No description provided for @biliAccountLoggedIn.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get biliAccountLoggedIn;

  /// No description provided for @biliAccountLoggedInAs.
  ///
  /// In en, this message translates to:
  /// **'Signed in as {name}'**
  String biliAccountLoggedInAs(String name);

  /// No description provided for @biliAccountLoggedOut.
  ///
  /// In en, this message translates to:
  /// **'Not signed in'**
  String get biliAccountLoggedOut;

  /// No description provided for @biliAccountSessionExpired.
  ///
  /// In en, this message translates to:
  /// **'Sign-in expired. Please sign in again.'**
  String get biliAccountSessionExpired;

  /// No description provided for @biliAccountLogoutAction.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get biliAccountLogoutAction;

  /// No description provided for @biliAccountLogoutConfirm.
  ///
  /// In en, this message translates to:
  /// **'After signing out, Bilibili captions will no longer be read. Cached lyrics stay.'**
  String get biliAccountLogoutConfirm;

  /// No description provided for @biliAccountLogoutFailed.
  ///
  /// In en, this message translates to:
  /// **'Sign-out failed. Try again.'**
  String get biliAccountLogoutFailed;

  /// No description provided for @biliAccountPrivacyHint.
  ///
  /// In en, this message translates to:
  /// **'Sign-in info is kept in secure storage. If sync is on, it is encrypted and synced to paired devices. It is only used to read Bilibili captions.'**
  String get biliAccountPrivacyHint;

  /// No description provided for @biliAccountQrSemantics.
  ///
  /// In en, this message translates to:
  /// **'Bilibili sign-in QR code'**
  String get biliAccountQrSemantics;

  /// No description provided for @providerBilibili.
  ///
  /// In en, this message translates to:
  /// **'Bilibili'**
  String get providerBilibili;
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
    'that was used.',
  );
}
