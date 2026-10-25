// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settingsTitle => 'Settings';

  @override
  String get queueTab => 'QUEUE';

  @override
  String get lyricsTab => 'LYRICS';

  @override
  String get cancel => 'Cancel';

  @override
  String get close => 'Close';

  @override
  String playbackFailed(String error) {
    return 'Playback failed: $error';
  }

  @override
  String get searchHint => 'Search songs, albums, artists...';

  @override
  String get searchIdleHint => 'Search songs by keyword';

  @override
  String get clearSearch => 'Clear search';

  @override
  String get searchClose => 'Close search';

  @override
  String searchResultsAnnouncement(int count) {
    return '$count results available';
  }

  @override
  String copiedToClipboard(String type) {
    return 'Copied to clipboard';
  }

  @override
  String get delete => 'Delete';

  @override
  String get lyricsFetching => 'Fetching lyrics...';

  @override
  String get lyricsNotFoundForTrack => 'No lyrics found for this track.';

  @override
  String lyricsFetchError(String error) {
    return 'Error fetching lyrics: $error';
  }

  @override
  String get lyricsTitle => 'Lyrics';

  @override
  String get lyricsLoading => 'Loading lyrics...';

  @override
  String get lyricsFailedToLoad => 'Failed to load lyrics.';

  @override
  String get lyricsCopyModeSnackbar =>
      'Copy mode: single repeat is on and auto-follow is paused; your settings return when you exit.';

  @override
  String get centerCurrentLine => 'Center Current Line';

  @override
  String get playlist => 'Playlist';

  @override
  String get operationFailed => 'Operation failed';

  @override
  String get settingsAppearanceTitle => 'Appearance';

  @override
  String get settingsThemeMode => 'Theme mode';

  @override
  String get themeModeSystem => 'System';

  @override
  String get themeModeLight => 'Light';

  @override
  String get themeModeDark => 'Dark';

  @override
  String get settingsBaseColor => 'Base colors';

  @override
  String get settingsBaseColorWallpaper => 'System wallpaper';

  @override
  String get settingsBaseColorCustom => 'Custom color';

  @override
  String get settingsMonetUnavailable => 'Not supported on this platform';

  @override
  String get settingsBaseColorWallpaperActive => 'Source: system wallpaper';

  @override
  String get settingsBaseColorAccentActive => 'Source: system theme color';

  @override
  String get settingsPureBlack => 'Pure black background';

  @override
  String get settingsPureBlackSubtitle =>
      'Pure black background in dark mode — saves power on OLED';

  @override
  String get settingsSeedColor => 'Custom color';

  @override
  String get settingsFollowArtwork => 'Follow album art';

  @override
  String get settingsFollowArtworkSubtitle =>
      'Pick colors from the current song’s artwork; base colors when there is none';

  @override
  String get coverTitle => 'Song cover';

  @override
  String get coverFollowSong => 'Song artwork';

  @override
  String get coverCustomized => 'Customized';

  @override
  String get coverChooseImage => 'Choose image';

  @override
  String get coverChangeImage => 'Change image';

  @override
  String get coverResetSong => 'Restore song artwork';

  @override
  String get coverResetToDefault => 'Use default cover';

  @override
  String get coverRestored => 'Cover restored';

  @override
  String get coverDefaultRestored => 'Molia mark restored';

  @override
  String get coverUpdated => 'Cover updated';

  @override
  String get coverUpdateFailed => 'Couldn’t update the cover. Try again';

  @override
  String get coverUnreadable => 'Couldn’t read this image. Choose another';

  @override
  String get coverDefaultTitle => 'Default cover';

  @override
  String get coverDefaultSubtitle => 'Shown when a song has no artwork';

  @override
  String get coverResetDefault => 'Restore the Molia mark';

  @override
  String get coverDefaultUpdated => 'Default cover updated';

  @override
  String get settingsSyncCustomCovers => 'Sync custom covers';

  @override
  String get settingsSyncCustomCoversSubtitle =>
      'Sends cover images to your other devices';

  @override
  String get coverLabel => 'Cover';

  @override
  String get settingsAppFont => 'App font';

  @override
  String get fontSystemDefault => 'System default';

  @override
  String get fontPickerSearchHint => 'Search fonts';

  @override
  String get fontPickerEmpty => 'No available fonts found';

  @override
  String get posterFontLabel => 'Font';

  @override
  String get posterColorSource => 'Color source';

  @override
  String get posterColorSourceAppTheme => 'Follow app theme';

  @override
  String get posterColorSourceArtwork => 'Follow album art';

  @override
  String get posterColorSourceCustom => 'Custom color';

  @override
  String get posterColorCustomLabel => 'Custom color';

  @override
  String get posterColorUnavailable => 'No artwork for this track';

  @override
  String get posterFontFollowApp => 'Follow app font';

  @override
  String get colorBlue => 'Blue';

  @override
  String get colorPurple => 'Purple';

  @override
  String get colorGreen => 'Green';

  @override
  String get colorOrange => 'Orange';

  @override
  String get colorPink => 'Pink';

  @override
  String get colorTeal => 'Teal';

  @override
  String get settingsPlaybackTitle => 'Playback';

  @override
  String get settingsDefaultPlayMode => 'Default play mode';

  @override
  String get settingsDefaultPlayModeSubtitle =>
      'Used the next time playback starts; current playback is unaffected';

  @override
  String get settingsRestoreSessionTitle => 'Resume last playback';

  @override
  String get settingsRestoreSessionSubtitle =>
      'Remembers track, queue and position';

  @override
  String get settingsPlayWithOtherApps => 'Play with other apps';

  @override
  String get settingsPlayWithOtherAppsSubtitle =>
      'Navigation and videos won\'t interrupt music';

  @override
  String get settingsLibraryAddPosition => 'Position of added songs';

  @override
  String get settingsLibraryAddPositionSubtitle =>
      'Top or bottom of favorites and playlists';

  @override
  String get settingsLibraryAddPositionTop => 'Top';

  @override
  String get settingsLibraryAddPositionBottom => 'Bottom';

  @override
  String get settingsAutoSourceSwap => 'Auto source switch';

  @override
  String get settingsAutoSourceSwapSubtitle =>
      'On playback failure, look for the same song in another source';

  @override
  String get settingsDataSaverTitle => 'Data saver';

  @override
  String get settingsDataSaverSubtitle =>
      'Lower audio quality and load fewer covers on mobile data';

  @override
  String get settingsDataSaverNetworkCellular => 'Mobile data · active';

  @override
  String get settingsDataSaverNetworkWifi => 'Wi-Fi · inactive';

  @override
  String get settingsDataSaverNetworkUnknown => 'Network type unavailable';

  @override
  String get settingsDataSaverQuality => 'Data saver quality cap';

  @override
  String get settingsDataSaverCovers => 'Cached artwork only on mobile data';

  @override
  String get settingsDataSaverCoversSubtitle =>
      'Stop loading new artwork; show a placeholder when not cached';

  @override
  String get settingsSourcesItemSubtitle =>
      'Import LX Music source scripts to search more platforms';

  @override
  String get settingsContentSection => 'Content & sources';

  @override
  String get settingsLyricsSection => 'Lyrics & display';

  @override
  String get settingsBottomNavTitle => 'Bottom navigation';

  @override
  String get settingsBottomNavHint =>
      'Drag to reorder; toggle to show or hide a tab (at least one stays visible)';

  @override
  String get settingsBottomNavKeepOne => 'Keep at least one tab visible';

  @override
  String get settingsBottomNavKeepHome =>
      'This page is the startup page — change “Startup page” first';

  @override
  String get settingsStartupPageTitle => 'Startup page';

  @override
  String get settingsStartupPageSubtitle => 'Page opened when the app starts';

  @override
  String settingsStartupPageHidden(String page, String effective) {
    return '“$page” is hidden; the app opens “$effective” instead';
  }

  @override
  String get playModeListLoop => 'Repeat all';

  @override
  String get playModeSequential => 'Sequential';

  @override
  String get playModeShuffle => 'Shuffle';

  @override
  String get playModeSingleRepeat => 'Single repeat';

  @override
  String get generalTitle => 'General';

  @override
  String get settingsHapticsTitle => 'Vibration feedback';

  @override
  String get settingsHapticsSubtitle =>
      'Light vibration on taps such as navigation and playback';

  @override
  String get settingsGeneralTitle => 'General settings';

  @override
  String get settingsGeneralSubtitle =>
      'Language, app name and bottom navigation';

  @override
  String get settingsDataSection => 'Data';

  @override
  String get dataManagementTitle => 'Data & storage';

  @override
  String get settingsDataSubtitle => 'Cache, downloads and data import/export';

  @override
  String get settingsDataStorageSection => 'Storage & stats';

  @override
  String get settingsDataPortabilitySection => 'Import & export';

  @override
  String get exportDataTitle => 'Export data';

  @override
  String get exportDataSubtitle =>
      'Full backup: playlists, sources, settings, stats, history (no credentials)';

  @override
  String get importDataTitle => 'Import data';

  @override
  String get importDataSubtitle => 'Merge a Molia backup into local data';

  @override
  String get clearCacheTitle => 'Clear Lyrics Cache';

  @override
  String get clearCacheSubtitle => 'Clear cached lyrics';

  @override
  String get cancelButton => 'Cancel';

  @override
  String get languageSaved => 'Language setting saved';

  @override
  String get exportFailed => 'Export failed or cancelled.';

  @override
  String get importDialogTitle => 'Confirm Import';

  @override
  String get importDialogMessage =>
      'Importing merges the backup with local data; matching entries are replaced by the backup. This cannot be undone.\n\nMake sure the file is a backup exported from Molia.';

  @override
  String get importButton => 'Import Data';

  @override
  String get importSuccess => 'Data imported successfully!';

  @override
  String get importFailed => 'Failed to import data.';

  @override
  String get exportSuccess => 'Data exported successfully!';

  @override
  String savedToPath(String path) {
    return 'Saved to $path';
  }

  @override
  String savedToDownloads(String path) {
    return 'Saved to Downloads: $path';
  }

  @override
  String savedToFilesApp(String path) {
    return 'Saved to Files: $path';
  }

  @override
  String get saveFailed => 'Couldn\'t save. Try again.';

  @override
  String fileInDownloads(String path) {
    return 'File is in Downloads: $path';
  }

  @override
  String get clearCacheDialogTitle => 'Confirm Clear Cache';

  @override
  String get clearCacheDialogMessage =>
      'Are you sure you want to clear the lyrics cache? This cannot be undone.';

  @override
  String get clearCacheButton => 'Clear Cache';

  @override
  String get clearingCache => 'Clearing cache...';

  @override
  String get cacheCleared => 'Cache cleared successfully!';

  @override
  String get cacheClearFailed => 'Failed to clear cache';

  @override
  String get saveChanges => 'Save';

  @override
  String get selectLyrics => 'Select Lyrics';

  @override
  String get lyricsPosterAction => 'Lyrics poster';

  @override
  String get deselectAll => 'Deselect All';

  @override
  String get noLyricsSelected => 'Please select some lyrics first';

  @override
  String get sharePoster => 'Share Poster';

  @override
  String selectedLyricsCopied(int count) {
    return 'Copied $count lines of lyrics';
  }

  @override
  String posterGenerationFailed(Object error) {
    return 'Poster generation failed: $error';
  }

  @override
  String get noLyricsToSelect => 'No lyrics available to select';

  @override
  String get posterLyricsLimitExceeded =>
      'Maximum 10 lines of lyrics can be selected for poster generation';

  @override
  String get tapToSelectLyrics => 'Tap lyric line to select';

  @override
  String get nowPlayingLabel => 'Playing';

  @override
  String get libraryLabel => 'Discover';

  @override
  String get libraryTabSearch => 'Search';

  @override
  String get libraryTabLeaderboards => 'Charts';

  @override
  String get libraryTabPlaylists => 'Playlists';

  @override
  String get libraryChannelSelect => 'Select channel';

  @override
  String get libraryNoChannels =>
      'All channels are disabled. Enable channels in Source Management.';

  @override
  String get libraryLoadFailed => 'Couldn\'t load your library';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSimplifiedChinese => '简体中文';

  @override
  String get noItemsFound => 'No items found';

  @override
  String get copyButtonText => 'Copy';

  @override
  String get posterButtonLabel => 'Poster';

  @override
  String get retryButton => 'Retry';

  @override
  String get backToLibraryTooltip => 'Back to library';

  @override
  String get loadingGenerating => 'Generating poster...';

  @override
  String get currentQueueEmpty => 'Current queue is empty';

  @override
  String get nowPlayingSection => 'Playing';

  @override
  String get nowPlayingPaused => 'Paused';

  @override
  String get searchLyrics => 'Search Lyrics';

  @override
  String get noCurrentTrackPlaying => 'No track currently playing';

  @override
  String get cannotGetTrackInfo => 'Cannot get current track information';

  @override
  String get lyricsSearchAppliedSuccess =>
      'Lyrics successfully searched and applied';

  @override
  String get searchResults => 'SEARCH RESULTS';

  @override
  String get noResultsFound => 'No results found';

  @override
  String get playlistType => 'Playlist';

  @override
  String get albumType => 'Album';

  @override
  String get songType => 'Song';

  @override
  String get artistType => 'Artist';

  @override
  String get retry => 'Retry';

  @override
  String get providerQQMusic => 'QQ Music';

  @override
  String get providerLRCLIB => 'LRCLIB';

  @override
  String get providerNetease => 'NetEase Cloud Music';

  @override
  String get providerKugou => 'Kugou Music';

  @override
  String get providerKuwo => 'Kuwo Music';

  @override
  String get providerMigu => 'Migu Music';

  @override
  String get lyricsBestMatch => 'Best match';

  @override
  String get playingFrom => 'PLAYING FROM';

  @override
  String get playFromAlbum => 'PLAY FROM ALBUM';

  @override
  String get playFromPlaylist => 'PLAY FROM PLAYLIST';

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String get sourcesTitle => 'Source Management';

  @override
  String get sourcesStatusSection => 'Status';

  @override
  String get sourcesImportSection => 'Import script';

  @override
  String get anyListenEntry => 'any-listen';

  @override
  String get anyListenIntroBody =>
      'any-listen is a self-hosted music service. Once enabled, its online sources appear in search.';

  @override
  String get anyListenIntroHint =>
      'This integration has not been tested against a real server and may not work yet.';

  @override
  String get anyListenServerSection => 'Server';

  @override
  String get anyListenServerUrl => 'Server address';

  @override
  String get anyListenServerUrlHint => 'Address of your any-listen service';

  @override
  String get anyListenServerUrlRequired => 'Enter the server address first';

  @override
  String get anyListenServerUrlRequiredToEnable =>
      'Enter the server address before enabling';

  @override
  String get anyListenToken => 'Access password (optional)';

  @override
  String get anyListenTokenPlaceholder =>
      'After a successful test, paste the access password provided by the server';

  @override
  String get anyListenTokenShow => 'Show access password';

  @override
  String get anyListenTokenHide => 'Hide access password';

  @override
  String get anyListenEnable => 'Enable any-listen source';

  @override
  String get anyListenEnableSubtitle =>
      'When off, it is hidden from search and makes no network requests';

  @override
  String get anyListenSave => 'Save';

  @override
  String get anyListenTest => 'Test connection';

  @override
  String get anyListenSaveFailed => 'Save failed: cannot write local storage';

  @override
  String get sourcesNoneActive => 'No source enabled';

  @override
  String sourcesActiveSource(String name, String version) {
    return 'Active source: $name $version';
  }

  @override
  String get sourcesActivating => 'Activating…';

  @override
  String sourcesActivationFailed(String error) {
    return 'Activation failed: $error';
  }

  @override
  String sourcesAuthor(String author) {
    return 'Author: $author';
  }

  @override
  String get sourcesUpdateAlertTitle => 'Source update available';

  @override
  String get sourcesOpenUpdateUrl => 'Open update URL';

  @override
  String get sourcesUpdateDismiss => 'Got it';

  @override
  String get sourcesUpdateNow => 'Update now';

  @override
  String get sourcesUpdating => 'Updating…';

  @override
  String sourcesUpdateSuccess(String version) {
    return 'Updated to $version';
  }

  @override
  String get sourcesUpdateNoUpdate => 'Already up to date';

  @override
  String sourcesUpdateFailed(String reason) {
    return 'Update failed: $reason';
  }

  @override
  String get sourcesUpdateManualHint =>
      'This URL is not a script file. Open the update page and import it manually.';

  @override
  String get sourcesImportFromFile => 'Import from file';

  @override
  String get sourcesImportFromFileSubtitle =>
      'Choose an LX Music source script (.js)';

  @override
  String get sourcesImportFromText => 'Paste script';

  @override
  String get sourcesImportFromTextSubtitle =>
      'Paste the full script from the clipboard';

  @override
  String get sourcesImportFromUrl => 'Import from URL';

  @override
  String get sourcesImportFromUrlSubtitle => 'Download a script from a link';

  @override
  String get sourcesDefaultQuality => 'Default quality';

  @override
  String get sourcesQualityHiRes => 'Hi-Res';

  @override
  String get sourcesQualityLossless => 'Lossless';

  @override
  String get sourcesQualityWav => 'WAV';

  @override
  String get sourcesQualityApe => 'APE';

  @override
  String get sourcesQuality320k => '320K';

  @override
  String get sourcesQuality192k => '192K';

  @override
  String get sourcesQuality128k => '128K';

  @override
  String get sourcesQualityHint =>
      'Play at this quality when available; fall back automatically otherwise';

  @override
  String get sourcesSortTitle => 'Channel order';

  @override
  String get sourcesSortReset => 'Reset';

  @override
  String get sourcesSortResetSubtitle =>
      'Restore the default order: script sources first, built-in platforms after';

  @override
  String get sourcesSortHint =>
      'Discover and search follow this order; new channels go to the end, and disabled channels disappear.';

  @override
  String get sourcesChannelDisabled => 'Disabled';

  @override
  String get sourcesNoSearchableSources =>
      'No searchable sources yet. Enable a source script to list searchable platforms here.';

  @override
  String get sourcesKindLx => 'Script source';

  @override
  String get sourcesKindBuiltin => 'Built-in platform';

  @override
  String sourcesImportedScripts(int count) {
    return 'Imported scripts ($count)';
  }

  @override
  String get sourcesNoScripts =>
      'No source scripts imported yet. Community sources can be found on GitHub by searching for “lx-music-source”.';

  @override
  String sourcesScriptByAuthor(String author) {
    return 'by $author';
  }

  @override
  String get sourcesScriptActions => 'Source script actions';

  @override
  String get sourcesEnable => 'Enable';

  @override
  String get sourcesDisable => 'Disable';

  @override
  String sourcesActivated(String name) {
    return 'Source enabled: $name';
  }

  @override
  String sourcesActivateFailed(String error) {
    return 'Failed to enable: $error';
  }

  @override
  String get sourcesDeleteScriptTitle => 'Delete source script';

  @override
  String sourcesDeleteScriptConfirm(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get sourcesDisclaimerTitle => 'Import source script';

  @override
  String get sourcesDisclaimerBody =>
      'Source scripts are executable code from third parties; once imported they run on this device and can access the network.\nOnly import scripts from trusted sources. Their availability and legality are the provider’s responsibility.';

  @override
  String get sourcesContinueImport => 'Continue import';

  @override
  String sourcesImportFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get sourcesPasteTitle => 'Paste source script';

  @override
  String get sourcesPasteHint => 'Paste the full source script';

  @override
  String get sourcesImportAction => 'Import';

  @override
  String get sourcesDownloadAndImport => 'Download & import';

  @override
  String get searchFailed => 'Search failed';

  @override
  String get searchNoSourcesTitle => 'No sources available';

  @override
  String get searchNoSourcesHint =>
      'Import and enable a source in Source Management, or select an available source.';

  @override
  String searchNoResultsInSource(String source) {
    return 'No results found in “$source”';
  }

  @override
  String get searchKindSongs => 'Songs';

  @override
  String get searchKindArtists => 'Artists';

  @override
  String get searchKindLyrics => 'Lyrics';

  @override
  String get searchLoadMore => 'Load more';

  @override
  String searchLoadMoreWithTotal(int total) {
    return 'Load more ($total tracks)';
  }

  @override
  String get languageSettingTitle => 'App Language';

  @override
  String get languageSettingSubtitle => 'Change the interface display language';

  @override
  String get languageSystem => 'System default';

  @override
  String get recentlyPlayedEmpty =>
      'Albums and playlists you listen to will show up here.';

  @override
  String get libraryRecentPlays => 'Recent Plays';

  @override
  String get libraryPlaylists => 'My Playlists';

  @override
  String get libraryImportFavorites => 'Import Favorites';

  @override
  String get libraryImportFavoritesSubtitle =>
      'Import a favorites list exported from LX Music (.lxmc)';

  @override
  String libraryImportSuccess(int count) {
    return 'Imported $count tracks';
  }

  @override
  String libraryImportFailed(String reason) {
    return 'Import failed: $reason';
  }

  @override
  String get libraryImportUnsupported =>
      'Importing .lxmc favorites is not supported on this platform';

  @override
  String get libraryImportNoTracks => 'No importable tracks found in the file';

  @override
  String get historyClear => 'Clear history';

  @override
  String get historyClearConfirm =>
      'Clear all play history? This cannot be undone.';

  @override
  String get historyEmpty => 'No play history yet';

  @override
  String get favoriteAdd => 'Add to favorites';

  @override
  String get favoriteRemove => 'Remove from favorites';

  @override
  String get favoritesPlaylistName => 'Favorites';

  @override
  String get favoritesLabel => 'Favorites';

  @override
  String get favoritesEmpty => 'No favorites yet';

  @override
  String get favoritesSearchHint => 'Search songs';

  @override
  String get favoritesSearchEmpty => 'No matching tracks';

  @override
  String get favoritesSwitchTitle => 'Switch collection';

  @override
  String get shufflePlay => 'Shuffle';

  @override
  String get sortTooltip => 'Sort';

  @override
  String get trackActionsTooltip => 'Track actions';

  @override
  String get sortDefaultOrder => 'Default order';

  @override
  String get tableColumnArtist => 'Artist';

  @override
  String get tableColumnAlbum => 'Album';

  @override
  String get tableColumnPlayedAt => 'Played at';

  @override
  String get tableColumnDuration => 'Duration';

  @override
  String get viewAllResults => 'View all results';

  @override
  String get sortByTitle => 'Title';

  @override
  String get sortByArtist => 'Artist';

  @override
  String get playAll => 'Play all';

  @override
  String get playAllShuffled => 'Shuffle all';

  @override
  String get nextTrackTooltip => 'Next track';

  @override
  String get previousTrackTooltip => 'Previous track';

  @override
  String get playerBarVolume => 'Volume';

  @override
  String playerBarVolumePercent(int percent) {
    return '$percent%';
  }

  @override
  String get playerBarMute => 'Mute';

  @override
  String get playerBarUnmute => 'Unmute';

  @override
  String get playerBarQueue => 'Queue';

  @override
  String get queuePanelNowPlaying => 'Playing';

  @override
  String get windowMinimize => 'Minimize';

  @override
  String get windowMaximize => 'Maximize';

  @override
  String get windowRestore => 'Restore';

  @override
  String get windowClose => 'Close';

  @override
  String get playlistEmpty =>
      'No playlists yet. Create one or import an LX Music favorites file.';

  @override
  String get playlistTracksEmpty => 'This playlist has no tracks yet';

  @override
  String playlistTrackCount(int count) {
    return '$count tracks';
  }

  @override
  String get playlistDelete => 'Delete playlist';

  @override
  String playlistDeleteConfirm(String name) {
    return 'Delete “$name”?';
  }

  @override
  String get playlistRemoveTrack => 'Remove from playlist';

  @override
  String get playlistCreate => 'New playlist';

  @override
  String get playlistCreateConfirm => 'Create';

  @override
  String get playlistCreateHint => 'Playlist name';

  @override
  String get playlistNameRequired => 'Enter a playlist name';

  @override
  String get playlistNameExists => 'A playlist with this name already exists';

  @override
  String get playlistRename => 'Rename playlist';

  @override
  String get addToPlaylist => 'Add to playlist';

  @override
  String get playlistReorder => 'Reorder';

  @override
  String get playlistReorderHint => 'Long-press and drag to reorder';

  @override
  String get playlistReorderDone => 'Done';

  @override
  String get selectAllItems => 'Select all';

  @override
  String get historyDeleteEntry => 'Delete entry';

  @override
  String get sourceSwap => 'Change source';

  @override
  String get sourceSwapSearching => 'Searching other sources…';

  @override
  String get sourceSwapEmpty => 'No match found in other sources';

  @override
  String get sourceSwapNoSources => 'No other sources available';

  @override
  String sourceSwapFailedSources(int count) {
    return '$count source(s) failed to search';
  }

  @override
  String get sourceSwapConfirm => 'Change source';

  @override
  String get sourceSwapPreviewContext => 'Source preview';

  @override
  String get sourceSwapDuplicateTitle => 'Track already exists';

  @override
  String get sourceSwapDuplicateMessage =>
      'This song is already in the list. Changing the source replaces the existing version.';

  @override
  String get sourceSwapDone => 'Source changed';

  @override
  String get sourceSwapQueueFollowed => 'Source changed and playback switched';

  @override
  String get sourceSwapNotFound =>
      'The track is no longer in its original place';

  @override
  String get sourceSwapApplyFailed =>
      'Failed to change source, please try again';

  @override
  String get sourceSwapTabLyrics => 'Lyrics';

  @override
  String get sourceSwapTabAudio => 'Audio';

  @override
  String playlistAddedTo(String name) {
    return 'Added to “$name”';
  }

  @override
  String get playlistAlreadyContains => 'Already in playlist';

  @override
  String get playlistImportToMine => 'Import to my playlists';

  @override
  String get playlistImportFromFile => 'Import from .lxmc file';

  @override
  String get playlistImportFromLink => 'Import from playlist link';

  @override
  String get playlistImportChannel => 'Platform';

  @override
  String get playlistImportEmpty => 'Playlist has no importable tracks';

  @override
  String get playlistImportedName => 'Imported playlist';

  @override
  String get discoverSectionTitle => 'Discover';

  @override
  String get discoverLeaderboards => 'Charts';

  @override
  String get discoverPlaylists => 'Playlists';

  @override
  String get discoverHotSearches => 'Trending';

  @override
  String get discoverOpenPlaylist => 'Open playlist';

  @override
  String get discoverOpenPlaylistHint => 'Paste a playlist link or ID';

  @override
  String get discoverOpen => 'Open';

  @override
  String get discoverPlaylistSearchHint => 'Search playlists';

  @override
  String get discoverHotTags => 'Popular tags';

  @override
  String get discoverAll => 'All';

  @override
  String get discoverAllTags => 'All tags';

  @override
  String get discoverLoadMore => 'Load more';

  @override
  String get discoverLoadFailed => 'Failed to load';

  @override
  String get discoverRetry => 'Retry';

  @override
  String get discoverNoContent => 'Nothing here yet';

  @override
  String get discoverSearchEmpty => 'No playlists found';

  @override
  String discoverPlaylistAuthor(String author) {
    return 'by $author';
  }

  @override
  String get discoverAddToPlaylist => 'Add to playlist';

  @override
  String get discoverNoPlaylists =>
      'No playlists yet. Favorite a song first to create one.';

  @override
  String discoverPlayCount(String count) {
    return '$count plays';
  }

  @override
  String get albumEmpty => 'No tracks in this album';

  @override
  String get albumLoadFailed => 'Failed to load album';

  @override
  String get artistEmpty => 'No tracks for this artist';

  @override
  String get artistLoadFailed => 'Failed to load artist';

  @override
  String get artistNotFound => 'Artist not found';

  @override
  String get unknownArtist => 'Unknown artist';

  @override
  String artistSongCount(int count) {
    return '$count songs';
  }

  @override
  String albumYear(int year) {
    return '$year';
  }

  @override
  String get settingsAppTitle => 'App name';

  @override
  String get settingsAppTitleSubtitle =>
      'Shown in the top bar when nothing is playing';

  @override
  String get settingsAppTitleDialogTitle => 'App name';

  @override
  String get settingsAppTitleHint => 'Enter a name';

  @override
  String get appName => 'Molia';

  @override
  String get libraryRecentContexts => 'Recently Played';

  @override
  String get libraryHistory => 'Play History';

  @override
  String get libraryLocalSongs => 'Local tracks';

  @override
  String get libraryImportLocalSongs => 'Import local tracks';

  @override
  String libraryImportLocalSongsDone(int count) {
    return 'Imported $count tracks';
  }

  @override
  String libraryImportLocalSongsSkipped(int imported, int skipped) {
    return 'Imported $imported tracks, $skipped skipped';
  }

  @override
  String get localSongsEmpty => 'No local tracks yet';

  @override
  String get localSongsRemove => 'Remove from list';

  @override
  String get localSongsRemoveConfirm =>
      'Removes the entry only; the original file is kept.';

  @override
  String get libraryListEnd => '— End —';

  @override
  String get settingsCacheTitle => 'Cache management';

  @override
  String get settingsCacheSubtitle =>
      'Audio, lyric and artwork usage and cleanup rules';

  @override
  String get cachePartitionAudio => 'Audio cache';

  @override
  String get cachePartitionLyrics => 'Lyrics cache';

  @override
  String get cachePartitionArtwork => 'Artwork cache';

  @override
  String cacheUsage(String size, int count) {
    return '$size · $count items';
  }

  @override
  String get cacheUsageComputing => 'Calculating…';

  @override
  String get cachePolicyAudioEnabled => 'Cache audio while playing';

  @override
  String get cachePolicyAudioScope => 'Cache what you play';

  @override
  String get cachePolicyAudioHint =>
      'Songs are cached as they play, so they can play offline or be saved as downloads; the oldest cache is cleared when the limit is reached.';

  @override
  String get cachePolicyAudioMax => 'Size limit';

  @override
  String get cachePolicyLyricsTtl => 'Keep lyrics for';

  @override
  String get cachePolicyArtworkMax => 'Max artwork objects';

  @override
  String get cachePolicyArtworkStale => 'Expire artwork after';

  @override
  String get cacheUnlimited => 'Unlimited';

  @override
  String get cacheNeverExpire => 'Never';

  @override
  String cacheValueMb(int value) {
    return '$value MB';
  }

  @override
  String cacheValueGb(int value) {
    return '$value GB';
  }

  @override
  String cacheValueDays(int value) {
    return '$value days';
  }

  @override
  String cacheValueItems(int value) {
    return '$value';
  }

  @override
  String get cacheUnitMb => 'MB';

  @override
  String get cacheUnitDays => 'days';

  @override
  String get cacheUnitItems => 'items';

  @override
  String cacheCustomHint(String label, int min, int max) {
    return '0 = $label · Range $min–$max';
  }

  @override
  String cacheAudioMaxSuggested(String value) {
    return 'Suggested: $value';
  }

  @override
  String cacheCustomRangeError(int min, int max) {
    return 'Enter an integer between $min and $max';
  }

  @override
  String get cacheClearPartition => 'Clear';

  @override
  String get cacheClearAll => 'Clear all caches';

  @override
  String get cacheClearAllConfirm =>
      'Clear all caches (audio, lyrics and artwork)? This cannot be undone.';

  @override
  String get lyricsContentTitle => 'Lyrics & outputs';

  @override
  String get lyricsContentSubtitle =>
      'Lyrics page, translation, offset and shared options';

  @override
  String get lyricsPageTitle => 'Lyrics page';

  @override
  String get lyricsPageTranslationSubtitle =>
      'Show translation under each line in the lyrics page';

  @override
  String get lyricsPageRomaSubtitle =>
      'Show romanization under each line in the lyrics page';

  @override
  String get lyricsDisplaySharedTitle => 'Lyric outputs';

  @override
  String get lyricsDisplayTranslation => 'Translation';

  @override
  String get lyricsDisplayTranslationSubtitle =>
      'Show translation in floating, notification and Bluetooth lyrics';

  @override
  String get lyricsDisplayRoma => 'Romanization';

  @override
  String get lyricsDisplayRomaSubtitle =>
      'Show romanization in floating, notification and Bluetooth lyrics';

  @override
  String get lyricsDisplayUnsynced => 'Unsynced lyrics';

  @override
  String get lyricsDisplayUnsyncedTitle => 'Show song title';

  @override
  String get lyricsDisplayUnsyncedHide => 'Hide';

  @override
  String get lyricsDisplayUnsyncedFirstLine => 'Show first line';

  @override
  String get lyricsDisplayOffset => 'Lyric offset';

  @override
  String lyricsDisplayOffsetValue(int ms) {
    return '$ms ms';
  }

  @override
  String get lyricsDesktopTitle => 'Floating lyrics';

  @override
  String get lyricsDesktopEntrySubtitle =>
      'Floating window style, behavior and colors';

  @override
  String get lyricsDesktopEnable => 'Enable floating lyrics';

  @override
  String get lyricsDesktopEnableSubtitle =>
      'Show the current line above other apps';

  @override
  String get lyricsDesktopPermissionNeeded => 'Overlay permission required';

  @override
  String get lyricsDesktopPermissionGrant => 'Grant';

  @override
  String get lyricsDesktopPreview => 'Style preview';

  @override
  String get lyricsDesktopPreviewLine => 'I can\'t just be an ordinary friend';

  @override
  String get lyricsDesktopPreviewTranslation => '我无法只是普通朋友';

  @override
  String get lyricsDesktopFontSize => 'Font size';

  @override
  String get lyricsDesktopOpacity => 'Opacity';

  @override
  String get lyricsDesktopWidth => 'Width';

  @override
  String get lyricsDesktopMaxLines => 'Visible lines';

  @override
  String get lyricsDesktopAlign => 'Horizontal align';

  @override
  String get lyricsDesktopAlignLeft => 'Left';

  @override
  String get lyricsDesktopAlignCenter => 'Center';

  @override
  String get lyricsDesktopAlignRight => 'Right';

  @override
  String get lyricsDesktopColorPlayed => 'Current line color';

  @override
  String get lyricsDesktopColorUnplayed => 'Other lines color';

  @override
  String get lyricsDesktopColorShadow => 'Shadow color';

  @override
  String get lyricsDesktopSchemeSource => 'Color source';

  @override
  String get lyricsDesktopSchemeAppTheme => 'Follow app theme';

  @override
  String get lyricsDesktopSchemeArtwork => 'Follow album art';

  @override
  String get lyricsDesktopLock => 'Lock position (mouse clicks pass through)';

  @override
  String get lyricsDesktopFreeze => 'Pause updates while the screen is off';

  @override
  String get lyricsDesktopPauseBehavior => 'When paused';

  @override
  String get lyricsDesktopHideOnPause => 'Hide when paused';

  @override
  String get lyricsDesktopHideOnPauseSubtitle =>
      'Collapse the floating window while paused; it returns when playback resumes';

  @override
  String get lyricsDesktopPauseFallbackOverridden =>
      'The whole window is hidden while paused, so this setting has no effect';

  @override
  String get lyricsDesktopNoLyrics => 'Without lyrics';

  @override
  String get lyricsDesktopAnimation => 'Line transition animation';

  @override
  String get lyricsDesktopScrollMode => 'Long line scrolling';

  @override
  String get lyricsDesktopScrollModeSubtitle =>
      'Follow singing: text moves with the highlight; Constant: scrolls at a steady speed';

  @override
  String get lyricsDesktopScrollFollow => 'Follow singing';

  @override
  String get lyricsDesktopScrollConstant => 'Constant speed';

  @override
  String get lyricsDesktopBehaviorSection => 'Behavior & controls';

  @override
  String get lyricsSharedDisplaySection => 'Lyric display';

  @override
  String get lyricsDesktopResetPosition => 'Reset position';

  @override
  String get lyricsControlPlayPause => 'Play / pause';

  @override
  String get lyricsControlPrevious => 'Previous';

  @override
  String get lyricsControlNext => 'Next';

  @override
  String get lyricsControlTranslation => 'Translation';

  @override
  String get lyricsControlLock => 'Lock';

  @override
  String get lyricsControlClose => 'Close';

  @override
  String get lyricsSystemMediaTitle => 'System media lyrics';

  @override
  String get lyricsSystemMediaSubtitle =>
      'Notification, lock screen and Bluetooth';

  @override
  String get lyricsBehaviorKeep => 'Keep';

  @override
  String get lyricsBehaviorTitle => 'Song title';

  @override
  String get lyricsBehaviorClear => 'Clear';

  @override
  String get lyricsNotificationTitle => 'Notification & lock screen';

  @override
  String get lyricsNotificationEnable => 'Show lyrics in notification';

  @override
  String get lyricsNotificationEnableSubtitle =>
      'Sync the current lyric to system playback controls';

  @override
  String get lyricsMetadataTarget => 'Show in';

  @override
  String get lyricsMetadataTargetSubtitle => 'Subtitle';

  @override
  String get lyricsMetadataTargetArtist => 'Artist';

  @override
  String get lyricsMetadataTargetTitle => 'Title';

  @override
  String get lyricsMetadataTargetAlbum => 'Album';

  @override
  String get lyricsMetadataFormat => 'Format';

  @override
  String get lyricsMetadataFormatLyric => 'Lyrics only';

  @override
  String get lyricsMetadataFormatLyricTitle => 'Lyrics · title';

  @override
  String get lyricsMetadataFormatTitleLyric => 'Title · lyrics';

  @override
  String get lyricsMetadataIncludeTranslation => 'Include translation';

  @override
  String get lyricsMetadataPauseBehavior => 'When paused';

  @override
  String get lyricsBluetoothTitle => 'Bluetooth lyrics';

  @override
  String get lyricsBluetoothEnable => 'Show lyrics on car display';

  @override
  String get lyricsBluetoothEnableSubtitle =>
      'Show the current lyric on the car head unit, notification shade and lock screen';

  @override
  String get lyricsBluetoothOnlyA2dp =>
      'Only while Bluetooth audio is connected';

  @override
  String get lyricsBluetoothStatusConnected => 'Bluetooth audio connected';

  @override
  String get lyricsBluetoothStatusDisconnected =>
      'Bluetooth audio not connected';

  @override
  String get lyricsBluetoothUpdateInterval => 'Update interval';

  @override
  String get lyricsBluetoothIntervalLine => 'Every line';

  @override
  String get lyricsBluetoothInterval1s => 'Every second';

  @override
  String get lyricsBluetoothInterval2s => 'Every 2 seconds';

  @override
  String get lyricsNotificationPermissionTitle =>
      'Notification permission needed';

  @override
  String get lyricsNotificationPermissionSubtitle =>
      'Allow notifications so media controls can stay visible; tap to open system settings';

  @override
  String get lyricsMediaSessionUnavailable =>
      'System media controls failed to start: notification/lock-screen lyrics and playback controls are unavailable';

  @override
  String get lyricsDisplayUnsupported =>
      'Lyric outputs are not available on this platform';

  @override
  String get colorPickerTitle => 'Pick a color';

  @override
  String get colorPickerCustom => 'Custom color…';

  @override
  String get colorPickerHex => 'Hex color';

  @override
  String get colorPickerInvalid => 'Invalid color value';

  @override
  String get colorPickerHue => 'Hue';

  @override
  String get colorPickerSaturation => 'Saturation';

  @override
  String get colorPickerBrightness => 'Brightness';

  @override
  String get colorPickerOpacity => 'Opacity';

  @override
  String get lyricsColorSource => 'Color';

  @override
  String get lyricsColorSourceCustom => 'Custom';

  @override
  String get lyricsColorSourcePrimary => 'Primary';

  @override
  String get lyricsColorSourceSecondary => 'Secondary';

  @override
  String get lyricsColorSourceTertiary => 'Tertiary';

  @override
  String get lyricsColorSourceOnSurface => 'On surface';

  @override
  String get lyricsColorSourceOnSurfaceVariant => 'Variant';

  @override
  String get lyricsColorSourceSurface => 'Surface';

  @override
  String get lyricsDesktopColorThemeHint =>
      '“Follow app theme” changes with the appearance settings; “Follow artwork” picks colors from the current song and updates live.';

  @override
  String get statsTitle => 'Listening Stats';

  @override
  String get statsSubtitle =>
      'Play counts, listening time, and activity heatmaps (stored on this device only)';

  @override
  String get statsSettingsSubtitle => 'Plays / activity heatmaps / export';

  @override
  String get statsRecordSwitch => 'Record listening stats';

  @override
  String get statsRecordSwitchSubtitle =>
      'Turn off to stop recording new plays; existing data is kept';

  @override
  String get statsRangeWeek => '7 days';

  @override
  String get statsRangeMonth => '30 days';

  @override
  String get statsRangeAll => 'All';

  @override
  String get statsRangeTitle => 'Time range';

  @override
  String get statsValueDuration => 'Time';

  @override
  String get statsValueCount => 'Plays';

  @override
  String get statsPlays => 'Valid plays';

  @override
  String get statsListened => 'Listening time';

  @override
  String get statsTracks => 'Tracks played';

  @override
  String get statsSince => 'Since';

  @override
  String get statsCompleteRate => 'Completion rate';

  @override
  String get statsSkipRate => 'Skip rate';

  @override
  String get statsSources => 'Sources';

  @override
  String get statsTopTracks => 'Most played';

  @override
  String get statsTopArtists => 'Top artists';

  @override
  String get statsEmpty => 'No listening history yet';

  @override
  String get statsEmptyHint => 'Play some songs and come back';

  @override
  String get statsExport => 'Export listening data';

  @override
  String statsExportSubtitle(int limit) {
    return 'JSON file (summary + last $limit events)';
  }

  @override
  String get statsExportFailed => 'Export failed';

  @override
  String get statsClear => 'Clear stats';

  @override
  String get statsClearConfirm =>
      'This will delete all listening stat events. This cannot be undone.';

  @override
  String get statsCleared => 'Listening stats cleared';

  @override
  String statsPlaysCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count plays',
      one: '1 play',
    );
    return '$_temp0';
  }

  @override
  String statsDurationSeconds(int count) {
    return '$count s';
  }

  @override
  String statsDurationMinutes(int count) {
    return '$count min';
  }

  @override
  String statsDurationHours(int hours, int minutes) {
    return '$hours h $minutes min';
  }

  @override
  String statsDaySummary(int count, String duration) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count plays',
      one: '1 play',
    );
    return '$_temp0 · $duration';
  }

  @override
  String statsTooltip(String date, String value) {
    return '$date · $value';
  }

  @override
  String statsEventListened(String duration) {
    return 'Listened $duration';
  }

  @override
  String get aiDjTitle => 'AI DJ';

  @override
  String get aiDjSettingsSubtitle => 'AI radio with your own key';

  @override
  String get aiDjNotConfigured => 'AI service is not configured yet';

  @override
  String get aiDjRequestFailed => 'AI request failed. Try again later.';

  @override
  String get aiDjUnauthorized => 'Invalid API key or permission denied';

  @override
  String get aiDjRateLimited => 'Rate limited. Try again later.';

  @override
  String get aiDjBadResponse => 'The AI response could not be parsed';

  @override
  String get aiDjNothingResolved => 'No playable tracks in this batch';

  @override
  String get aiDjStatusOff => 'Off';

  @override
  String get aiDjStatusPreparing => 'Preparing…';

  @override
  String get aiDjStatusPlaying => 'Live';

  @override
  String get aiDjStatusError => 'Paused (queue kept)';

  @override
  String get aiDjToggle => 'AI DJ mode';

  @override
  String get aiDjToggleSubtitle =>
      'AI keeps picking songs into the queue and continues when it ends';

  @override
  String get aiDjFeedMore => 'More';

  @override
  String get aiDjStopKeepQueue => 'Keep playing';

  @override
  String get aiDjStopClearQueue => 'Clear queue & stop';

  @override
  String get aiDjStopDialogTitle => 'Exit AI DJ?';

  @override
  String get aiDjConsentTitle => 'Before you start';

  @override
  String get aiDjConsentBody =>
      'When enabled, your listening profile (stats summary, the latest 50 plays, and songs already heard) is sent to the AI service you configure to generate recommendations. Data goes directly to that service, not through this app, and no built-in key is provided.\nTurning the mode off stops recommendations; clearing the config disconnects it.';

  @override
  String get aiDjAgree => 'Agree & start';

  @override
  String get aiDjConfigTitle => 'AI service';

  @override
  String get aiDjBaseUrl => 'Base URL';

  @override
  String get aiDjApiKey => 'API key';

  @override
  String get aiDjModel => 'Model';

  @override
  String get aiDjPresetCustom => 'Custom';

  @override
  String get aiDjTestConnection => 'Test connection';

  @override
  String get aiDjTestSucceeded => 'Connected';

  @override
  String get aiDjTestSaved => 'Connected — config saved';

  @override
  String get aiDjSaveConfig => 'Save';

  @override
  String get aiDjClearConfig => 'Clear';

  @override
  String get aiDjConfigSaved => 'Saved';

  @override
  String aiDjQueued(int count) {
    return '$count recommendations left in the queue';
  }

  @override
  String aiDjSkippedCount(int count) {
    return '$count skipped';
  }

  @override
  String aiDjLikedCount(int count) {
    return '$count liked';
  }

  @override
  String aiDjUnresolved(int count) {
    return '$count not found on your sources';
  }

  @override
  String get aiDjRetry => 'Retry';

  @override
  String get aiDjOpenSettings => 'Set up AI service';

  @override
  String get aiDjDiscoverSubtitle =>
      'Let AI pick songs from your listening history';

  @override
  String get aiDjGenerating => 'Generating recommendations…';

  @override
  String get aiDjBatchFailed => 'Couldn\'t generate a batch';

  @override
  String get aiDjRefreshBatch => 'New batch';

  @override
  String get aiDjStatusIdle => 'Idle';

  @override
  String get aiDjTodayTitle => 'Today\'s picks';

  @override
  String get aiDjViewAll => 'View all';

  @override
  String aiDjLastUpdated(String time) {
    return 'Updated $time';
  }

  @override
  String get aiDjUpdatedJustNow => 'just now';

  @override
  String aiDjUpdatedMinutesAgo(int count) {
    return '$count min ago';
  }

  @override
  String aiDjUpdatedHoursAgo(int count) {
    return '$count h ago';
  }

  @override
  String aiDjUpdatedYesterday(String time) {
    return 'yesterday $time';
  }

  @override
  String aiDjUpdatedDate(int month, int day) {
    return '$month/$day';
  }

  @override
  String get aiDjPlayAll => 'Play all';

  @override
  String get aiDjEnqueueAll => 'Add to queue';

  @override
  String get aiDjInQueue => 'In queue';

  @override
  String get aiDjItemActions => 'Recommendation actions';

  @override
  String get aiDjReplaceItem => 'Swap this one';

  @override
  String get aiDjNotInterested => 'Not interested';

  @override
  String get aiDjFeedbackTitle => 'This round';

  @override
  String get aiDjFeedbackLiked => 'Liked';

  @override
  String get aiDjFeedbackSkipped => 'Skipped';

  @override
  String get aiDjUpstreamTitle => 'Data sent this time';

  @override
  String aiDjUpstreamBody(int events, int artists, int exclusions) {
    return 'Latest $events plays · $artists frequent artists · $exclusions already-heard songs excluded';
  }

  @override
  String get aiDjUpstreamHint =>
      'Only the stats above plus song and artist names — no play links or device information.';

  @override
  String get aiDjGenerate => 'Generate';

  @override
  String get aiDjEmptyList => 'No recommendations yet';

  @override
  String get aiDjEmptyListHint =>
      'Generate today\'s picks — playable any time.';

  @override
  String get aiDjEnqueueEmpty => 'Everything here is already queued';

  @override
  String get aiDjPreferencesTitle => 'Recommendation preferences';

  @override
  String get aiDjPreferencesSubtitle => 'Styles, scenes and what gets sent';

  @override
  String aiDjBatchSize(int count) {
    return '$count per batch';
  }

  @override
  String get aiDjBatchSizeTitle => 'Batch size';

  @override
  String get aiDjFeedBatch => 'Add a batch to the queue';

  @override
  String get aiDjSectionsNone => 'Preferences only';

  @override
  String get aiDjFeedDone => 'Batch added to the queue';

  @override
  String get aiDjUnresolvedRetried => 'Searched again';

  @override
  String get aiDjHistoryTitle => 'Recommendation history';

  @override
  String aiDjHistoryEntry(int count) {
    return 'History ($count)';
  }

  @override
  String get aiDjHistoryEmpty => 'No batch history yet';

  @override
  String get aiDjHistoryEmptyHint => 'Every generated batch is kept here.';

  @override
  String get aiDjHistoryPlay => 'Play this batch';

  @override
  String get aiDjHistoryEnqueue => 'Add to queue';

  @override
  String get aiDjHistorySetActive => 'Set as current';

  @override
  String get aiDjHistoryDelete => 'Delete this batch';

  @override
  String get aiDjHistoryActive => 'Current';

  @override
  String get aiDjHistoryClear => 'Clear history';

  @override
  String get aiDjHistoryClearTitle => 'Clear recommendation history?';

  @override
  String get aiDjHistoryClearBody =>
      'Only history records are removed; the playing queue is not affected. The current batch is kept.';

  @override
  String get aiDjHistoryCleared => 'Recommendation history cleared';

  @override
  String get aiDjHistoryExpand => 'View tracks';

  @override
  String get aiDjHistoryCollapse => 'Hide tracks';

  @override
  String aiDjHistoryItems(int count) {
    return '$count tracks';
  }

  @override
  String aiDjHistoryUnresolved(int count) {
    return '$count not found';
  }

  @override
  String aiDjHistorySource(String origin) {
    return 'From $origin';
  }

  @override
  String get aiDjOriginRefresh => 'a refresh';

  @override
  String get aiDjOriginAutoFeed => 'auto-feed';

  @override
  String get aiDjOriginManualFeed => 'a manual top-up';

  @override
  String get aiDjOriginRestored => 'older picks';

  @override
  String get aiDjHistoryLoadFailed =>
      'This batch is damaged and cannot be opened';

  @override
  String get aiDjMoreLikeThis => 'More like this';

  @override
  String get aiDjRetryUnresolved => 'Search again';

  @override
  String get aiDjTransparencyTitle => 'What gets sent to AI';

  @override
  String get aiDjViewPrompt => 'View exact prompt';

  @override
  String get aiDjSystemPrompt => 'System prompt';

  @override
  String get aiDjUserPrompt => 'User prompt';

  @override
  String get aiDjCopyPrompt => 'Copy';

  @override
  String get aiDjPromptCopied => 'Copied';

  @override
  String get aiDjPromptTabPreview => 'This batch';

  @override
  String get aiDjPromptTabLastSent => 'Last sent';

  @override
  String get aiDjPromptTabLastRaw => 'Last reply';

  @override
  String get aiDjPromptUnavailable => 'Preview isn\'t available right now';

  @override
  String get aiDjLastSentPrompt => 'Last prompt sent';

  @override
  String get aiDjLastRawResponse => 'Last AI response';

  @override
  String get aiDjNoLastPrompt => 'Nothing sent yet';

  @override
  String get aiDjNoLastResponse => 'No response yet';

  @override
  String get aiDjPromptPrivacyHint =>
      'No play links, device information or API key.';

  @override
  String aiDjSendSummary(String sections) {
    return 'Sending: $sections';
  }

  @override
  String get aiDjAutoFeedTitle => 'Auto-fill near the end of the queue';

  @override
  String get aiDjAutoFeedSubtitle =>
      'Adds a batch automatically with 5 tracks left, without interrupting playback';

  @override
  String get aiDjAutoFeedFailed => 'Auto-fill failed; it will retry later';

  @override
  String aiDjAutoFeedHalted(int count) {
    return 'Auto-fill paused after $count failures in a row';
  }

  @override
  String get aiDjAutoFeedResume => 'Resume auto-fill';

  @override
  String get aiDjGenerationStatus => 'Generating recommendations';

  @override
  String get aiDjPhaseProfile => 'Reading your taste';

  @override
  String get aiDjPhaseModel => 'AI is picking songs';

  @override
  String aiDjPhaseResolving(int done, int total) {
    return 'Finding songs $done/$total';
  }

  @override
  String aiDjWaitingSeconds(int seconds) {
    return 'Waiting ${seconds}s';
  }

  @override
  String get aiDjCancelGeneration => 'Stop';

  @override
  String get aiDjReplacing => 'Swapping…';

  @override
  String get aiDjPrefsGenerationGroup => 'Generation';

  @override
  String get aiDjPrefsStylesGroup => 'Styles';

  @override
  String get aiDjPrefsScenesGroup => 'Scenes';

  @override
  String get aiDjPrefsLanguagesGroup => 'Languages';

  @override
  String get aiDjPrefsEraGroup => 'Era';

  @override
  String get aiDjPrefsExtraGroup => 'Extra request';

  @override
  String get aiDjPrefsExtraHint =>
      'Up to 120 characters, sent to AI with your request';

  @override
  String get aiDjPrefsOnlyUnheardTitle => 'Only unheard tracks';

  @override
  String get aiDjPrefsOnlyUnheardSubtitle =>
      'Skip tracks you have already played';

  @override
  String get aiDjPrefsExplorationTitle => 'Exploration';

  @override
  String get aiDjExplorationSafe => 'Safe';

  @override
  String get aiDjExplorationBalanced => 'Balanced';

  @override
  String get aiDjExplorationSurprise => 'Surprise';

  @override
  String get aiDjStylePop => 'Pop';

  @override
  String get aiDjStyleRock => 'Rock';

  @override
  String get aiDjStyleElectronic => 'Electronic';

  @override
  String get aiDjStyleFolk => 'Folk';

  @override
  String get aiDjStyleRap => 'Rap';

  @override
  String get aiDjStyleRnb => 'R&B';

  @override
  String get aiDjStyleJazz => 'Jazz';

  @override
  String get aiDjStyleClassical => 'Classical';

  @override
  String get aiDjStyleMetal => 'Metal';

  @override
  String get aiDjStyleAcg => 'ACG';

  @override
  String get aiDjStyleInstrumental => 'Instrumental';

  @override
  String get aiDjStyleChineseStyle => 'Chinese style';

  @override
  String get aiDjSceneCommute => 'Commute';

  @override
  String get aiDjSceneFocus => 'Focus';

  @override
  String get aiDjSceneRelax => 'Relax';

  @override
  String get aiDjSceneWorkout => 'Workout';

  @override
  String get aiDjSceneSleep => 'Sleep';

  @override
  String get aiDjSceneWeekend => 'Weekend';

  @override
  String get aiDjLanguageMandarin => 'Mandarin';

  @override
  String get aiDjLanguageCantonese => 'Cantonese';

  @override
  String get aiDjLanguageEnglish => 'English';

  @override
  String get aiDjLanguageJapanese => 'Japanese';

  @override
  String get aiDjLanguageKorean => 'Korean';

  @override
  String get aiDjLanguageInstrumental => 'Instrumental';

  @override
  String get aiDjEraAny => 'Any';

  @override
  String get aiDjEraRecent3 => 'Last 3 years';

  @override
  String get aiDjEra2010s => '2010s';

  @override
  String get aiDjEra2000s => '2000s';

  @override
  String get aiDjEraBefore90 => 'Before the 90s';

  @override
  String get aiDjPrefsAutoSaveHint =>
      'Changes save automatically and apply to the next batch.';

  @override
  String get aiDjPrefsReset => 'Restore defaults';

  @override
  String get aiDjPrefsResetTitle => 'Restore default preferences?';

  @override
  String get aiDjPrefsResetBody =>
      'Styles, scenes and sending scope return to defaults; saved recommendations are not affected.';

  @override
  String get aiDjPrefsResetDone => 'Default preferences restored';

  @override
  String get aiDjPrefsDataScope => 'What gets sent';

  @override
  String get aiDjScopeHint =>
      'Unchecked items are not sent; favorites and playlists are off by default.';

  @override
  String get aiDjScopeSummary => 'Listening summary';

  @override
  String get aiDjScopeTopArtists => 'Frequent artists';

  @override
  String get aiDjScopeTopTracks => 'Frequent tracks';

  @override
  String get aiDjScopeTimeAndSource => 'Time and source breakdown';

  @override
  String get aiDjScopeRecentEvents => 'Recent plays';

  @override
  String get aiDjScopeListenedExclusions => 'Already-heard exclusion list';

  @override
  String get aiDjScopeFavorites => 'Favorite tracks';

  @override
  String get aiDjScopePlaylists => 'Your playlists';

  @override
  String get aiDjScopeFavoritesConfirm =>
      'This reads the titles and artists of up to 100 favorite tracks so they are not recommended again.';

  @override
  String get aiDjScopePlaylistsConfirm =>
      'This reads the names, titles and artists of up to 10 of your playlists so they are not recommended again.';

  @override
  String get aiDjSeedsTitle => 'More like these';

  @override
  String get aiDjSeedsHint => 'Cleared after the next successful batch';

  @override
  String get aiDjSeedsEmpty => 'No “More like this” picks yet';

  @override
  String get aiDjClearMemory => 'Clear AI memory';

  @override
  String get aiDjClearMemoryTitle => 'Clear AI memory?';

  @override
  String get aiDjClearMemoryBody =>
      'This deletes long-term “not interested”, “liked” and “more like these” entries. This round\'s feedback is cleared too.';

  @override
  String get aiDjMemoryCleared => 'AI memory cleared';

  @override
  String get aiDjFeedbackMemory => 'Long-term memory';

  @override
  String get aiDjFeedbackThisRound => 'This round';

  @override
  String aiDjSeedLabel(String label) {
    return 'More like · $label';
  }

  @override
  String get settingsSyncTitle => 'Cross-device sync';

  @override
  String get settingsSyncItemSubtitle =>
      'Playlists, sources, settings and keys';

  @override
  String get syncLocalSection => 'This device';

  @override
  String get syncLocalSectionHint =>
      'Other devices need this information to reach this device; these addresses are also used for nearby pairing.';

  @override
  String get syncDeviceNameTitle => 'Device name';

  @override
  String get syncPassphraseTitle => 'Sync passphrase';

  @override
  String get syncPassphraseNotSet => 'Not set';

  @override
  String get syncPassphraseTrustHint =>
      'Any device that knows the passphrase can read and write all synced data; reset it if leaked.';

  @override
  String get syncPassphraseCopy => 'Copy passphrase';

  @override
  String get syncPassphraseReset => 'Reset passphrase';

  @override
  String get syncPassphraseResetConfirm =>
      'All devices must re-enter the new passphrase. Continue?';

  @override
  String get syncPassphraseInvalid =>
      'Invalid passphrase (at least 16 characters)';

  @override
  String get syncSave => 'Save';

  @override
  String get syncNever => 'Never synced';

  @override
  String syncStatusSyncedPeers(int count) {
    return 'Synced with $count devices';
  }

  @override
  String get syncRelativeJustNow => 'just now';

  @override
  String syncRelativeMinutes(int count) {
    return '$count min ago';
  }

  @override
  String syncRelativeHours(int count) {
    return '$count h ago';
  }

  @override
  String syncRelativeDays(int count) {
    return '$count d ago';
  }

  @override
  String get syncOutcomeOk => 'Synced';

  @override
  String get syncOutcomeNoChanges => 'No changes';

  @override
  String get syncOutcomeNoPeers => 'No other device found';

  @override
  String get syncOutcomePartial => 'Partly failed';

  @override
  String get syncOutcomeFailed => 'Sync failed';

  @override
  String get syncTriggerStartup => 'startup';

  @override
  String get syncTriggerDebounce => 'data changed';

  @override
  String get syncTriggerTimer => 'scheduled';

  @override
  String get syncTriggerIncoming => 'sent by another device';

  @override
  String get syncTriggerResume => 'resumed';

  @override
  String get syncTriggerPause => 'before background';

  @override
  String get syncTriggerNetwork => 'network changed';

  @override
  String get syncTriggerDiscovery => 'device found';

  @override
  String get syncTriggerCheck => 'opened sync page';

  @override
  String get syncTriggerManual => 'manual';

  @override
  String get syncActivitySection => 'Activity';

  @override
  String get syncActivityTitle => 'Last 24 hours';

  @override
  String syncActivityRounds(int rounds, int effective, String bytes) {
    return '$rounds runs, $effective with changes · $bytes transferred';
  }

  @override
  String syncActivityEnvironment(
      String level, String network, String powerSave) {
    return '$level · $network · $powerSave';
  }

  @override
  String get syncLevelActive => 'active';

  @override
  String get syncLevelIdle => 'idle';

  @override
  String get syncLevelBackground => 'background';

  @override
  String get syncLevelPowerSave => 'power save';

  @override
  String get syncLevelUnknown => 'not running';

  @override
  String get syncNetworkCellular => 'cellular';

  @override
  String get syncNetworkOther => 'Wi-Fi / other';

  @override
  String get syncPowerSaveOn => 'power save on';

  @override
  String get syncPowerSaveOff => 'power save off';

  @override
  String get syncCellularSection => 'Cellular';

  @override
  String get syncCellularPauseTitle => 'Pause automatic sync on cellular';

  @override
  String get syncCellularPauseSubtitle =>
      'When off, mobile data syncs only small items (settings, playlists); stats and history wait for Wi-Fi';

  @override
  String syncAppliedItems(int applied) {
    return '$applied updated';
  }

  @override
  String syncPeerCount(int count) {
    return '$count devices';
  }

  @override
  String syncFailedCount(int count) {
    return '$count failures';
  }

  @override
  String syncBytes(String inbound, String outbound) {
    return '↓$inbound ↑$outbound';
  }

  @override
  String get syncRetry => 'Retry';

  @override
  String get syncContentSection => 'What to sync';

  @override
  String get syncContentAllOn => 'All categories';

  @override
  String syncContentOffCount(int count) {
    return '$count turned off';
  }

  @override
  String get syncCategoryPlaylists => 'Playlists & favorites';

  @override
  String get syncCategorySources => 'Sources (scripts & config)';

  @override
  String get syncCategorySettings => 'App settings';

  @override
  String get syncCategoryCovers => 'Custom covers';

  @override
  String get syncCategoryStatistics => 'Play statistics';

  @override
  String get syncCategoryHistory => 'Play history';

  @override
  String get syncCategorySession => 'Last playback state';

  @override
  String get syncCategoryCredentials => 'AI radio and keys';

  @override
  String get syncTransportSection => 'Transport';

  @override
  String get syncTransportAllOffHint =>
      'Sync does not run while both methods are off; turn one on to start.';

  @override
  String get syncLanTitle => 'LAN direct';

  @override
  String get syncWebdavTitle => 'WebDAV / cloud';

  @override
  String get syncWebdavConfigTitle => 'WebDAV settings';

  @override
  String get syncWebdavServer => 'Server URL';

  @override
  String get syncWebdavUsername => 'Username';

  @override
  String get syncWebdavPassword => 'Password';

  @override
  String get syncWebdavRemoteDir => 'Cloud folder';

  @override
  String get syncWebdavNotConfigured => 'Not configured';

  @override
  String get syncTransportRunning => 'running';

  @override
  String get syncTransportStopped => 'stopped';

  @override
  String get syncTransportDisabled => 'turned off';

  @override
  String get syncTransportNotConfigured => 'not configured';

  @override
  String get syncTransportStartFailed => 'failed to start';

  @override
  String get syncLogTitle => 'Sync log';

  @override
  String get syncLogSection => 'Sync log';

  @override
  String get syncLogEmpty => 'No records yet';

  @override
  String syncLogFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get syncAdvancedTitle => 'Advanced';

  @override
  String get syncAdvancedSubtitle =>
      'Device name, passphrase, and network addresses';

  @override
  String get syncPeersSection => 'Devices';

  @override
  String get syncPeersHint =>
      'Turn on LAN sync, then tap a device under Nearby devices to pair. If nothing appears, check LAN permission or use a manual address.';

  @override
  String get syncPeersEmptyTitle => 'No paired devices yet';

  @override
  String get syncPeersEmptySubtitle =>
      'Tap a device under Nearby devices, or add an address in Advanced settings';

  @override
  String get syncNearbySection => 'Nearby devices';

  @override
  String get syncNearbyTapToPair => 'Tap to pair';

  @override
  String get syncNearbyHasGroup =>
      'The other device is already in a sync group';

  @override
  String get syncNearbyLanOffTitle => 'LAN sync is off';

  @override
  String get syncNearbyLanOffHint =>
      'Turn on LAN sync above and nearby devices will appear here.';

  @override
  String get syncNearbySearching => 'Looking for nearby devices…';

  @override
  String get syncNearbySearchHint =>
      'Make sure the other device has Molia open and LAN sync on';

  @override
  String get syncNearbyRescan => 'Search again';

  @override
  String get syncNearbyEmptyTitle => 'No devices found';

  @override
  String get syncNearbyEmptyHint =>
      'Ask the other device to open Molia and turn on LAN sync';

  @override
  String get syncNearbyFooter =>
      'Only accept devices you know. Accepting lets the other device read all synced data (including keys). If nothing appears, add an address in Advanced settings.';

  @override
  String syncNearbyPairTitle(String name) {
    return 'Pair with “$name”';
  }

  @override
  String get syncNearbyContacting => 'Contacting the other device…';

  @override
  String get syncNearbyCodeLabel => 'Confirmation code';

  @override
  String get syncNearbyCheckCode =>
      'Check that the other device shows the same numbers';

  @override
  String get syncNearbyWaiting => 'Waiting for the other device to accept…';

  @override
  String get syncNearbyJoined => 'Joined the sync group';

  @override
  String get syncNearbySameGroup => 'Already in the same sync group';

  @override
  String get syncNearbyResultRejected =>
      'The other device rejected the request. You can try again later.';

  @override
  String get syncNearbyResultExpired =>
      'The pairing request expired. Tap the device to try again.';

  @override
  String get syncNearbyResultConflict =>
      'The devices are in different sync groups. Reset one device’s passphrase and try again.';

  @override
  String get syncNearbyResultUnreachable =>
      'Couldn’t reach the device. Make sure both devices are on the same network with LAN sync on.';

  @override
  String get syncNearbyResultBusy =>
      'The other device is handling another request. Try again shortly.';

  @override
  String get syncNearbyResultUnsupported =>
      'This device doesn’t support one-tap pairing yet. Update Molia and try again.';

  @override
  String get syncNearbyResultUnavailable =>
      'Pairing is unavailable. Make sure both devices have LAN sync on and try again.';

  @override
  String get syncNearbyResultCancelled =>
      'Pairing cancelled. Tap the device to try again.';

  @override
  String syncNearbyIncomingJoinTitle(String name) {
    return '“$name” wants to join your sync group';
  }

  @override
  String syncNearbyIncomingInviteTitle(String name) {
    return '“$name” invited you to join their sync group';
  }

  @override
  String get syncNearbyIncomingJoinWarning =>
      'If you accept, the other device can read all synced data (including scripts and keys). Only accept devices you know.';

  @override
  String get syncNearbyIncomingInviteWarning =>
      'Accepting joins their sync group and switches this device to their passphrase. The other device can then read all synced data (including scripts and keys).';

  @override
  String get syncNearbyAccept => 'Accept';

  @override
  String get syncNearbyReject => 'Reject';

  @override
  String get syncNearbyIncomingRejected => 'Pairing request rejected';

  @override
  String get syncNearbyIncomingExpired => 'The pairing request expired';

  @override
  String get syncNearbyIncomingFailed =>
      'Pairing didn’t finish. Ask the other device to try again.';

  @override
  String get syncNearbyIncomingNotCompleted =>
      'Accepted, but the other device hasn’t finished pairing. If it doesn’t join, ask it to try again.';

  @override
  String get syncNearbyManualProbeSent =>
      'Looking for this device; tap it under Nearby devices to pair';

  @override
  String syncPeerThisDevice(String id) {
    return 'This device · $id';
  }

  @override
  String get syncPeerThisDeviceTitle => 'This device ID';

  @override
  String get syncPeerNever => 'Not connected yet';

  @override
  String get syncSyncing => 'Syncing…';

  @override
  String syncPeerConnectedSince(String time) {
    return 'Connected · last synced $time';
  }

  @override
  String syncPeerDisconnectedSince(String time) {
    return 'Not connected · last synced $time';
  }

  @override
  String syncPeerCloudSyncedSince(String time) {
    return 'Synced to cloud · last synced $time';
  }

  @override
  String syncPeerCloudNotSyncedSince(String time) {
    return 'Not synced to cloud · last synced $time';
  }

  @override
  String syncPeerLastSuccess(String time) {
    return 'Last synced $time';
  }

  @override
  String syncPeerLastAttempt(String time) {
    return 'Last attempt $time';
  }

  @override
  String syncPeerLostSince(String time) {
    return 'Lost · last synced $time';
  }

  @override
  String get syncPeerNameSeparator => ', ';

  @override
  String get syncRoundNoConnectedPeers => 'No devices connected this round';

  @override
  String get syncRoundNoRecords => 'No connection records yet';

  @override
  String syncRoundSynced(String names) {
    return 'Synced this round: $names';
  }

  @override
  String syncRoundSyncedMore(String names, int count) {
    return 'Synced this round: $names and $count more';
  }

  @override
  String syncPeerBehind(int count) {
    return '$count pending';
  }

  @override
  String syncPeerBehindBytes(int count, String size) {
    return '$count pending (~$size)';
  }

  @override
  String syncPeerClockSkew(int minutes) {
    return 'device time differs by $minutes min';
  }

  @override
  String syncPeerLastError(String error) {
    return 'Last error: $error';
  }

  @override
  String get syncTransportPermissionDenied => 'LAN permission missing';

  @override
  String get syncLanPermissionTitle => 'Grant LAN permission';

  @override
  String get syncLanPermissionSubtitle =>
      'Android 17+ needs the nearby-devices permission to reach other devices';

  @override
  String get syncLanPermissionDenied =>
      'Permission not granted: LAN sync is unavailable (manual addresses cannot work around it). Switch to WebDAV instead.';

  @override
  String get syncLanPermissionNeeded => 'LAN permission required';

  @override
  String get syncLanPermissionGrant => 'Grant';

  @override
  String get syncOpenSystemSettings => 'Open settings';

  @override
  String get syncPeerHostLabel => 'Address';

  @override
  String get syncPeerHostHint => 'e.g. 192.168.1.23 or 2409:8a55::5';

  @override
  String get syncPeerNameLabel => 'Name (optional)';

  @override
  String get syncPeerHostInvalid => 'Address cannot be empty';

  @override
  String get syncPeerDelete => 'Remove device';

  @override
  String get syncPeerDeleteConfirm =>
      'Removes it from this device only; it does not revoke sync access. If it still has the sync passphrase and is online, it will appear again. To stop syncing with it, change the sync passphrase.';

  @override
  String get syncPeerRemoved => 'Removed from this device';

  @override
  String get syncPeerManual => 'added manually';

  @override
  String get syncPeerLost => 'Lost';

  @override
  String get syncPeerLostHint =>
      'This device has not connected for over 180 days (it may have been reinstalled or retired). You can remove it from this device, or clean up its cloud sync files; local data is unaffected.';

  @override
  String get syncPeerCleanupRemote => 'Clean up cloud files';

  @override
  String get syncPeerCleanupRemoteHint =>
      'Delete this device’s sync files on WebDAV';

  @override
  String get syncPeerCleanupRemoteConfirm =>
      'Deletes this device’s sync files on WebDAV; local data is unaffected. Files are written again when the device comes back online. LAN connections have no cloud files.';

  @override
  String get syncPeerCleanupRemoteDone => 'Cloud files cleaned up';

  @override
  String get syncPeerCleanupRemoteNone => 'No cloud files to clean up';

  @override
  String syncPeerCleanupRemoteFailed(Object error) {
    return 'Cleanup failed: $error';
  }

  @override
  String get syncPeerNotContacted =>
      'Not connected yet — it retries automatically when the device is online';

  @override
  String syncPeerCandidatesTitle(int count) {
    return '$count available addresses';
  }

  @override
  String get syncPeerCandidatesSubtitle =>
      'not connected yet · tap to view or remove';

  @override
  String get syncLocalAddressCopied => 'Address copied';

  @override
  String get syncLocalAddressesEmptyTitle => 'No available network address';

  @override
  String get syncLocalAddressesHint =>
      'These addresses are used by other devices to reach this one.';

  @override
  String get syncLocalAddressesEmpty =>
      'No usable LAN address found; check the network connection.';

  @override
  String get syncLocalProbePort => 'Discovery port';

  @override
  String get syncLocalProbePortUnavailable =>
      'Unavailable; add a device address manually';

  @override
  String syncLocalProbePortPerFamily(String v4, String v6) {
    return '$v4 (IPv4) / $v6 (IPv6)';
  }

  @override
  String get syncLocalHttpPort => 'Connection port';

  @override
  String get syncLocalHttpPortUnavailable => 'Not started yet';

  @override
  String syncPeerDeviceId(String id) {
    return 'Device $id';
  }

  @override
  String get syncDeviceNameDialogTitle => 'Device name';

  @override
  String get syncRenameHint => 'Shown on other devices';

  @override
  String get syncDeviceNameEmpty => 'Name cannot be empty';

  @override
  String get syncCategorySubtitle =>
      'When off, this device neither uploads nor receives this data';

  @override
  String get syncIssueDialogTitle => 'Sync issue';

  @override
  String get syncIssueUnknown =>
      'Unknown reason — retry first; if it keeps failing, check the sync log';

  @override
  String get syncIssueNotConfigured => 'Sync transport is not configured';

  @override
  String get syncIssueStartFailed => 'Transport failed to start';

  @override
  String get syncIssuePermissionDenied =>
      'LAN permission missing (Android 17+ needs the nearby-devices permission)';

  @override
  String get syncIssueNoPassphrase => 'No sync passphrase set';

  @override
  String get syncIssueAllPeersUnreachable => 'No device can be reached';

  @override
  String get syncIssuePullFailed => 'Failed to read sync data';

  @override
  String get syncIssuePushFailed => 'Failed to upload local changes';

  @override
  String syncIssueApplyFailed(int count) {
    return 'Failed to receive sync data $count time(s)';
  }

  @override
  String syncIssuePeerReadFailed(String peer) {
    return '$peer: failed to read sync data';
  }

  @override
  String syncIssuePeerDecryptFailed(String peer) {
    return '$peer: passphrase mismatch or corrupted data';
  }

  @override
  String syncIssuePeerPushFailed(String peer) {
    return '$peer: upload failed';
  }

  @override
  String get syncIssueBroadcastUnavailable =>
      'Auto-discovery failed (blocked by network policy)';

  @override
  String get syncIssueProbePortUnavailable =>
      'Auto-discovery unavailable; add a device address manually';

  @override
  String get syncIssueDiscoverySilent =>
      'No other device found (the network may be isolated)';

  @override
  String get syncIssueWebdavDirFailed => 'WebDAV folder unavailable';

  @override
  String get syncIssueWebdavListFailed => 'Failed to read the WebDAV folder';

  @override
  String syncIssueWebdavReadFailed(String peer) {
    return '$peer: failed to read sync data';
  }

  @override
  String syncIssueWebdavDecryptFailed(String peer) {
    return '$peer: passphrase mismatch or corrupted data';
  }

  @override
  String get syncIssueWebdavUploadFailed =>
      'Failed to upload sync data to WebDAV';

  @override
  String syncIssueDeleteRemoteFailed(String peer) {
    return 'Failed to clean up cloud files for $peer';
  }

  @override
  String get syncIssueInternal => 'Sync error';

  @override
  String get syncActionGrantPermission => 'Grant permission';

  @override
  String get syncActionConfigure => 'Configure';

  @override
  String get syncActionConfigurePassphrase => 'Set passphrase';

  @override
  String get syncActionAddManualPeer => 'Add manual address';

  @override
  String get syncActionUseWebdav => 'Use WebDAV';

  @override
  String get syncWebdavEnabled => 'WebDAV enabled';

  @override
  String get syncConfigureOnSettingsPage =>
      'Set the passphrase on the sync settings page';

  @override
  String get syncPeerUnknown => 'Unknown device';

  @override
  String get syncPeerDeviceIdCopied => 'Full device ID copied';

  @override
  String get syncPeerHostFormatInvalid =>
      'Invalid address (use an IP or hostname, without a port)';

  @override
  String get syncPeerPortInvalid => 'Port must be 1–65535';

  @override
  String get syncPeerAdded => 'Device added';

  @override
  String get syncPeerUpdated => 'Device updated';

  @override
  String get syncPeerUnreachable =>
      'Not connected: make sure the device is online on the same network, or update its address';

  @override
  String get syncPeerProbePortLabel => 'Discovery port';

  @override
  String syncPeerProbePortHint(int port) {
    return 'Default $port';
  }

  @override
  String get syncPeerAlreadyAdded =>
      'Already in the list — name and port updated';

  @override
  String get syncManualConnect => 'Connect manually';

  @override
  String get syncManualConnectSubtitle =>
      'Enter the device address manually when auto-discovery fails';

  @override
  String get syncManualConnectHint =>
      'Enter an address here when auto-discovery fails. Unpaired devices appear under Nearby devices and pair with one tap.';

  @override
  String get syncNetworkAddresses => 'Network addresses';

  @override
  String syncNetworkAddressesCount(int count) {
    return '$count available';
  }

  @override
  String syncPeerAddressCount(int count) {
    return '$count addresses';
  }

  @override
  String get syncPeerAddressEdit => 'Update address';

  @override
  String get syncPeerAddressDelete => 'Remove address';

  @override
  String get syncPeerAddressDeleteConfirm =>
      'Removes this address from the list; a connected device is unaffected.';

  @override
  String get syncPeerAddressUpdated => 'Address updated';

  @override
  String get syncPeerAddressRemoved => 'Removed from the address list';

  @override
  String get syncPeerContactQueued => 'Device added — it will connect shortly';

  @override
  String syncPeerAddedOffline(String name) {
    return '$name added — not reachable yet, it will retry';
  }

  @override
  String syncPeerConnected(String name) {
    return 'Connected to $name';
  }

  @override
  String get syncPeerContacting => 'Connecting…';

  @override
  String get syncLanPermissionPermanentSubtitle =>
      'Permission permanently denied — enable nearby-devices in system settings';

  @override
  String get syncLogHint =>
      'Results of recent sync rounds; tap a failed row for the reason and next steps';

  @override
  String get settingsUpdateTitle => 'About & updates';

  @override
  String settingsUpdateSubtitle(String version) {
    return 'Current version $version';
  }

  @override
  String settingsUpdateAvailable(String version) {
    return 'Update available: $version';
  }

  @override
  String get updateSettingsSection => 'Updates';

  @override
  String get updateChannelTitle => 'Update channel';

  @override
  String get updateChannelSubtitle =>
      'Stable gets releases only; Beta is early access';

  @override
  String get updateChannelStable => 'Stable';

  @override
  String get updateChannelBeta => 'Beta';

  @override
  String get updateAutoCheckTitle => 'Check for updates automatically';

  @override
  String get updateAutoCheckSubtitle =>
      'Silent check at startup, at most once a day';

  @override
  String get updateCheckTitle => 'Check for updates';

  @override
  String get updateStatusIdle => 'Not checked yet';

  @override
  String get updateStatusChecking => 'Checking…';

  @override
  String get updateStatusUpToDate => 'Up to date';

  @override
  String updateStatusAvailable(String version) {
    return 'New version $version available';
  }

  @override
  String get updateStatusDownloading => 'Downloading…';

  @override
  String get updateStatusDownloaded => 'Ready to install';

  @override
  String get updateStatusInstalling => 'Installing…';

  @override
  String updateLastChecked(String time) {
    return 'Last checked $time';
  }

  @override
  String get updateReleaseSection => 'New version';

  @override
  String updateReleaseTitle(String version) {
    return 'Molia $version';
  }

  @override
  String updateReleaseDate(String date) {
    return 'Released $date';
  }

  @override
  String get updateReleaseDateUnknown => 'Release date unknown';

  @override
  String get updateCancelDownload => 'Cancel';

  @override
  String get updateInstallingHint =>
      'Handed to the installer — follow the system prompts.';

  @override
  String get updateIosHint =>
      'iOS updates come from the App Store; in-app install is not available.';

  @override
  String get updateGrantInstallPermission => 'Grant permission';

  @override
  String get updateInstallNow => 'Install now';

  @override
  String get updateDownloadAndInstall => 'Download and install';

  @override
  String get updateOpenDownloadPage => 'Open download page';

  @override
  String get updateAdvancedSection => 'Advanced';

  @override
  String get updateManifestOverrideTitle => 'Update information URL';

  @override
  String get updateManifestOverrideDefault =>
      'Default (official GitHub release)';

  @override
  String get updateManifestOverrideHint =>
      'Leave empty to use the official URL';

  @override
  String get updateDownloadPrefixTitle => 'Download mirror prefix';

  @override
  String get updateDownloadPrefixDefault => 'Default (GitHub direct)';

  @override
  String get updateDownloadPrefixHint =>
      'e.g. https://gh-proxy.com/ (verify unofficial mirrors yourself)';

  @override
  String get updateAboutSection => 'About';

  @override
  String get updateCurrentVersion => 'Current version';

  @override
  String get updatePlatformTitle => 'Platform';

  @override
  String get updateGithubTitle => 'GitHub repository';

  @override
  String get updateErrorNetwork => 'Network error — update check failed';

  @override
  String get updateErrorManifest => 'Invalid update information';

  @override
  String get updateErrorUnsupported =>
      'In-app updates are not supported on this platform';

  @override
  String get updateErrorChecksum => 'Package checksum mismatch; file deleted';

  @override
  String get updateErrorPermission =>
      'Allow \"Install unknown apps\" to install updates';

  @override
  String get updateErrorNotWritable =>
      'Install directory is read-only; download and replace manually';

  @override
  String get updateErrorInstall => 'Install failed';

  @override
  String updateDownloadProgress(
      String percent, String receivedMb, String speedMb) {
    return 'Downloaded $percent% ($receivedMb MB, $speedMb MB/s)';
  }

  @override
  String get trackInfoTabTitle => 'Details';

  @override
  String get trackInfoEmpty => 'Nothing playing';

  @override
  String get trackInfoQuality => 'Playing quality';

  @override
  String get trackInfoQualityAvailable => 'Available qualities';

  @override
  String get trackInfoQualityUnknown => 'Unknown';

  @override
  String get trackInfoChannel => 'Channel';

  @override
  String get trackInfoChannelUnknown => 'Unknown channel';

  @override
  String get trackInfoAlbum => 'Album';

  @override
  String get trackInfoArtist => 'Artist';

  @override
  String get trackInfoDuration => 'Duration';

  @override
  String get trackInfoTrackId => 'Track ID';

  @override
  String get trackInfoIdCopied => 'Track ID copied';

  @override
  String get localDataTitle => 'Local data';

  @override
  String get trackInfoCacheResolve => 'Playback link cache';

  @override
  String get trackInfoCacheNone => 'Not cached';

  @override
  String trackInfoCacheEntries(int count) {
    return '$count entries';
  }

  @override
  String trackInfoCacheCleared(String size) {
    return 'Cleared $size';
  }

  @override
  String get trackInfoCachePlaying =>
      'Playing — audio cache can be cleared later';

  @override
  String get trackActionCommentsSubtitle => 'Hot and latest comments';

  @override
  String get trackActionSwapSubtitle =>
      'Find this track\'s audio or lyrics on another source';

  @override
  String get trackInfoSource => 'Source';

  @override
  String get trackInfoLyricsSource => 'Lyrics source';

  @override
  String get trackInfoLyricsSourceNone => 'No lyrics yet';

  @override
  String get trackInfoAlbumOpen => 'View album';

  @override
  String get trackInfoArtistOpen => 'View artist';

  @override
  String get trackInfoSourceUnknownId => 'Unknown track ID';

  @override
  String get sharePlatformPage => 'Share platform page';

  @override
  String get openPlatformPage => 'Open platform page';

  @override
  String get shareTrackFile => 'Share song file';

  @override
  String get downloadAndShare => 'Download & share';

  @override
  String get platformPageUnavailable => 'This source has no platform page';

  @override
  String get shareDownloading => 'Downloading — sharing when done';

  @override
  String get localDataCacheSection => 'Cache usage';

  @override
  String get localDataStateCached => 'Cached';

  @override
  String get localDataOfflineAvailable => 'Available offline';

  @override
  String get localDataTransferToFolder => 'Save a copy to folder';

  @override
  String get localDataTransferHint => 'Cached · transfers without network';

  @override
  String get localDataAudioPlatformHint =>
      'This platform does not write a playback cache; one is added after playback';

  @override
  String get trackCacheClearAll => 'Clear all';

  @override
  String trackCacheClearConfirm(String part) {
    return 'Clear \"$part\"?';
  }

  @override
  String get trackCacheClearAllConfirm =>
      'Clear all cached data for this track?';

  @override
  String get trackCacheClearHint =>
      'Only the cache is cleared; downloads and playback are unaffected.';

  @override
  String cacheClearPart(String part) {
    return 'Clear \"$part\"?';
  }

  @override
  String get clear => 'Clear';

  @override
  String get trackCacheEmpty => 'Nothing cached for this track';

  @override
  String trackCacheAudioWriting(String size) {
    return 'Audio writing $size';
  }

  @override
  String get cacheAudioDisabled => 'Audio caching is off';

  @override
  String get downloadAudioSection => 'Audio';

  @override
  String get downloadQualityLabel => 'Quality';

  @override
  String get downloadQualityCached => 'Cached';

  @override
  String get downloadExtrasSection => 'Extras';

  @override
  String get downloadCoverPart => 'Cover';

  @override
  String get downloadPartDownload => 'Download';

  @override
  String get downloadPartRemove => 'Remove';

  @override
  String get downloadAll => 'Download all';

  @override
  String get downloadFromCache => 'Already cached — no download needed';

  @override
  String get downloadLyricsDone => 'Lyrics downloaded';

  @override
  String get downloadCoverDone => 'Cover downloaded';

  @override
  String get downloadNoArtwork => 'No cover for this track';

  @override
  String get downloadNoLyrics => 'No lyrics found';

  @override
  String get downloadSettingsTitle => 'Download settings';

  @override
  String get downloadSettingsSubtitle =>
      'Save location, file names and tag embedding';

  @override
  String get downloadSaveLocation => 'Save location';

  @override
  String get downloadSaveLocationDefault => 'Default (system Downloads)';

  @override
  String get downloadSaveLocationSharedHint => 'Used for downloads and exports';

  @override
  String get downloadSaveLocationAndroid => 'Downloads › Molia';

  @override
  String get downloadSaveLocationIos => 'Files › On My iPhone › Molia';

  @override
  String get downloadSaveLocationFixedHintAndroid =>
      'The playback copy stays in the app; a copy is also saved to Downloads after each download';

  @override
  String get downloadSaveLocationFixedHintAndroidOff =>
      'Public copy is off; files stay in the app. Turn on “Publish to system Downloads” below';

  @override
  String get downloadSaveLocationFixedHintIos =>
      'Files are visible in Files › On My iPhone › Molia';

  @override
  String get downloadPickDirectory => 'Choose folder';

  @override
  String get downloadFilenameTemplate => 'File name format';

  @override
  String get downloadFilenameTemplateHint =>
      'Variables: artist / title / album';

  @override
  String get downloadFilenamePreview => 'Preview';

  @override
  String get downloadReset => 'Reset to default';

  @override
  String get downloadEmbedTags => 'Embed lyrics & cover tags';

  @override
  String get downloadEmbedTagsSubtitle =>
      'Write tags into the audio file (MP3 / FLAC) so other players can read them; the original file is kept if writing fails';

  @override
  String get downloadPublishToPublicDir => 'Publish to system Downloads';

  @override
  String get downloadPublishToPublicDirSubtitle =>
      'Also save a copy to the system Downloads folder (Android) so file managers and other players can see it';

  @override
  String get downloadNotifications => 'Download notifications';

  @override
  String get downloadNotificationsSubtitle =>
      'Show download progress in the notification shade and keep downloading in the background (Android; notification permission required)';

  @override
  String get downloadLocationInfo => 'Download folder';

  @override
  String get downloadPlaybackLocation => 'Playback copy';

  @override
  String get downloadPublicCopyLocation => 'Also saved to';

  @override
  String get downloadLocationUnsupported =>
      'Downloading is not supported on this platform';

  @override
  String get save => 'Save';

  @override
  String get lyricsEmptyState => 'No lyrics found — try another source?';

  @override
  String get lyricsDisplaySettingsAction => 'Lyrics display settings';

  @override
  String get lyricsSwapAction => 'Change lyrics';

  @override
  String get lyricsCopyModeAction => 'Copy lyrics mode';

  @override
  String get lyricsCopyModeExit => 'Exit copy mode';

  @override
  String get commentsTitle => 'Comments';

  @override
  String get commentsTabHot => 'Hot';

  @override
  String commentsTabHotCount(int count) {
    return 'Hot ($count)';
  }

  @override
  String get commentsTabLatest => 'Latest';

  @override
  String commentsTabLatestCount(int count) {
    return 'Latest ($count)';
  }

  @override
  String get commentsEmpty => 'No comments yet';

  @override
  String get commentsUnsupported =>
      'Comments are not available for this channel';

  @override
  String get commentsLoadFailed => 'Failed to load comments';

  @override
  String get commentsPullToRetry => 'Pull down to retry';

  @override
  String get commentsLoadMoreFailed => 'Failed to load more comments';

  @override
  String get commentsNoMore => 'No more comments';

  @override
  String commentsIpLocation(String location) {
    return 'IP: $location';
  }

  @override
  String commentsQuotedAuthor(String name) {
    return '$name: ';
  }

  @override
  String commentsLikedCount(int count) {
    return '$count likes';
  }

  @override
  String get commentsTimeJustNow => 'Just now';

  @override
  String commentsTimeMinutesAgo(int count) {
    return '$count min ago';
  }

  @override
  String commentsTimeHoursAgo(int count) {
    return '$count h ago';
  }

  @override
  String get downloadStatusNotDownloaded => 'Not downloaded';

  @override
  String get downloadStatusDownloading => 'Downloading';

  @override
  String get downloadStatusDownloaded => 'Downloaded';

  @override
  String get downloadAction => 'Download';

  @override
  String get downloadCancel => 'Cancel download';

  @override
  String get downloadDelete => 'Delete download';

  @override
  String get downloadDeleteConfirm =>
      'Delete the download? Audio, lyrics and cover files will be removed.';

  @override
  String get downloadDeleteConfirmMixed =>
      'Delete the downloads? Audio, lyrics and cover files will be removed; imported songs are only removed from the list.';

  @override
  String get localSongsCachedTag => 'Cached';

  @override
  String get localSongsCachedRemove => 'Clear cache';

  @override
  String get localSongsCachedRemoveConfirm =>
      'Clear this song’s audio cache? Only the cache is removed; downloads and imported files are unaffected.';

  @override
  String get localSongsMixedRemoveConfirm =>
      'Remove the selected items? Downloads delete files, imported items are only removed from the list, and cached copies are cleared.';

  @override
  String get downloadShare => 'Share file';

  @override
  String downloadProgressPercent(int percent) {
    return '$percent%';
  }

  @override
  String get downloadCompleted => 'Download complete';

  @override
  String downloadFailed(String message) {
    return 'Download failed: $message';
  }

  @override
  String get downloadUnsupported =>
      'Downloads are not supported on this platform';

  @override
  String get downloadAlreadyExists => 'This track is already downloaded';

  @override
  String get downloadCancelled => 'Download cancelled';

  @override
  String get downloadDataSaverTitle => 'Data saver is active';

  @override
  String get downloadDataSaverConfirm =>
      'You are on mobile data with data saver enabled. Downloading will use mobile data. Continue?';

  @override
  String get downloadContinue => 'Continue';

  @override
  String get downloadFileMissing =>
      'The local file is missing and may have been deleted';

  @override
  String get downloadSourceLocal => 'Local download';

  @override
  String get downloadsManageTitle => 'Downloads';

  @override
  String get downloadsManageSubtitle =>
      'Task queue, batch download and file maintenance';

  @override
  String get downloadsActiveSection => 'In progress';

  @override
  String get downloadsActiveEmpty => 'No downloads in progress';

  @override
  String downloadsActiveCount(int count) {
    return '$count task(s)';
  }

  @override
  String get downloadsBatchSection => 'Batch download';

  @override
  String get downloadsBatchQueue => 'Download current queue';

  @override
  String downloadsBatchQueueSubtitle(int count) {
    return '$count track(s); skips downloaded and local tracks';
  }

  @override
  String downloadsBatchStarted(int count) {
    return 'Batch download started ($count)';
  }

  @override
  String downloadsBatchDone(int done, int failed) {
    return 'Batch finished: $done succeeded, $failed failed';
  }

  @override
  String get downloadsMaintenanceSection => 'File maintenance';

  @override
  String get downloadsCleanupParts => 'Remove unfinished downloads';

  @override
  String get downloadsCleanupPartsSubtitle =>
      'Remove temporary files left by interrupted downloads; finished downloads are untouched';

  @override
  String downloadsCleanupPartsDone(int count) {
    return 'Removed $count unfinished file(s)';
  }

  @override
  String get downloadsCleanupOrphans => 'Remove leftover files';

  @override
  String get downloadsCleanupOrphansSubtitle =>
      'Delete files in the download folder that no record points to';

  @override
  String downloadsCleanupOrphansDone(int count) {
    return 'Removed $count leftover file(s)';
  }

  @override
  String get downloadsBatchPlaylist => 'Download a playlist';

  @override
  String get downloadsBatchPlaylistSubtitle =>
      'Pick a playlist and download it in batch (skips downloaded and local tracks)';

  @override
  String get downloadsPickPlaylist => 'Choose a playlist';

  @override
  String get downloadsMigrateLegacy => 'Move downloads to the new location';

  @override
  String get downloadsMigrateLegacySubtitle =>
      'Move files from the legacy app folder into the current download folder';

  @override
  String downloadsMigrateLegacyDone(int moved, int failed) {
    return 'Moved $moved, failed $failed';
  }

  @override
  String get downloadsPublishPublic => 'Copy to public Downloads folder';

  @override
  String get downloadsPublishPublicSubtitle =>
      'Copy downloads that are not in the system Downloads folder yet (Android)';

  @override
  String downloadsPublishPublicDone(int published, int failed) {
    return 'Copied $published, failed $failed';
  }

  @override
  String get downloadsNoResume =>
      'Failed downloads start over (platform links usually expire quickly).';

  @override
  String get downloadsEmpty => 'No downloaded tracks yet';

  @override
  String get sleepTimerTitle => 'Sleep timer';

  @override
  String get sleepTimerOff => 'Off';

  @override
  String sleepTimerRemaining(String time) {
    return '$time left';
  }

  @override
  String get sleepTimerAfterTrack => 'Pause after current track';

  @override
  String get sleepTimerCancel => 'Turn off timer';

  @override
  String sleepTimerArmedSnackbar(String time) {
    return 'Sleep timer on · pausing in $time';
  }

  @override
  String get sleepTimerArmedAfterTrack =>
      'Sleep timer on · pausing after this track';

  @override
  String get sleepTimerHourLabel => 'Hours';

  @override
  String get sleepTimerMinuteLabel => 'Minutes';

  @override
  String get sleepTimerCustom => 'Custom duration…';

  @override
  String get sleepTimerCustomTitle => 'Custom duration';

  @override
  String get sleepTimerCustomInvalid =>
      'Duration must be between 1 minute and 10 hours';

  @override
  String get sleepTimerCustomConfirm => 'Set';

  @override
  String get trayShowWindow => 'Show window';

  @override
  String get trayPrevious => 'Previous track';

  @override
  String get trayNext => 'Next track';

  @override
  String get trayQuit => 'Quit';

  @override
  String get settingsDesktopSection => 'Desktop';

  @override
  String get settingsCloseToTray => 'Minimize to tray on close';

  @override
  String get settingsCloseToTraySubtitle =>
      'Keep playing in the background; reopen or quit from the tray icon';

  @override
  String get settingsShortcutsTitle => 'Shortcuts';

  @override
  String get settingsShortcutsSubtitle =>
      'Enable and customize in-app and global shortcuts';

  @override
  String get shortcutsInAppSection => 'In-app shortcuts';

  @override
  String get shortcutsInAppHint =>
      'Active while the window is focused; tap a binding to re-record it';

  @override
  String get shortcutsGlobalSection => 'Global shortcuts';

  @override
  String get shortcutsGlobalHint =>
      'Global shortcuts work even when the window is in the background; must include Ctrl / Alt / Shift';

  @override
  String get shortcutsGlobalUnsupportedKey =>
      'Global shortcuts only support letters, digits, F1–F12 and space';

  @override
  String shortcutsGlobalFailed(String detail) {
    return 'Some global shortcuts could not be enabled: $detail';
  }

  @override
  String get shortcutsGlobalLinuxHint =>
      'On Linux these are provided through the desktop portal; minimal desktops may not support it and will report a failure';

  @override
  String get shortcutsEnabledSwitch => 'Enable in-app shortcuts';

  @override
  String get shortcutsGlobalEnabledSwitch => 'Enable global shortcuts';

  @override
  String get shortcutsResetAll => 'Reset to defaults';

  @override
  String get shortcutsRecording => 'Press a new key… (Esc to cancel)';

  @override
  String shortcutsConflict(Object action) {
    return 'Already used by “$action”';
  }

  @override
  String get shortcutsGlobalNeedsModifier =>
      'Global shortcuts must include Ctrl / Alt / Shift';

  @override
  String get shortcutsSwapDialogTitle => 'Replace shortcut?';

  @override
  String shortcutsSwapDialogMessage(String action) {
    return '“$action” already uses this combination. Replacing will swap the two shortcuts.';
  }

  @override
  String get shortcutsSwapConfirm => 'Replace';

  @override
  String shortcutsSwapDone(String action) {
    return 'Swapped shortcuts with “$action”';
  }

  @override
  String get shortcutActionPlayPause => 'Play / pause';

  @override
  String get shortcutActionSeekBackward => 'Seek back 5s';

  @override
  String get shortcutActionSeekForward => 'Seek forward 5s';

  @override
  String get shortcutActionPrevious => 'Previous track';

  @override
  String get shortcutActionNext => 'Next track';

  @override
  String get shortcutActionVolumeUp => 'Volume up';

  @override
  String get shortcutActionVolumeDown => 'Volume down';

  @override
  String get shortcutActionMute => 'Mute toggle';

  @override
  String get shortcutActionSearch => 'Focus search';

  @override
  String get shortcutActionDestination1 => 'Go to page 1';

  @override
  String get shortcutActionDestination2 => 'Go to page 2';

  @override
  String get shortcutActionDestination3 => 'Go to page 3';

  @override
  String get shortcutActionCloseQueue => 'Close queue panel';

  @override
  String get shortcutActionShowWindow => 'Show main window';

  @override
  String get settingsRememberWindowBounds =>
      'Remember window position and size';

  @override
  String get settingsRememberWindowBoundsSubtitle =>
      'Reopen at the last position, size and maximized state';

  @override
  String get settingsTrayLinuxHint =>
      'GNOME and similar desktops need a tray extension to show the icon; without a tray, closing the window quits the app';
}
