// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get settingsTitle => '设置';

  @override
  String get queueTab => '队列';

  @override
  String get lyricsTab => '歌词';

  @override
  String get cancel => '取消';

  @override
  String playbackFailed(String error) {
    return '播放失败: $error';
  }

  @override
  String get searchHint => '搜索歌曲、专辑、艺术家...';

  @override
  String get searchIdleHint => '输入关键词搜索歌曲';

  @override
  String get clearSearch => '清除搜索';

  @override
  String copiedToClipboard(String type) {
    return '已复制到剪贴板';
  }

  @override
  String get delete => '删除';

  @override
  String get lyricsFetching => '正在获取歌词...';

  @override
  String get lyricsNotFoundForTrack => '未找到此歌曲的歌词。';

  @override
  String lyricsFetchError(String error) {
    return '获取歌词时出错: $error';
  }

  @override
  String get lyricsTitle => '歌词';

  @override
  String get lyricsLoading => '正在加载歌词...';

  @override
  String get lyricsFailedToLoad => '加载歌词失败。';

  @override
  String get lyricsCopyModeSnackbar => '歌词复制模式：单曲重复已激活，自动滚动已禁用。';

  @override
  String get centerCurrentLine => '居中当前行';

  @override
  String get exitCopyModeResumeScroll => '退出复制模式并恢复滚动';

  @override
  String get enterCopyLyricsMode => '进入歌词复制模式（单曲重复）';

  @override
  String get playlist => '播放列表';

  @override
  String get operationFailed => '操作失败';

  @override
  String get settingsAppearanceTitle => '外观';

  @override
  String get settingsThemeMode => '主题模式';

  @override
  String get themeModeSystem => '跟随系统';

  @override
  String get themeModeLight => '浅色';

  @override
  String get themeModeDark => '深色';

  @override
  String get settingsDynamicColor => '动态取色';

  @override
  String get settingsDynamicColorSubtitle => '从专辑封面提取主题色';

  @override
  String get settingsMonetColor => '莫奈取色';

  @override
  String get settingsMonetColorSubtitle => '使用系统壁纸提供的配色（Android 12+）';

  @override
  String get settingsMonetUnavailable => '当前平台不支持';

  @override
  String get settingsPureBlack => '纯黑背景';

  @override
  String get settingsPureBlackSubtitle => '深色模式下使用纯黑背景（OLED 省电）';

  @override
  String get settingsSeedColor => '主题色';

  @override
  String get settingsAppFont => '应用字体';

  @override
  String get fontSystemDefault => '系统默认';

  @override
  String get fontPickerSearchHint => '搜索字体';

  @override
  String get fontPickerEmpty => '未找到设备字体';

  @override
  String get posterFontLabel => '字体';

  @override
  String get posterFontFollowApp => '跟随应用字体';

  @override
  String get colorBlue => '蓝色';

  @override
  String get colorPurple => '紫色';

  @override
  String get colorGreen => '绿色';

  @override
  String get colorOrange => '橙色';

  @override
  String get colorPink => '粉色';

  @override
  String get colorTeal => '青色';

  @override
  String get settingsPlaybackTitle => '播放';

  @override
  String get settingsDefaultPlayMode => '默认播放模式';

  @override
  String get settingsCurrentQuality => '当前播放音质';

  @override
  String get settingsDataSaverTitle => '省流模式';

  @override
  String get settingsDataSaverSubtitle => '开启后，使用移动数据时自动降低音质并减少封面加载';

  @override
  String get settingsDataSaverNetworkCellular => '移动数据 · 已生效';

  @override
  String get settingsDataSaverNetworkWifi => 'Wi-Fi · 未生效';

  @override
  String get settingsDataSaverNetworkUnknown => '无法检测网络类型';

  @override
  String get settingsDataSaverQuality => '省流音质上限';

  @override
  String get settingsDataSaverCovers => '移动数据下仅使用已缓存封面';

  @override
  String get settingsDataSaverCoversSubtitle => '不发起新的封面请求，无缓存时显示占位图标';

  @override
  String get settingsSourcesSection => '音源';

  @override
  String get settingsSourcesItemSubtitle => '导入 LX Music 音源脚本，搜索并播放第三方平台歌曲';

  @override
  String get settingsBottomNavTitle => '底部导航';

  @override
  String get settingsBottomNavHint => '拖拽排序；开关控制显示，至少保留 1 个标签';

  @override
  String get settingsBottomNavKeepOne => '至少保留 1 个标签';

  @override
  String get playModeSequential => '顺序播放';

  @override
  String get playModeShuffle => '随机播放';

  @override
  String get playModeSingleRepeat => '单曲循环';

  @override
  String get generalTitle => '通用';

  @override
  String get copyLyricsAsSingleLineTitle => '将歌词复制为单行';

  @override
  String get copyLyricsAsSingleLineSubtitle => '复制时将换行符替换为空格';

  @override
  String get dataManagementTitle => '数据管理';

  @override
  String get exportDataTitle => '导出最近播放';

  @override
  String get exportDataSubtitle => '将最近播放记录导出为 JSON 文件';

  @override
  String get importDataTitle => '导入最近播放';

  @override
  String get importDataSubtitle => '从导出的 JSON 文件导入最近播放记录';

  @override
  String get clearCacheTitle => '清除歌词缓存';

  @override
  String get clearCacheSubtitle => '清除已缓存的歌词';

  @override
  String get cancelButton => '取消';

  @override
  String get languageDialogTitle => '选择语言';

  @override
  String get languageSaved => '语言设置已保存';

  @override
  String get exportFailed => '导出失败或已取消。';

  @override
  String get importDialogTitle => '确认导入';

  @override
  String get importDialogMessage =>
      '导入数据将替换具有相同标识符的现有最近播放记录。此操作无法撤销。您确定要继续吗？\n\n确保 JSON 文件有效且之前是从茉咏导出的。';

  @override
  String get importButton => '导入数据';

  @override
  String get importSuccess => '数据导入成功！';

  @override
  String get importFailed => '导入数据失败。';

  @override
  String get exportSuccess => '数据导出成功！';

  @override
  String get clearCacheDialogTitle => '确认清除缓存';

  @override
  String get clearCacheDialogMessage => '确定要清除歌词缓存吗？此操作无法撤销。';

  @override
  String get clearCacheButton => '清除缓存';

  @override
  String get clearingCache => '正在清除缓存...';

  @override
  String get cacheCleared => '缓存清除成功。';

  @override
  String get cacheClearFailed => '清除缓存失败。';

  @override
  String failedToChangeLanguage(String error) {
    return '更改语言失败: $error';
  }

  @override
  String get saveChanges => '保存';

  @override
  String get selectLyrics => '选择歌词';

  @override
  String get selectLyricsTooltip => '选择歌词片段进行分析或分享';

  @override
  String get deselectAll => '取消全选';

  @override
  String get noLyricsSelected => '请先选择一些歌词';

  @override
  String get sharePoster => '分享海报';

  @override
  String selectedLyricsCopied(int count) {
    return '已复制 $count 行歌词';
  }

  @override
  String posterGenerationFailed(Object error) {
    return '生成海报失败: $error';
  }

  @override
  String get noLyricsToSelect => '没有可选择的歌词';

  @override
  String get posterLyricsLimitExceeded => '最多只能选择10行歌词生成海报';

  @override
  String get tapToSelectLyrics => '轻点歌词行以选中';

  @override
  String get nowPlayingLabel => '播放';

  @override
  String get libraryLabel => '发现';

  @override
  String get libraryTabSearch => '搜索';

  @override
  String get libraryTabLeaderboards => '热榜';

  @override
  String get libraryTabPlaylists => '歌单';

  @override
  String get libraryChannelSelect => '选择渠道';

  @override
  String get libraryNoChannels => '所有渠道都已停用，请在「音源管理」中启用渠道。';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSimplifiedChinese => '简体中文';

  @override
  String get collapseTooltip => '收起';

  @override
  String get expandTooltip => '展开';

  @override
  String get noItemsFound => '未找到项目';

  @override
  String get copyButtonText => '复制';

  @override
  String get posterButtonLabel => '海报';

  @override
  String get retryButton => '重试';

  @override
  String get backToLibraryTooltip => '返回资料库';

  @override
  String get loadingGenerating => '正在生成分析...';

  @override
  String get currentQueueEmpty => '当前队列为空';

  @override
  String get nowPlayingSection => '正在播放';

  @override
  String get upNextSection => '接下来';

  @override
  String get searchLyrics => '搜索歌词';

  @override
  String get noCurrentTrackPlaying => '没有正在播放的歌曲';

  @override
  String get cannotGetTrackInfo => '无法获取当前歌曲信息';

  @override
  String get lyricsSearchAppliedSuccess => '歌词已成功搜索并应用';

  @override
  String get searchResults => '搜索结果';

  @override
  String get noResultsFound => '未找到结果';

  @override
  String get playlistType => '播放列表';

  @override
  String get albumType => '专辑';

  @override
  String get songType => '歌曲';

  @override
  String get artistType => '艺术家';

  @override
  String get retry => '重试';

  @override
  String get providerQQMusic => 'QQ音乐';

  @override
  String get providerLRCLIB => 'LRCLIB';

  @override
  String get providerNetease => '网易云音乐';

  @override
  String get playingFrom => '播放自';

  @override
  String get playFromAlbum => '播放自专辑';

  @override
  String get playFromPlaylist => '播放自播放列表';

  @override
  String get play => '播放';

  @override
  String get sourcesTitle => '音源管理';

  @override
  String get anyListenEntry => 'any-listen 接入';

  @override
  String get sourcesWebUnsupported => 'Web 端暂不支持 LX 音源脚本（需要本地 JS 引擎）。';

  @override
  String get sourcesNoneActive => '未启用音源';

  @override
  String sourcesActiveSource(String name, String version) {
    return '当前音源：$name $version';
  }

  @override
  String get sourcesActivating => '正在激活…';

  @override
  String sourcesActivationFailed(String error) {
    return '激活失败：$error';
  }

  @override
  String sourcesAuthor(String author) {
    return '作者：$author';
  }

  @override
  String get sourcesUpdateAlertTitle => '音源更新提示';

  @override
  String get sourcesOpenUpdateUrl => '打开更新地址';

  @override
  String get sourcesUpdateDismiss => '知道了';

  @override
  String get sourcesUpdateNow => '立即更新';

  @override
  String get sourcesUpdating => '正在更新…';

  @override
  String sourcesUpdateSuccess(String version) {
    return '已更新到 $version';
  }

  @override
  String get sourcesUpdateNoUpdate => '已是最新版本';

  @override
  String sourcesUpdateFailed(String reason) {
    return '更新失败：$reason';
  }

  @override
  String get sourcesUpdateManualHint => '该地址不是脚本文件，请打开更新页手动导入。';

  @override
  String get sourcesImportFromFile => '从文件导入';

  @override
  String get sourcesImportFromFileSubtitle => '选择 .js 格式的 LX Music 音源脚本';

  @override
  String get sourcesImportFromText => '粘贴脚本导入';

  @override
  String get sourcesImportFromTextSubtitle => '从剪贴板粘贴脚本全文';

  @override
  String get sourcesImportFromUrl => '从链接导入';

  @override
  String get sourcesImportFromUrlSubtitle => '从 HTTP(S) 链接下载脚本';

  @override
  String get sourcesDefaultQuality => '默认音质';

  @override
  String get sourcesQualityHiRes => 'Hi-Res';

  @override
  String get sourcesQualityLossless => '无损';

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
  String get sourcesQualityHint => '取链时会优先使用该音质，不可用时自动回退。';

  @override
  String get sourcesSortTitle => '渠道排序';

  @override
  String get sourcesSortReset => '重置';

  @override
  String get sourcesSortHint =>
      '发现页的渠道顺序与下方一致，同时决定搜索音源顺序；新导入的渠道自动排在末尾，关闭开关后该渠道不再出现在发现页与搜索结果中。';

  @override
  String get sourcesChannelDisabled => '已停用';

  @override
  String get sourcesNoSearchableSources => '当前没有可搜索的音源。启用音源脚本后，这里会列出可搜索的平台。';

  @override
  String get sourcesKindLx => '脚本音源';

  @override
  String get sourcesKindBuiltin => '内置平台';

  @override
  String get sourcesMoveUp => '上移';

  @override
  String get sourcesMoveDown => '下移';

  @override
  String sourcesImportedScripts(int count) {
    return '已导入的脚本 ($count)';
  }

  @override
  String get sourcesNoScripts =>
      '还没有导入音源脚本。社区音源可在 Github 搜索 “lx-music-source” 获取。';

  @override
  String sourcesScriptByAuthor(String author) {
    return 'by $author';
  }

  @override
  String get sourcesEnable => '启用';

  @override
  String get sourcesDisable => '停用';

  @override
  String sourcesActivated(String name) {
    return '已启用音源：$name';
  }

  @override
  String sourcesActivateFailed(String error) {
    return '启用失败：$error';
  }

  @override
  String get sourcesDeleteScriptTitle => '删除音源脚本';

  @override
  String sourcesDeleteScriptConfirm(String name) {
    return '确定删除「$name」吗？';
  }

  @override
  String get sourcesDisclaimerTitle => '导入音源脚本';

  @override
  String get sourcesDisclaimerBody =>
      '音源脚本为第三方社区提供的可执行 JavaScript 代码，\n导入后将在本机 JS 引擎中运行，可发起网络请求。\n请仅导入来源可信的脚本，脚本的可用性与合法性由提供者负责。';

  @override
  String get sourcesContinueImport => '继续导入';

  @override
  String sourcesImportFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String get sourcesPasteTitle => '粘贴音源脚本';

  @override
  String get sourcesPasteHint => '粘贴以 /** @name ... */ 开头的脚本全文';

  @override
  String get sourcesImportAction => '导入';

  @override
  String get sourcesDownloadAndImport => '下载并导入';

  @override
  String get searchFailed => '搜索失败';

  @override
  String get searchNoSourcesTitle => '当前无可用音源';

  @override
  String get searchNoSourcesHint => '请在「音源管理」中导入并启用音源，或选择一个可用的音源。';

  @override
  String searchNoResultsInSource(String source) {
    return '在「$source」中没有找到结果';
  }

  @override
  String get searchLoadMore => '加载更多';

  @override
  String searchLoadMoreWithTotal(int total) {
    return '加载更多（共 $total 首）';
  }

  @override
  String get languageSettingTitle => '应用语言';

  @override
  String get languageSettingSubtitle => '更改界面显示语言';

  @override
  String get languageSystem => '跟随系统';

  @override
  String get recentlyPlayedEmpty => '还没有最近播放内容。播放一些歌曲后，最近播放的专辑/歌单会显示在这里。';

  @override
  String get libraryRecentPlays => '最近播放';

  @override
  String get libraryPlaylists => '我的列表';

  @override
  String get libraryImportFavorites => '导入收藏夹';

  @override
  String get libraryImportFavoritesSubtitle => '从 LX Music 导出的收藏夹文件（.lxmc）导入';

  @override
  String libraryImportSuccess(int count) {
    return '已导入 $count 首';
  }

  @override
  String libraryImportFailed(String reason) {
    return '导入失败：$reason';
  }

  @override
  String get libraryImportUnsupported => '当前平台不支持导入 .lxmc 收藏夹';

  @override
  String get libraryImportNoTracks => '文件中没有可导入的曲目';

  @override
  String get historyClear => '清空历史';

  @override
  String get historyClearConfirm => '确定清空全部播放历史？此操作不可撤销。';

  @override
  String get historyEmpty => '还没有播放记录';

  @override
  String get favoriteAdd => '收藏';

  @override
  String get favoriteRemove => '取消收藏';

  @override
  String get favoritesPlaylistName => '我的收藏';

  @override
  String get favoritesLabel => '收藏';

  @override
  String get favoritesEmpty => '还没有收藏记录';

  @override
  String get favoritesSearchHint => '搜索歌曲';

  @override
  String get favoritesSearchEmpty => '没有匹配的歌曲';

  @override
  String get favoritesSwitchTitle => '切换收藏夹';

  @override
  String get shufflePlay => '随机播放';

  @override
  String get sortTooltip => '排序';

  @override
  String get sortDefaultOrder => '默认顺序';

  @override
  String get sortByTitle => '按标题';

  @override
  String get sortByArtist => '按艺术家';

  @override
  String get playAll => '播放全部';

  @override
  String get nextTrackTooltip => '下一首';

  @override
  String get playlistEmpty => '还没有列表。点「新建列表」创建，或导入 LX Music 收藏夹。';

  @override
  String get playlistTracksEmpty => '这个列表还没有曲目';

  @override
  String playlistTrackCount(int count) {
    return '$count 首';
  }

  @override
  String get playlistDelete => '删除列表';

  @override
  String playlistDeleteConfirm(String name) {
    return '删除「$name」？';
  }

  @override
  String get playlistRemoveTrack => '从列表移除';

  @override
  String get playlistCreate => '新建列表';

  @override
  String get playlistCreateConfirm => '创建';

  @override
  String get playlistCreateHint => '列表名称';

  @override
  String get playlistNameRequired => '请输入列表名称';

  @override
  String get playlistNameExists => '已有同名列表';

  @override
  String get playlistRename => '重命名列表';

  @override
  String get addToPlaylist => '加入列表';

  @override
  String get playlistReorder => '调整顺序';

  @override
  String get playlistReorderHint => '长按拖动调整顺序';

  @override
  String get playlistReorderDone => '完成';

  @override
  String get selectAllItems => '全选';

  @override
  String get historyDeleteEntry => '删除记录';

  @override
  String playlistAddedTo(String name) {
    return '已加入「$name」';
  }

  @override
  String get playlistAlreadyContains => '已在列表中';

  @override
  String get playlistImportToMine => '导入到我的列表';

  @override
  String get playlistImportFromFile => '从 .lxmc 文件导入';

  @override
  String get playlistImportFromLink => '从歌单链接导入';

  @override
  String get playlistImportChannel => '平台';

  @override
  String get playlistImportEmpty => '歌单没有可导入的曲目';

  @override
  String get playlistImportedName => '导入的歌单';

  @override
  String get discoverSectionTitle => '发现';

  @override
  String get discoverLeaderboards => '热榜';

  @override
  String get discoverPlaylists => '歌单';

  @override
  String get discoverHotSearches => '热搜';

  @override
  String get discoverOpenPlaylist => '打开歌单';

  @override
  String get discoverOpenPlaylistHint => '粘贴歌单链接或 ID';

  @override
  String get discoverOpen => '打开';

  @override
  String get discoverPlaylistSearchHint => '搜索歌单';

  @override
  String get discoverHotTags => '热门标签';

  @override
  String get discoverAll => '全部';

  @override
  String get discoverAllTags => '全部标签';

  @override
  String get discoverLoadMore => '加载更多';

  @override
  String get discoverLoadFailed => '加载失败';

  @override
  String get discoverRetry => '重试';

  @override
  String get discoverNoContent => '暂无内容';

  @override
  String get discoverSearchEmpty => '没有找到歌单';

  @override
  String discoverPlaylistAuthor(String author) {
    return '由 $author';
  }

  @override
  String get discoverAddToPlaylist => '加入列表';

  @override
  String get discoverNoPlaylists => '还没有列表。先在资料库中收藏歌曲创建列表。';

  @override
  String discoverPlayCount(String count) {
    return '$count 次播放';
  }

  @override
  String get settingsAppTitle => '应用名称';

  @override
  String get settingsAppTitleSubtitle => '无歌曲播放时显示在顶栏';

  @override
  String get settingsAppTitleDialogTitle => '应用名称';

  @override
  String get settingsAppTitleHint => '输入名称';

  @override
  String get appName => '茉咏';

  @override
  String get libraryRecentContexts => '最近播放';

  @override
  String get libraryHistory => '播放历史';

  @override
  String get libraryListEnd => '— 到底了 —';

  @override
  String get settingsCacheTitle => '缓存管理';

  @override
  String get settingsCacheSubtitle => '音频 / 歌词 / 封面占用与策略';

  @override
  String get cachePartitionAudio => '音频缓存';

  @override
  String get cachePartitionLyrics => '歌词缓存';

  @override
  String get cachePartitionArtwork => '封面缓存';

  @override
  String cacheUsage(String size, int count) {
    return '$size · $count 项';
  }

  @override
  String get cacheUsageComputing => '统计中…';

  @override
  String get cachePolicyAudioEnabled => '边播边缓存';

  @override
  String get cachePolicyAudioMax => '容量上限';

  @override
  String get cachePolicyLyricsTtl => '歌词保留时长';

  @override
  String get cachePolicyArtworkMax => '封面数量上限';

  @override
  String get cachePolicyArtworkStale => '封面过期时长';

  @override
  String get cacheUnlimited => '不限制';

  @override
  String get cacheNeverExpire => '永不过期';

  @override
  String cacheValueMb(int value) {
    return '$value MB';
  }

  @override
  String cacheValueDays(int value) {
    return '$value 天';
  }

  @override
  String cacheValueItems(int value) {
    return '$value 个';
  }

  @override
  String get cacheUnitMb => 'MB';

  @override
  String get cacheUnitDays => '天';

  @override
  String get cacheUnitItems => '个';

  @override
  String cacheCustomHint(String label, int min, int max) {
    return '0 = $label · 范围 $min–$max';
  }

  @override
  String cacheCustomRangeError(int min, int max) {
    return '请输入 $min–$max 之间的整数';
  }

  @override
  String get cacheClearPartition => '清理';

  @override
  String get cacheClearAll => '清理全部缓存';

  @override
  String get cacheClearAllConfirm => '确定清理全部缓存（音频 / 歌词 / 封面）？此操作无法撤销。';
}
