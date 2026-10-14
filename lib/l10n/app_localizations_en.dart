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
  String get settingsPureBlack => 'Pure black background';

  @override
  String get settingsPureBlackSubtitle =>
      'Use pure black surfaces in dark mode (OLED)';

  @override
  String get settingsSeedColor => 'Custom color';

  @override
  String get settingsFollowArtwork => 'Follow album art';

  @override
  String get settingsFollowArtworkSubtitle =>
      'Use album art colors while playing; falls back to base colors';

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
      'Initial mode for new sessions; current playback is unaffected';

  @override
  String get settingsRestoreSessionTitle => 'Resume last playback';

  @override
  String get settingsRestoreSessionSubtitle =>
      'Restore track, queue and position on launch (on by default)';

  @override
  String get settingsCurrentQuality => 'Now playing quality';

  @override
  String get settingsAutoSourceSwap => 'Auto source switch';

  @override
  String get settingsAutoSourceSwapSubtitle =>
      'On failure, find the same song in another source and switch (on by default)';

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
  String get settingsSourcesItemSubtitle =>
      'Import LX Music source scripts to search third-party platforms';

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
  String get playModeSequential => 'Sequential';

  @override
  String get playModeShuffle => 'Shuffle';

  @override
  String get playModeSingleRepeat => 'Single repeat';

  @override
  String get generalTitle => 'General';

  @override
  String get settingsGeneralAndDataTitle => 'General & data';

  @override
  String get settingsGeneralSubtitle =>
      'Language, app name and bottom navigation';

  @override
  String get copyLyricsAsSingleLineTitle => 'Copy lyrics as single line';

  @override
  String get copyLyricsAsSingleLineSubtitle =>
      'Replaces line breaks with spaces when copying';

  @override
  String get dataManagementTitle => 'Data & storage';

  @override
  String get settingsDataSubtitle =>
      'Cache, listening stats and data import/export';

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
  String get saveChanges => 'Save';

  @override
  String get selectLyrics => 'Select Lyrics';

  @override
  String get selectLyricsTooltip =>
      'Select lyrics fragments to make a poster or share';

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
  String get loadingGenerating => 'Generating poster...';

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
      'Preferred when resolving a track URL; falls back when unavailable.';

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
      'The target playlist already contains this track. Changing the source will remove the duplicate and replace it with the selected version.';

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
    return 'Suggested $value (internal storage ÷ 128)';
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
  String get lyricsPageTitle => 'Lyrics page';

  @override
  String get lyricsDisplayPageEntrySubtitle =>
      'Translation and romanization of the in-app lyrics page';

  @override
  String get lyricsPageTranslationSubtitle =>
      'Show translation under each line in the lyrics page';

  @override
  String get lyricsPageRomaSubtitle =>
      'Show romanization under each line in the lyrics page';

  @override
  String get lyricsDisplaySharedTitle => 'Lyric outputs';

  @override
  String get lyricsDisplayOutputsEntrySubtitle =>
      'Translation, timing and unsynced handling shared by all outputs';

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
  String get lyricsDesktopSingleLine => 'Current line only';

  @override
  String get lyricsDesktopAlign => 'Horizontal align';

  @override
  String get lyricsDesktopAlignVertical => 'Vertical align';

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
  String get lyricsDesktopSchemeSource => 'Color source';

  @override
  String get lyricsDesktopSchemeAppTheme => 'Follow app theme';

  @override
  String get lyricsDesktopSchemeArtwork => 'Follow album art';

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
  String get lyricsNotificationEntrySubtitle =>
      'Lyrics written into the media notification and lock screen';

  @override
  String get lyricsNotificationEnable => 'Show lyrics in notification';

  @override
  String get lyricsNotificationEnableSubtitle =>
      'Writes the current line into media metadata';

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
  String get lyricsBluetoothEntrySubtitle =>
      'Lyrics for A2DP car displays and head units';

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
  String get lyricsNotificationPermissionTitle =>
      'Notification permission needed';

  @override
  String get lyricsNotificationPermissionSubtitle =>
      'Allow notifications so the media card appears; tap to open system settings';

  @override
  String get lyricsMediaSessionUnavailable =>
      'System media session unavailable: notification / lock-screen lyrics and playback controls are disabled';

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
  String get lyricsDesktopColorThemeHint =>
      'The color source decides which scheme the theme-role rows use: app theme follows the appearance settings; album art updates live with the current track.';

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
  String get aiDjSettingsSubtitle =>
      'AI-powered radio with your own API key (off by default)';

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
      'Keeps AI-picked songs coming and extends the queue automatically';

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
      'When enabled, your listening profile (aggregated stats, the latest 200 play events, and the list of already-played tracks) will be sent to the AI service you configure in order to generate recommendations. Data goes straight to that service with no relay through this app, and no bundled API key is provided. Turning the mode off stops continuation; clearing the config disconnects it.';

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
  String get aiDjSaveConfig => 'Save';

  @override
  String get aiDjClearConfig => 'Clear';

  @override
  String get aiDjConfigSaved => 'Saved';

  @override
  String aiDjQueued(int count) {
    return '$count queued this session';
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
    return 'Latest $events play events · top $artists artists · $exclusions already-played excluded';
  }

  @override
  String get aiDjUpstreamHint =>
      'Only the stats above plus titles/artists — no play URLs, no device info.';

  @override
  String get aiDjCacheTtlTitle => 'Recommendation cache';

  @override
  String aiDjCacheTtlDays(int days) {
    return 'Keep $days days';
  }

  @override
  String get aiDjCacheTtlForever => 'Keep forever';

  @override
  String get aiDjCacheTtlHint =>
      'An expired list stops feeding the radio; the next extension generates a new batch (no interruption, no notice).';

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
  String get settingsSyncTitle => 'Cross-device sync';

  @override
  String get settingsSyncItemSubtitle =>
      'Playlists, sources, settings and credentials';

  @override
  String get syncGeneralSection => 'Sync';

  @override
  String get syncTrustModelTitle => 'Trust model';

  @override
  String get syncEnabledTitle => 'Enable sync';

  @override
  String get syncEnabledSubtitle =>
      'Exchange data with devices that share your passphrase';

  @override
  String get syncDeviceNameTitle => 'Device name';

  @override
  String get syncPassphraseTitle => 'Sync passphrase';

  @override
  String get syncPassphraseNotSet => 'Not set';

  @override
  String get syncPassphraseTrustHint =>
      'Passphrase is the trust root; every holder is fully trusted. Reset it if leaked.';

  @override
  String get syncPassphraseCopy => 'Copy passphrase';

  @override
  String get syncPassphraseReset => 'Reset passphrase';

  @override
  String get syncPassphraseResetConfirm =>
      'All devices must re-enter the new passphrase. Continue?';

  @override
  String get syncPassphraseJoin => 'Join with existing passphrase';

  @override
  String get syncPassphraseJoinTitle => 'Enter sync passphrase';

  @override
  String get syncPassphraseJoinHint =>
      'Enter the passphrase shown on another device';

  @override
  String get syncPassphraseInvalid =>
      'Invalid passphrase (at least 16 characters)';

  @override
  String get syncSave => 'Save';

  @override
  String get syncSyncNow => 'Sync now';

  @override
  String get syncSyncing => 'Syncing…';

  @override
  String get syncNever => 'Never synced';

  @override
  String syncLastResultOk(String time, int applied) {
    return 'Last sync $time · $applied applied';
  }

  @override
  String syncLastResultFail(String error) {
    return 'Last sync failed: $error';
  }

  @override
  String get syncContentSection => 'What to sync';

  @override
  String get syncCategoryPlaylists => 'Playlists & favorites';

  @override
  String get syncCategorySources => 'Sources (scripts & config)';

  @override
  String get syncCategorySettings => 'App settings';

  @override
  String get syncCategoryStatistics => 'Play statistics';

  @override
  String get syncCategoryHistory => 'Play history';

  @override
  String get syncCategorySession => 'Last playback session';

  @override
  String get syncCategoryCredentials => 'AI DJ & credentials';

  @override
  String get syncTransportSection => 'Transport';

  @override
  String get syncLanTitle => 'LAN direct';

  @override
  String get syncLanSubtitle => 'Device-to-device on the same Wi-Fi, no server';

  @override
  String get syncWebdavTitle => 'WebDAV / cloud';

  @override
  String get syncWebdavSubtitle => 'Sync across networks via your own WebDAV';

  @override
  String get syncWebdavConfigTitle => 'WebDAV settings';

  @override
  String get syncWebdavServer => 'Server URL';

  @override
  String get syncWebdavUsername => 'Username';

  @override
  String get syncWebdavPassword => 'Password';

  @override
  String get syncWebdavRemoteDir => 'Remote directory';

  @override
  String get syncWebdavNotConfigured => 'Not configured';

  @override
  String get syncLogSection => 'Sync log';

  @override
  String get syncLogEmpty => 'No records yet';

  @override
  String syncLogApplied(int applied, int skipped) {
    return '$applied applied, $skipped skipped';
  }

  @override
  String syncLogFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get syncDeviceNameDialogTitle => 'Device name';

  @override
  String get syncRenameHint => 'Shown on other devices';

  @override
  String get syncDeviceNameEmpty => 'Name cannot be empty';

  @override
  String get syncCategorySubtitle =>
      'Turning it off stops pushing and applying this data on this device';

  @override
  String get syncGeneratedHint =>
      'Passphrase generated; enter it on other devices to join';

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
  String get updateReloadNow => 'Reload now';

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
  String get updateManifestOverrideTitle => 'Manifest URL';

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
  String get updateErrorNetwork => 'Network error — update check failed';

  @override
  String get updateErrorManifest => 'Invalid update manifest';

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
  String get trackInfoTabTitle => 'Song info';

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
  String get trackInfoDuration => 'Duration';

  @override
  String get trackInfoTrackId => 'Track ID';

  @override
  String get trackInfoIdCopied => 'Track ID copied';

  @override
  String get trackInfoCacheSection => 'Cache';

  @override
  String get trackInfoCacheResolve => 'Resolved link cache';

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
  String get downloadSection => 'Download';

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
      'Delete the local copy? Audio, lyrics and cover files will be removed.';

  @override
  String get downloadShare => 'Share / export';

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
  String get downloadsTitle => 'Downloads';

  @override
  String get downloadsEmpty => 'No downloaded tracks yet';

  @override
  String downloadsSummary(int count, String size) {
    return '$count tracks · $size';
  }

  @override
  String get downloadsUnsupported =>
      'Downloads are not supported on this platform';
}
