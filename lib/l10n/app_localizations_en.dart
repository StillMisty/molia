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
      'Copy Lyrics Mode: Single repeat active, auto-scroll disabled.';

  @override
  String get centerCurrentLine => 'Center Current Line';

  @override
  String get exitCopyModeResumeScroll => 'Exit Copy Mode & Resume Scroll';

  @override
  String get enterCopyLyricsMode => 'Enter Copy Lyrics Mode (Single Repeat)';

  @override
  String get playlist => 'Playlist';

  @override
  String get operationFailed => 'Operation failed';

  @override
  String get settingsAppearanceTitle => 'Appearance';

  @override
  String get settingsThemeMode => 'Theme mode';

  @override
  String get themeModeSystem => 'System default';

  @override
  String get themeModeLight => 'Light';

  @override
  String get themeModeDark => 'Dark';

  @override
  String get settingsDynamicColor => 'Dynamic color';

  @override
  String get settingsDynamicColorSubtitle =>
      'Derive theme colors from album art';

  @override
  String get settingsMonetColor => 'Monet color';

  @override
  String get settingsMonetColorSubtitle =>
      'Use wallpaper colors provided by the system (Android 12+)';

  @override
  String get settingsMonetUnavailable => 'Not supported on this platform';

  @override
  String get settingsPureBlack => 'Pure black background';

  @override
  String get settingsPureBlackSubtitle =>
      'Use pure black surfaces in dark mode (OLED)';

  @override
  String get settingsSeedColor => 'Theme color';

  @override
  String get settingsAppFont => 'App font';

  @override
  String get fontSystemDefault => 'System default';

  @override
  String get fontPickerSearchHint => 'Search fonts';

  @override
  String get fontPickerEmpty => 'No fonts available on this device';

  @override
  String get posterFontLabel => 'Font';

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
  String get settingsCurrentQuality => 'Now playing quality';

  @override
  String get settingsDataSaverTitle => 'Data saver';

  @override
  String get settingsDataSaverSubtitle =>
      'When on, lower audio quality and reduce artwork loading on mobile data';

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
      'Do not request new artwork; show a placeholder when not cached';

  @override
  String get settingsSourcesSection => 'Sources';

  @override
  String get settingsSourcesItemSubtitle =>
      'Import LX Music source scripts to search and play songs from third-party platforms';

  @override
  String get settingsBottomNavTitle => 'Bottom navigation';

  @override
  String get settingsBottomNavHint =>
      'Drag to reorder; toggle to show or hide a tab (at least one stays visible)';

  @override
  String get settingsBottomNavKeepOne => 'Keep at least one tab visible';

  @override
  String get playModeSequential => 'Sequential';

  @override
  String get playModeShuffle => 'Shuffle';

  @override
  String get playModeSingleRepeat => 'Single repeat';

  @override
  String get generalTitle => 'General';

  @override
  String get copyLyricsAsSingleLineTitle => 'Copy lyrics as single line';

  @override
  String get copyLyricsAsSingleLineSubtitle =>
      'Replaces line breaks with spaces when copying';

  @override
  String get dataManagementTitle => 'Data Management';

  @override
  String get exportDataTitle => 'Export Recent Plays';

  @override
  String get exportDataSubtitle => 'Export recent play history as a JSON file';

  @override
  String get importDataTitle => 'Import Recent Plays';

  @override
  String get importDataSubtitle =>
      'Import recent play history from an exported JSON file';

  @override
  String get clearCacheTitle => 'Clear Lyrics Cache';

  @override
  String get clearCacheSubtitle => 'Clear cached lyrics';

  @override
  String get cancelButton => 'Cancel';

  @override
  String get languageDialogTitle => 'Select Language';

  @override
  String get languageSaved => 'Language setting saved';

  @override
  String get exportFailed => 'Export failed or cancelled.';

  @override
  String get importDialogTitle => 'Confirm Import';

  @override
  String get importDialogMessage =>
      'Importing data will replace existing recent play entries with the same identifiers. This cannot be undone. Are you sure you want to continue?\n\nEnsure the JSON file is valid and was previously exported from Molia.';

  @override
  String get importButton => 'Import Data';

  @override
  String get importSuccess => 'Data imported successfully!';

  @override
  String get importFailed => 'Failed to import data.';

  @override
  String get exportSuccess => 'Data exported successfully!';

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
  String failedToChangeLanguage(String error) {
    return 'Failed to change language: $error';
  }

  @override
  String get saveChanges => 'Save';

  @override
  String get selectLyrics => 'Select Lyrics';

  @override
  String get selectLyricsTooltip =>
      'Select lyrics fragments for analysis or sharing';

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
  String get nowPlayingLabel => 'Now Playing';

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
  String get languageEnglish => 'English';

  @override
  String get languageSimplifiedChinese => '简体中文';

  @override
  String get collapseTooltip => 'Collapse';

  @override
  String get expandTooltip => 'Expand';

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
  String get loadingGenerating => 'Generating analysis...';

  @override
  String get currentQueueEmpty => 'Current queue is empty';

  @override
  String get nowPlayingSection => 'Now Playing';

  @override
  String get upNextSection => 'Up Next';

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
  String get playingFrom => 'PLAYING FROM';

  @override
  String get playFromAlbum => 'PLAY FROM ALBUM';

  @override
  String get playFromPlaylist => 'PLAY FROM PLAYLIST';

  @override
  String get play => 'Play';

  @override
  String get sourcesTitle => 'Source Management';

  @override
  String get anyListenEntry => 'any-listen';

  @override
  String get sourcesWebUnsupported =>
      'LX source scripts are not supported on web (a local JS engine is required).';

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
  String get sourcesImportFromUrlSubtitle => 'Download the script over HTTP(S)';

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
      'This quality is preferred when resolving a track URL, with automatic fallback when unavailable.';

  @override
  String get sourcesSortTitle => 'Channel order';

  @override
  String get sourcesSortReset => 'Reset';

  @override
  String get sourcesSortHint =>
      'The channel order on the Discover page matches the list below and also controls the search source order. Newly imported channels are appended at the end; turning a channel off removes it from the Discover page and search results.';

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
  String get sourcesMoveUp => 'Move up';

  @override
  String get sourcesMoveDown => 'Move down';

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
      'Source scripts are executable JavaScript code provided by third-party communities.\nOnce imported, they run in the local JS engine and can make network requests.\nImport only scripts from trusted sources; their availability and legality are the responsibility of the provider.';

  @override
  String get sourcesContinueImport => 'Continue import';

  @override
  String sourcesImportFailed(String error) {
    return 'Import failed: $error';
  }

  @override
  String get sourcesPasteTitle => 'Paste source script';

  @override
  String get sourcesPasteHint =>
      'Paste the full script starting with /** @name ... */';

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
      'Nothing played recently yet. Albums and playlists you play will show up here.';

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
  String get sortDefaultOrder => 'Default order';

  @override
  String get sortByTitle => 'Title';

  @override
  String get sortByArtist => 'Artist';

  @override
  String get playAll => 'Play all';

  @override
  String get nextTrackTooltip => 'Next track';

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
  String get libraryListEnd => '— End —';

  @override
  String get settingsCacheTitle => 'Cache management';

  @override
  String get settingsCacheSubtitle =>
      'Audio, lyrics and artwork usage and policies';

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
  String cacheCustomRangeError(int min, int max) {
    return 'Enter an integer between $min and $max';
  }

  @override
  String get cacheClearPartition => 'Clear';

  @override
  String get cacheClearAll => 'Clear all caches';

  @override
  String get cacheClearAllConfirm =>
      'Clear all caches (audio / lyrics / artwork)? This cannot be undone.';

  @override
  String get settingsLyricsDisplayTitle => 'Lyrics display';

  @override
  String get settingsLyricsDisplaySubtitle =>
      'Floating lyrics, notification & Bluetooth';

  @override
  String get lyricsDisplaySharedTitle => 'Shared';

  @override
  String get lyricsDisplayTranslation => 'Translation';

  @override
  String get lyricsDisplayTranslationSubtitle =>
      'Show translation under the current line';

  @override
  String get lyricsDisplayRoma => 'Romanization';

  @override
  String get lyricsDisplayRomaSubtitle =>
      'Show romanized lyrics under the current line';

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
  String get lyricsDesktopSingleLine => 'Current line only';

  @override
  String get lyricsDesktopAlign => 'Text align';

  @override
  String get lyricsDesktopAlignLeft => 'Left';

  @override
  String get lyricsDesktopAlignCenter => 'Center';

  @override
  String get lyricsDesktopAlignRight => 'Right';

  @override
  String get lyricsDesktopAlignTop => 'Top';

  @override
  String get lyricsDesktopAlignBottom => 'Bottom';

  @override
  String get lyricsDesktopColorPlayed => 'Current line color';

  @override
  String get lyricsDesktopColorUnplayed => 'Other lines color';

  @override
  String get lyricsDesktopColorShadow => 'Shadow color';

  @override
  String get lyricsDesktopLock => 'Lock position (click-through)';

  @override
  String get lyricsDesktopFreeze => 'Freeze while screen off';

  @override
  String get lyricsDesktopPauseBehavior => 'When paused';

  @override
  String get lyricsDesktopNoLyrics => 'Without lyrics';

  @override
  String get lyricsDesktopAnimation => 'Line transition animation';

  @override
  String get lyricsDesktopControls => 'Control bar buttons';

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
      'Uses the media notification subtitle (no modules needed)';

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
      'Writes the current line into media metadata (also visible in notification & lock screen)';

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
  String get lyricsDisplayUnsupported =>
      'Lyric outputs are not available on this platform';
}
