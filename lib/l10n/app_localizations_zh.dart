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
  String get close => '关闭';

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
  String get searchClose => '关闭搜索';

  @override
  String searchResultsAnnouncement(int count) {
    return '$count 条搜索结果';
  }

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
  String get lyricsCopyModeSnackbar => '已进入复制模式：切到单曲循环并暂停跟随，退出时恢复原设置。';

  @override
  String get centerCurrentLine => '居中当前行';

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
  String get settingsBaseColor => '基础配色';

  @override
  String get settingsBaseColorWallpaper => '系统壁纸';

  @override
  String get settingsBaseColorCustom => '自定义颜色';

  @override
  String get settingsMonetUnavailable => '当前平台不支持';

  @override
  String get settingsBaseColorWallpaperActive => '当前来源：系统壁纸';

  @override
  String get settingsBaseColorAccentActive => '当前来源：系统主题色';

  @override
  String get settingsPureBlack => '纯黑背景';

  @override
  String get settingsPureBlackSubtitle => '深色模式下背景纯黑，OLED 更省电';

  @override
  String get settingsSeedColor => '自定义颜色';

  @override
  String get settingsFollowArtwork => '播放时跟随封面';

  @override
  String get settingsFollowArtworkSubtitle => '按当前歌曲封面取色，无封面时用基础配色';

  @override
  String get coverTitle => '歌曲封面';

  @override
  String get coverFollowSong => '跟随歌曲';

  @override
  String get coverCustomized => '已自定义';

  @override
  String get coverChooseImage => '选择图片';

  @override
  String get coverChangeImage => '更换图片';

  @override
  String get coverResetSong => '恢复歌曲封面';

  @override
  String get coverUpdated => '封面已更新';

  @override
  String get coverUpdateFailed => '封面更新失败，请重试';

  @override
  String get coverUnreadable => '无法读取这张图片，请换一张';

  @override
  String get coverDefaultTitle => '默认封面';

  @override
  String get coverDefaultSubtitle => '歌曲没有封面时显示';

  @override
  String get coverResetDefault => '恢复 Molia 标志';

  @override
  String get coverDefaultUpdated => '默认封面已更新';

  @override
  String get settingsSyncCustomCovers => '同步自定义封面';

  @override
  String get settingsSyncCustomCoversSubtitle => '默认关闭；开启后随同步发送';

  @override
  String get coverLabel => '封面';

  @override
  String get settingsAppFont => '应用字体';

  @override
  String get fontSystemDefault => '系统默认';

  @override
  String get fontPickerSearchHint => '搜索字体';

  @override
  String get fontPickerEmpty => '未找到可用字体';

  @override
  String get posterFontLabel => '字体';

  @override
  String get posterColorSource => '取色来源';

  @override
  String get posterColorSourceAppTheme => '跟随应用主题';

  @override
  String get posterColorSourceArtwork => '跟随封面';

  @override
  String get posterColorSourceCustom => '自定义颜色';

  @override
  String get posterColorCustomLabel => '自定义色';

  @override
  String get posterColorUnavailable => '当前曲目无封面';

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
  String get settingsDefaultPlayModeSubtitle => '下次开始播放时用这个模式，不影响当前播放';

  @override
  String get settingsRestoreSessionTitle => '启动时恢复上次播放';

  @override
  String get settingsRestoreSessionSubtitle => '恢复上次的曲目、队列与进度';

  @override
  String get settingsPlayWithOtherApps => '与其他应用同时播放';

  @override
  String get settingsPlayWithOtherAppsSubtitle => '导航、视频等声音不会打断音乐';

  @override
  String get settingsLibraryAddPosition => '加入收藏与列表的位置';

  @override
  String get settingsLibraryAddPositionSubtitle => '收藏和自建列表的新歌放在顶部还是底部';

  @override
  String get settingsLibraryAddPositionTop => '顶部';

  @override
  String get settingsLibraryAddPositionBottom => '底部';

  @override
  String get settingsAutoSourceSwap => '自动换源';

  @override
  String get settingsAutoSourceSwapSubtitle => '播放失败时自动换到其它音源找同一首歌';

  @override
  String get settingsDataSaverTitle => '省流模式';

  @override
  String get settingsDataSaverSubtitle => '使用移动数据时自动降低音质、少加载封面';

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
  String get settingsDataSaverCoversSubtitle => '不再加载新封面，未缓存的显示占位图';

  @override
  String get settingsSourcesItemSubtitle => '导入 LX Music 音源脚本，扩展可搜索的平台';

  @override
  String get settingsContentSection => '内容与来源';

  @override
  String get settingsLyricsSection => '歌词与展示';

  @override
  String get settingsBottomNavTitle => '底部导航';

  @override
  String get settingsBottomNavHint => '拖拽排序；开关控制显示，至少保留 1 个标签';

  @override
  String get settingsBottomNavKeepOne => '至少保留 1 个标签';

  @override
  String get settingsBottomNavKeepHome => '该页正在作为启动首页，请先在「启动时打开」中更改';

  @override
  String get settingsStartupPageTitle => '启动时打开';

  @override
  String get settingsStartupPageSubtitle => '打开应用时默认进入的页面';

  @override
  String settingsStartupPageHidden(String page, String effective) {
    return '「$page」已隐藏，启动时实际打开「$effective」';
  }

  @override
  String get playModeListLoop => '列表循环';

  @override
  String get playModeSequential => '顺序播放';

  @override
  String get playModeShuffle => '随机播放';

  @override
  String get playModeSingleRepeat => '单曲循环';

  @override
  String get generalTitle => '通用';

  @override
  String get settingsHapticsTitle => '震动反馈';

  @override
  String get settingsHapticsSubtitle => '点按导航、播放等操作时给出轻震动';

  @override
  String get settingsGeneralTitle => '通用设置';

  @override
  String get settingsGeneralSubtitle => '语言、应用名称与底部导航';

  @override
  String get settingsDataSection => '数据';

  @override
  String get dataManagementTitle => '数据与存储';

  @override
  String get settingsDataSubtitle => '缓存、下载与数据导入导出';

  @override
  String get settingsDataStorageSection => '存储与统计';

  @override
  String get settingsDataPortabilitySection => '导入与导出';

  @override
  String get exportDataTitle => '导出数据';

  @override
  String get exportDataSubtitle => '完整备份：歌单、音源、设置、统计与历史（不含密钥）';

  @override
  String get importDataTitle => '导入数据';

  @override
  String get importDataSubtitle => '把 Molia 备份与本地数据合并';

  @override
  String get clearCacheTitle => '清除歌词缓存';

  @override
  String get clearCacheSubtitle => '清除已缓存的歌词';

  @override
  String get cancelButton => '取消';

  @override
  String get languageSaved => '语言设置已保存';

  @override
  String get exportFailed => '导出失败或已取消。';

  @override
  String get importDialogTitle => '确认导入';

  @override
  String get importDialogMessage =>
      '导入会把备份与本地数据合并，相同条目以备份为准，且无法撤销。\n\n请确认文件是从 Molia 导出的备份。';

  @override
  String get importButton => '导入数据';

  @override
  String get importSuccess => '数据导入成功！';

  @override
  String get importFailed => '导入数据失败。';

  @override
  String get exportSuccess => '数据导出成功！';

  @override
  String savedToPath(String path) {
    return '已保存到 $path';
  }

  @override
  String savedToDownloads(String path) {
    return '已保存到系统「下载」：$path';
  }

  @override
  String savedToFilesApp(String path) {
    return '已保存到「文件」App：$path';
  }

  @override
  String get saveFailed => '保存失败，请重试。';

  @override
  String fileInDownloads(String path) {
    return '文件已在下载目录：$path';
  }

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
  String get saveChanges => '保存';

  @override
  String get selectLyrics => '选择歌词';

  @override
  String get lyricsPosterAction => '歌词海报';

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
  String get libraryLoadFailed => '资料库加载失败';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSimplifiedChinese => '简体中文';

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
  String get loadingGenerating => '正在生成海报...';

  @override
  String get currentQueueEmpty => '当前队列为空';

  @override
  String get nowPlayingSection => '正在播放';

  @override
  String get nowPlayingPaused => '已暂停';

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
  String get providerKugou => '酷狗音乐';

  @override
  String get providerKuwo => '酷我音乐';

  @override
  String get providerMigu => '咪咕音乐';

  @override
  String get lyricsBestMatch => '最佳匹配';

  @override
  String get playingFrom => '播放自';

  @override
  String get playFromAlbum => '播放自专辑';

  @override
  String get playFromPlaylist => '播放自播放列表';

  @override
  String get play => '播放';

  @override
  String get pause => '暂停';

  @override
  String get sourcesTitle => '音源管理';

  @override
  String get sourcesStatusSection => '当前状态';

  @override
  String get sourcesImportSection => '导入脚本';

  @override
  String get anyListenEntry => 'any-listen 接入';

  @override
  String get anyListenIntroBody => 'any-listen 是自托管的音乐服务。启用后，它的在线音源会出现在搜索页。';

  @override
  String get anyListenIntroHint => '该接入尚未与真实服务器验证，可能暂不可用。';

  @override
  String get anyListenServerSection => '服务器配置';

  @override
  String get anyListenServerUrl => '服务器地址';

  @override
  String get anyListenServerUrlHint => 'any-listen 服务的访问地址';

  @override
  String get anyListenServerUrlRequired => '请先填写服务器地址';

  @override
  String get anyListenServerUrlRequiredToEnable => '启用前请填写服务器地址';

  @override
  String get anyListenToken => '访问密码（可选）';

  @override
  String get anyListenTokenPlaceholder => '连接测试通过后，粘贴服务器提供的访问密码';

  @override
  String get anyListenTokenShow => '显示访问密码';

  @override
  String get anyListenTokenHide => '隐藏访问密码';

  @override
  String get anyListenEnable => '启用 any-listen 音源';

  @override
  String get anyListenEnableSubtitle => '关闭后不出现在搜索页，也不会联网';

  @override
  String get anyListenSave => '保存';

  @override
  String get anyListenTest => '连接测试';

  @override
  String get anyListenSaveFailed => '保存失败：无法写入本地存储';

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
  String get sourcesImportFromUrlSubtitle => '从链接下载脚本';

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
  String get sourcesQualityHint => '优先用这个音质播放，不支持时自动降级';

  @override
  String get sourcesSortTitle => '渠道排序';

  @override
  String get sourcesSortReset => '重置';

  @override
  String get sourcesSortResetSubtitle => '恢复「脚本音源在前、内置平台在后」的默认顺序';

  @override
  String get sourcesSortHint => '发现页与搜索都按这里的顺序；新渠道排在末尾，关闭后不再出现。';

  @override
  String get sourcesChannelDisabled => '已停用';

  @override
  String get sourcesNoSearchableSources => '当前没有可搜索的音源。启用音源脚本后，这里会列出可搜索的平台。';

  @override
  String get sourcesKindLx => '脚本音源';

  @override
  String get sourcesKindBuiltin => '内置平台';

  @override
  String sourcesImportedScripts(int count) {
    return '已导入的脚本 ($count)';
  }

  @override
  String get sourcesNoScripts =>
      '还没有导入音源脚本。社区音源可在 Github 搜索 “lx-music-source” 获取。';

  @override
  String sourcesScriptByAuthor(String author) {
    return '作者：$author';
  }

  @override
  String get sourcesScriptActions => '音源脚本操作';

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
      '音源脚本是第三方提供的可执行代码，导入后会在本机运行并联网。\n请只导入可信来源的脚本；脚本的可用性与合法性由提供者负责。';

  @override
  String get sourcesContinueImport => '继续导入';

  @override
  String sourcesImportFailed(String error) {
    return '导入失败：$error';
  }

  @override
  String get sourcesPasteTitle => '粘贴音源脚本';

  @override
  String get sourcesPasteHint => '粘贴音源脚本全文';

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
  String get searchKindSongs => '单曲';

  @override
  String get searchKindArtists => '歌手';

  @override
  String get searchKindLyrics => '歌词';

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
  String get recentlyPlayedEmpty => '播放一些歌曲后，最近听过的专辑与歌单会显示在这里。';

  @override
  String get libraryRecentPlays => '最近播放';

  @override
  String get libraryPlaylists => '我的列表';

  @override
  String get libraryImportFavorites => '导入收藏';

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
  String get trackActionsTooltip => '曲目操作';

  @override
  String get sortDefaultOrder => '默认顺序';

  @override
  String get tableColumnArtist => '艺术家';

  @override
  String get tableColumnAlbum => '专辑';

  @override
  String get tableColumnPlayedAt => '播放时间';

  @override
  String get tableColumnDuration => '时长';

  @override
  String get viewAllResults => '查看全部结果';

  @override
  String get sortByTitle => '按标题';

  @override
  String get sortByArtist => '按艺术家';

  @override
  String get playAll => '播放全部';

  @override
  String get playAllShuffled => '随机播放全部';

  @override
  String get nextTrackTooltip => '下一首';

  @override
  String get previousTrackTooltip => '上一首';

  @override
  String get playerBarVolume => '音量';

  @override
  String playerBarVolumePercent(int percent) {
    return '$percent%';
  }

  @override
  String get playerBarMute => '静音';

  @override
  String get playerBarUnmute => '取消静音';

  @override
  String get playerBarQueue => '播放队列';

  @override
  String get queuePanelNowPlaying => '正在播放';

  @override
  String get windowMinimize => '最小化';

  @override
  String get windowMaximize => '最大化';

  @override
  String get windowRestore => '还原';

  @override
  String get windowClose => '关闭';

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
  String get sourceSwap => '换源';

  @override
  String get sourceSwapSearching => '正在搜索其它音源…';

  @override
  String get sourceSwapEmpty => '其它音源没有找到这首歌';

  @override
  String get sourceSwapNoSources => '没有可用的其它音源';

  @override
  String sourceSwapFailedSources(int count) {
    return '$count 个音源搜索失败';
  }

  @override
  String get sourceSwapConfirm => '换源';

  @override
  String get sourceSwapPreviewContext => '换源试听';

  @override
  String get sourceSwapDuplicateTitle => '曲目已存在';

  @override
  String get sourceSwapDuplicateMessage => '列表里已有这首歌。换源会用它替换原来的版本。';

  @override
  String get sourceSwapDone => '已换源';

  @override
  String get sourceSwapQueueFollowed => '已换源并切换播放来源';

  @override
  String get sourceSwapNotFound => '曲目已不在原位置';

  @override
  String get sourceSwapApplyFailed => '换源失败，请稍后重试';

  @override
  String get sourceSwapTabLyrics => '歌词';

  @override
  String get sourceSwapTabAudio => '音频';

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
  String get albumEmpty => '该专辑暂无歌曲';

  @override
  String get albumLoadFailed => '专辑加载失败';

  @override
  String get artistEmpty => '该歌手暂无歌曲';

  @override
  String get artistLoadFailed => '歌手加载失败';

  @override
  String get artistNotFound => '未找到该歌手';

  @override
  String get unknownArtist => '未知歌手';

  @override
  String artistSongCount(int count) {
    return '$count 首歌曲';
  }

  @override
  String albumYear(int year) {
    return '$year 年';
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
  String get appName => 'Molia';

  @override
  String get libraryRecentContexts => '最近播放';

  @override
  String get libraryHistory => '播放历史';

  @override
  String get libraryLocalSongs => '本地歌曲';

  @override
  String get libraryImportLocalSongs => '导入本地歌曲';

  @override
  String libraryImportLocalSongsDone(int count) {
    return '已导入 $count 首';
  }

  @override
  String libraryImportLocalSongsSkipped(int imported, int skipped) {
    return '已导入 $imported 首，$skipped 个文件跳过';
  }

  @override
  String get localSongsEmpty => '还没有本地歌曲';

  @override
  String get localSongsRemove => '从列表移除';

  @override
  String get localSongsRemoveConfirm => '仅从列表移除，不会删除原文件。';

  @override
  String get libraryListEnd => '— 到底了 —';

  @override
  String get settingsCacheTitle => '缓存管理';

  @override
  String get settingsCacheSubtitle => '音频、歌词、封面的占用与清理规则';

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
  String get cachePolicyAudioScope => '听过的自动缓存';

  @override
  String get cachePolicyAudioHint => '播放时自动缓存，可离线播放，也可另存为下载；超出上限时自动清理最早的缓存。';

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
  String cacheValueGb(int value) {
    return '$value GB';
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
  String cacheAudioMaxSuggested(String value) {
    return '建议 $value';
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
  String get cacheClearAllConfirm => '清理全部缓存（音频、歌词、封面）？此操作无法撤销。';

  @override
  String get lyricsContentTitle => '歌词与输出';

  @override
  String get lyricsContentSubtitle => '歌词页、翻译、偏移等共享设置';

  @override
  String get lyricsPageTitle => '歌词页';

  @override
  String get lyricsPageTranslationSubtitle => '在歌词页每行下方显示翻译';

  @override
  String get lyricsPageRomaSubtitle => '在歌词页每行下方显示罗马音';

  @override
  String get lyricsDisplaySharedTitle => '歌词输出';

  @override
  String get lyricsDisplayTranslation => '翻译';

  @override
  String get lyricsDisplayTranslationSubtitle => '在桌面歌词、通知栏与蓝牙歌词中显示翻译';

  @override
  String get lyricsDisplayRoma => '罗马音';

  @override
  String get lyricsDisplayRomaSubtitle => '在桌面歌词、通知栏与蓝牙歌词中显示罗马音';

  @override
  String get lyricsDisplayUnsynced => '未同步歌词';

  @override
  String get lyricsDisplayUnsyncedTitle => '显示歌名';

  @override
  String get lyricsDisplayUnsyncedHide => '隐藏';

  @override
  String get lyricsDisplayUnsyncedFirstLine => '显示首行';

  @override
  String get lyricsDisplayOffset => '歌词偏移';

  @override
  String lyricsDisplayOffsetValue(int ms) {
    return '$ms 毫秒';
  }

  @override
  String get lyricsDesktopTitle => '桌面歌词';

  @override
  String get lyricsDesktopEntrySubtitle => '悬浮窗样式、行为与配色';

  @override
  String get lyricsDesktopEnable => '开启桌面歌词';

  @override
  String get lyricsDesktopEnableSubtitle => '浮在其他应用上显示当前歌词';

  @override
  String get lyricsDesktopPermissionNeeded => '需要悬浮窗权限';

  @override
  String get lyricsDesktopPermissionGrant => '去授权';

  @override
  String get lyricsDesktopPreview => '样式预览';

  @override
  String get lyricsDesktopPreviewLine => '我无法只是普通朋友';

  @override
  String get lyricsDesktopPreviewTranslation =>
      'I can\'t just be an ordinary friend';

  @override
  String get lyricsDesktopFontSize => '字号';

  @override
  String get lyricsDesktopOpacity => '透明度';

  @override
  String get lyricsDesktopWidth => '宽度';

  @override
  String get lyricsDesktopMaxLines => '显示行数';

  @override
  String get lyricsDesktopAlign => '水平对齐';

  @override
  String get lyricsDesktopAlignLeft => '左';

  @override
  String get lyricsDesktopAlignCenter => '中';

  @override
  String get lyricsDesktopAlignRight => '右';

  @override
  String get lyricsDesktopColorPlayed => '当前行颜色';

  @override
  String get lyricsDesktopColorUnplayed => '其他行颜色';

  @override
  String get lyricsDesktopColorShadow => '描边颜色';

  @override
  String get lyricsDesktopSchemeSource => '取色来源';

  @override
  String get lyricsDesktopSchemeAppTheme => '跟随应用主题';

  @override
  String get lyricsDesktopSchemeArtwork => '跟随封面';

  @override
  String get lyricsDesktopLock => '锁定位置（不挡鼠标操作）';

  @override
  String get lyricsDesktopFreeze => '息屏时暂停更新';

  @override
  String get lyricsDesktopPauseBehavior => '暂停时';

  @override
  String get lyricsDesktopHideOnPause => '暂停时隐藏';

  @override
  String get lyricsDesktopHideOnPauseSubtitle => '暂停后收起悬浮窗，恢复播放时再显示';

  @override
  String get lyricsDesktopPauseFallbackOverridden => '暂停时已隐藏整个窗口，此设置不会生效';

  @override
  String get lyricsDesktopNoLyrics => '无歌词时';

  @override
  String get lyricsDesktopAnimation => '行切换动画';

  @override
  String get lyricsDesktopScrollMode => '长行滚动';

  @override
  String get lyricsDesktopScrollModeSubtitle => '跟随演唱：文字跟着高亮走；匀速：按固定速度滚动';

  @override
  String get lyricsDesktopScrollFollow => '跟随演唱';

  @override
  String get lyricsDesktopScrollConstant => '匀速滚动';

  @override
  String get lyricsDesktopBehaviorSection => '行为与控制条';

  @override
  String get lyricsSharedDisplaySection => '歌词展示';

  @override
  String get lyricsDesktopResetPosition => '重置位置';

  @override
  String get lyricsControlPlayPause => '播放 / 暂停';

  @override
  String get lyricsControlPrevious => '上一首';

  @override
  String get lyricsControlNext => '下一首';

  @override
  String get lyricsControlTranslation => '翻译';

  @override
  String get lyricsControlLock => '锁定';

  @override
  String get lyricsControlClose => '关闭';

  @override
  String get lyricsSystemMediaTitle => '系统媒体歌词';

  @override
  String get lyricsSystemMediaSubtitle => '通知栏·锁屏与蓝牙歌词';

  @override
  String get lyricsBehaviorKeep => '保留';

  @override
  String get lyricsBehaviorTitle => '显示歌名';

  @override
  String get lyricsBehaviorClear => '清空';

  @override
  String get lyricsNotificationTitle => '通知栏 · 锁屏歌词';

  @override
  String get lyricsNotificationEnable => '在通知栏显示歌词';

  @override
  String get lyricsNotificationEnableSubtitle => '把当前歌词同步到系统播放控制';

  @override
  String get lyricsMetadataTarget => '显示在';

  @override
  String get lyricsMetadataTargetSubtitle => '副标题';

  @override
  String get lyricsMetadataTargetArtist => '艺术家';

  @override
  String get lyricsMetadataTargetTitle => '标题';

  @override
  String get lyricsMetadataTargetAlbum => '专辑';

  @override
  String get lyricsMetadataFormat => '格式';

  @override
  String get lyricsMetadataFormatLyric => '仅歌词';

  @override
  String get lyricsMetadataFormatLyricTitle => '歌词 · 歌名';

  @override
  String get lyricsMetadataFormatTitleLyric => '歌名 · 歌词';

  @override
  String get lyricsMetadataIncludeTranslation => '包含翻译';

  @override
  String get lyricsMetadataPauseBehavior => '暂停时';

  @override
  String get lyricsBluetoothTitle => '蓝牙歌词';

  @override
  String get lyricsBluetoothEnable => '车机显示歌词';

  @override
  String get lyricsBluetoothEnableSubtitle => '让车机、通知栏与锁屏显示当前歌词';

  @override
  String get lyricsBluetoothOnlyA2dp => '仅在蓝牙音频连接时生效';

  @override
  String get lyricsBluetoothStatusConnected => '已连接蓝牙音频';

  @override
  String get lyricsBluetoothStatusDisconnected => '未连接蓝牙音频';

  @override
  String get lyricsBluetoothUpdateInterval => '更新频率';

  @override
  String get lyricsBluetoothIntervalLine => '每行';

  @override
  String get lyricsBluetoothInterval1s => '每秒';

  @override
  String get lyricsBluetoothInterval2s => '每 2 秒';

  @override
  String get lyricsNotificationPermissionTitle => '需要通知权限';

  @override
  String get lyricsNotificationPermissionSubtitle => '允许通知后媒体控制才能稳定显示；点按前往系统设置';

  @override
  String get lyricsMediaSessionUnavailable => '系统媒体控制初始化失败：通知栏 / 锁屏歌词与播放控制不可用';

  @override
  String get lyricsDisplayUnsupported => '当前平台暂不支持歌词输出';

  @override
  String get colorPickerTitle => '选择颜色';

  @override
  String get colorPickerCustom => '自定义颜色…';

  @override
  String get colorPickerHex => '十六进制颜色';

  @override
  String get colorPickerInvalid => '颜色格式无效';

  @override
  String get colorPickerHue => '色相';

  @override
  String get colorPickerSaturation => '饱和度';

  @override
  String get colorPickerBrightness => '明度';

  @override
  String get colorPickerOpacity => '不透明度';

  @override
  String get lyricsColorSource => '颜色';

  @override
  String get lyricsColorSourceCustom => '自定义';

  @override
  String get lyricsColorSourcePrimary => '主色';

  @override
  String get lyricsColorSourceSecondary => '副色';

  @override
  String get lyricsColorSourceTertiary => '第三色';

  @override
  String get lyricsColorSourceOnSurface => '正文色';

  @override
  String get lyricsColorSourceOnSurfaceVariant => '次要文本色';

  @override
  String get lyricsColorSourceSurface => '表面色';

  @override
  String get lyricsDesktopColorThemeHint =>
      '「跟随应用主题」随外观设置变化；「跟随封面」按当前歌曲封面取色并实时更新。';

  @override
  String get statsTitle => '听歌统计';

  @override
  String get statsSubtitle => '播放次数、收听时长与热度分布（数据只保存在本机）';

  @override
  String get statsSettingsSubtitle => '播放次数 / 时段热力图 / 导出';

  @override
  String get statsRecordSwitch => '记录听歌统计';

  @override
  String get statsRecordSwitchSubtitle => '关闭后停止记录新的播放事件，已有数据保留';

  @override
  String get statsRangeWeek => '近 7 天';

  @override
  String get statsRangeMonth => '近 30 天';

  @override
  String get statsRangeAll => '全部';

  @override
  String get statsRangeTitle => '统计范围';

  @override
  String get statsValueDuration => '时长';

  @override
  String get statsValueCount => '次数';

  @override
  String get statsPlays => '有效播放';

  @override
  String get statsListened => '收听时长';

  @override
  String get statsTracks => '听过曲目';

  @override
  String get statsSince => '数据起始';

  @override
  String get statsCompleteRate => '完整播放率';

  @override
  String get statsSkipRate => '跳过率';

  @override
  String get statsSources => '来源分布';

  @override
  String get statsTopTracks => '最常听';

  @override
  String get statsTopArtists => '常听歌手';

  @override
  String get statsEmpty => '还没有听歌记录';

  @override
  String get statsEmptyHint => '播放几首歌后回来看看';

  @override
  String get statsExport => '导出听歌数据';

  @override
  String statsExportSubtitle(int limit) {
    return 'JSON 文件（汇总 + 最近 $limit 条明细）';
  }

  @override
  String get statsExportFailed => '导出失败';

  @override
  String get statsClear => '清空统计';

  @override
  String get statsClearConfirm => '将删除全部听歌统计事件，此操作不可撤销。';

  @override
  String get statsCleared => '已清空听歌统计';

  @override
  String statsPlaysCount(int count) {
    return '$count 次';
  }

  @override
  String statsDurationSeconds(int count) {
    return '$count 秒';
  }

  @override
  String statsDurationMinutes(int count) {
    return '$count 分钟';
  }

  @override
  String statsDurationHours(int hours, int minutes) {
    return '$hours 小时 $minutes 分';
  }

  @override
  String statsDaySummary(int count, String duration) {
    return '$count 次播放 · $duration';
  }

  @override
  String statsTooltip(String date, String value) {
    return '$date · $value';
  }

  @override
  String statsEventListened(String duration) {
    return '听了 $duration';
  }

  @override
  String get aiDjTitle => 'AI 推歌';

  @override
  String get aiDjSettingsSubtitle => '自备密钥的 AI 推荐电台';

  @override
  String get aiDjNotConfigured => '尚未配置 AI 服务';

  @override
  String get aiDjRequestFailed => 'AI 请求失败，请稍后重试';

  @override
  String get aiDjUnauthorized => 'API Key 无效或没有权限';

  @override
  String get aiDjRateLimited => 'AI 服务限流，请稍后重试';

  @override
  String get aiDjBadResponse => 'AI 返回内容无法解析';

  @override
  String get aiDjNothingResolved => '本批没有可播放的曲目';

  @override
  String get aiDjStatusOff => '未开启';

  @override
  String get aiDjStatusPreparing => '生成中…';

  @override
  String get aiDjStatusPlaying => '推歌中';

  @override
  String get aiDjStatusError => '已暂停（保留当前队列）';

  @override
  String get aiDjToggle => 'AI 推歌模式';

  @override
  String get aiDjToggleSubtitle => '开启后 AI 会持续选歌加入队列，播完自动继续';

  @override
  String get aiDjFeedMore => '再来一批';

  @override
  String get aiDjStopKeepQueue => '保留队列继续播';

  @override
  String get aiDjStopClearQueue => '清空队列并停止';

  @override
  String get aiDjStopDialogTitle => '退出 AI 推歌？';

  @override
  String get aiDjConsentTitle => '开始前确认';

  @override
  String get aiDjConsentBody =>
      '开启后会把听歌画像（统计汇总、最近 50 条播放、已听曲目）发送给你配置的 AI 服务用于生成推荐；数据直达该服务，不经过本应用，应用不含内置 Key。\n关闭后停止推荐；清除配置即断开连接。';

  @override
  String get aiDjAgree => '同意并开启';

  @override
  String get aiDjConfigTitle => 'AI 服务配置';

  @override
  String get aiDjBaseUrl => 'API 地址';

  @override
  String get aiDjApiKey => 'API Key';

  @override
  String get aiDjModel => '模型';

  @override
  String get aiDjPresetCustom => '自定义';

  @override
  String get aiDjTestConnection => '测试连接';

  @override
  String get aiDjTestSucceeded => '连接成功';

  @override
  String get aiDjTestSaved => '连接成功，配置已保存';

  @override
  String get aiDjSaveConfig => '保存配置';

  @override
  String get aiDjClearConfig => '清除配置';

  @override
  String get aiDjConfigSaved => '已保存';

  @override
  String aiDjQueued(int count) {
    return '队列中还有 $count 首推荐';
  }

  @override
  String aiDjSkippedCount(int count) {
    return '跳过 $count';
  }

  @override
  String aiDjLikedCount(int count) {
    return '收藏 $count';
  }

  @override
  String aiDjUnresolved(int count) {
    return '$count 首未找到可播放版本';
  }

  @override
  String get aiDjRetry => '重试';

  @override
  String get aiDjOpenSettings => '配置 AI 服务';

  @override
  String get aiDjDiscoverSubtitle => '用你的听歌记录让 AI 帮你选歌';

  @override
  String get aiDjGenerating => '正在生成推荐…';

  @override
  String get aiDjBatchFailed => '这批推荐没生成出来';

  @override
  String get aiDjRefreshBatch => '换一批';

  @override
  String get aiDjStatusIdle => '待机';

  @override
  String get aiDjTodayTitle => '今日推荐';

  @override
  String get aiDjViewAll => '查看全部';

  @override
  String aiDjLastUpdated(String time) {
    return '上次更新：$time';
  }

  @override
  String get aiDjUpdatedJustNow => '刚刚';

  @override
  String aiDjUpdatedMinutesAgo(int count) {
    return '$count 分钟前';
  }

  @override
  String aiDjUpdatedHoursAgo(int count) {
    return '$count 小时前';
  }

  @override
  String aiDjUpdatedYesterday(String time) {
    return '昨天 $time';
  }

  @override
  String aiDjUpdatedDate(int month, int day) {
    return '$month 月 $day 日';
  }

  @override
  String get aiDjPlayAll => '播放全部';

  @override
  String get aiDjEnqueueAll => '加入队列';

  @override
  String get aiDjInQueue => '队列中';

  @override
  String get aiDjItemActions => '推荐操作';

  @override
  String get aiDjReplaceItem => '换一首';

  @override
  String get aiDjNotInterested => '不感兴趣';

  @override
  String get aiDjFeedbackTitle => '本轮反馈';

  @override
  String get aiDjFeedbackLiked => '喜欢';

  @override
  String get aiDjFeedbackSkipped => '跳过';

  @override
  String get aiDjUpstreamTitle => '本次发送的数据';

  @override
  String aiDjUpstreamBody(int events, int artists, int exclusions) {
    return '最近 $events 条播放记录 · 常听歌手 $artists 位 · 排除已听 $exclusions 首';
  }

  @override
  String get aiDjUpstreamHint => '只发送以上统计与歌名、歌手，不含播放链接与设备信息。';

  @override
  String get aiDjGenerate => '生成推荐';

  @override
  String get aiDjEmptyList => '还没有推荐列表';

  @override
  String get aiDjEmptyListHint => '生成一批今日推荐，之后可随时播放。';

  @override
  String get aiDjEnqueueEmpty => '列表里的歌都已在队列中';

  @override
  String get aiDjPreferencesTitle => '推荐偏好';

  @override
  String get aiDjPreferencesSubtitle => '风格、场景与发送范围';

  @override
  String aiDjBatchSize(int count) {
    return '每批 $count 首';
  }

  @override
  String get aiDjBatchSizeTitle => '每批数量';

  @override
  String get aiDjFeedBatch => '补一批到队尾';

  @override
  String get aiDjSectionsNone => '仅偏好';

  @override
  String get aiDjFeedDone => '已补一批到队尾';

  @override
  String get aiDjUnresolvedRetried => '已重新搜索';

  @override
  String get aiDjHistoryTitle => '历史推荐';

  @override
  String aiDjHistoryEntry(int count) {
    return '历史推荐（$count）';
  }

  @override
  String get aiDjHistoryEmpty => '还没有历史推荐';

  @override
  String get aiDjHistoryEmptyHint => '生成推荐后，这里会保留每一批记录。';

  @override
  String get aiDjHistoryPlay => '播放这批';

  @override
  String get aiDjHistoryEnqueue => '加入队列';

  @override
  String get aiDjHistorySetActive => '设为当前';

  @override
  String get aiDjHistoryDelete => '删除这批推荐';

  @override
  String get aiDjHistoryActive => '当前';

  @override
  String get aiDjHistoryClear => '清空历史';

  @override
  String get aiDjHistoryClearTitle => '清空历史推荐？';

  @override
  String get aiDjHistoryClearBody => '只删除历史记录，不影响正在播放的队列。当前推荐会保留。';

  @override
  String get aiDjHistoryCleared => '已清空历史推荐';

  @override
  String get aiDjHistoryExpand => '查看曲目';

  @override
  String get aiDjHistoryCollapse => '收起曲目';

  @override
  String aiDjHistoryItems(int count) {
    return '$count 首';
  }

  @override
  String aiDjHistoryUnresolved(int count) {
    return '$count 首未找到';
  }

  @override
  String aiDjHistorySource(String origin) {
    return '来源：$origin';
  }

  @override
  String get aiDjOriginRefresh => '生成推荐';

  @override
  String get aiDjOriginAutoFeed => '自动补歌';

  @override
  String get aiDjOriginManualFeed => '手动补歌';

  @override
  String get aiDjOriginRestored => '旧推荐';

  @override
  String get aiDjHistoryLoadFailed => '这批内容已损坏，无法查看';

  @override
  String get aiDjMoreLikeThis => '多来点这种';

  @override
  String get aiDjRetryUnresolved => '重新找一次';

  @override
  String get aiDjTransparencyTitle => '发送给 AI 的内容';

  @override
  String get aiDjViewPrompt => '查看发送原文';

  @override
  String get aiDjSystemPrompt => '系统提示词';

  @override
  String get aiDjUserPrompt => '用户提示词';

  @override
  String get aiDjCopyPrompt => '复制';

  @override
  String get aiDjPromptCopied => '已复制';

  @override
  String get aiDjPromptTabPreview => '本次发送';

  @override
  String get aiDjPromptTabLastSent => '上次发送';

  @override
  String get aiDjPromptTabLastRaw => '上次返回';

  @override
  String get aiDjPromptUnavailable => '暂时无法生成预览';

  @override
  String get aiDjLastSentPrompt => '上次实际发送';

  @override
  String get aiDjLastRawResponse => '上次 AI 返回';

  @override
  String get aiDjNoLastPrompt => '还没有发送记录';

  @override
  String get aiDjNoLastResponse => '还没有返回记录';

  @override
  String get aiDjPromptPrivacyHint => '不含播放链接、设备信息或 API Key。';

  @override
  String aiDjSendSummary(String sections) {
    return '发送范围：$sections';
  }

  @override
  String get aiDjAutoFeedTitle => '队列快播完时自动补歌';

  @override
  String get aiDjAutoFeedSubtitle => '剩余 5 首时自动补一批，不打断播放';

  @override
  String get aiDjAutoFeedFailed => '自动补歌失败，稍后会再试';

  @override
  String aiDjAutoFeedHalted(int count) {
    return '自动补歌已暂停：连续 $count 次失败';
  }

  @override
  String get aiDjAutoFeedResume => '恢复自动补歌';

  @override
  String get aiDjGenerationStatus => '正在生成推荐';

  @override
  String get aiDjPhaseProfile => '整理听歌偏好';

  @override
  String get aiDjPhaseModel => 'AI 正在选歌';

  @override
  String aiDjPhaseResolving(int done, int total) {
    return '正在找歌 $done/$total';
  }

  @override
  String aiDjWaitingSeconds(int seconds) {
    return '已等待 $seconds 秒';
  }

  @override
  String get aiDjCancelGeneration => '停止';

  @override
  String get aiDjReplacing => '正在换…';

  @override
  String get aiDjPrefsGenerationGroup => '生成';

  @override
  String get aiDjPrefsStylesGroup => '风格';

  @override
  String get aiDjPrefsScenesGroup => '场景';

  @override
  String get aiDjPrefsLanguagesGroup => '语言';

  @override
  String get aiDjPrefsEraGroup => '年代';

  @override
  String get aiDjPrefsExtraGroup => '补充要求';

  @override
  String get aiDjPrefsExtraHint => '最多 120 字，会一起发送给 AI';

  @override
  String get aiDjPrefsOnlyUnheardTitle => '只推荐没听过的';

  @override
  String get aiDjPrefsOnlyUnheardSubtitle => '排除听过的曲目';

  @override
  String get aiDjPrefsExplorationTitle => '探索度';

  @override
  String get aiDjExplorationSafe => '稳妥';

  @override
  String get aiDjExplorationBalanced => '均衡';

  @override
  String get aiDjExplorationSurprise => '惊喜';

  @override
  String get aiDjStylePop => '流行';

  @override
  String get aiDjStyleRock => '摇滚';

  @override
  String get aiDjStyleElectronic => '电子';

  @override
  String get aiDjStyleFolk => '民谣';

  @override
  String get aiDjStyleRap => '说唱';

  @override
  String get aiDjStyleRnb => 'R&B';

  @override
  String get aiDjStyleJazz => '爵士';

  @override
  String get aiDjStyleClassical => '古典';

  @override
  String get aiDjStyleMetal => '金属';

  @override
  String get aiDjStyleAcg => 'ACG';

  @override
  String get aiDjStyleInstrumental => '纯音乐';

  @override
  String get aiDjStyleChineseStyle => '国风';

  @override
  String get aiDjSceneCommute => '通勤';

  @override
  String get aiDjSceneFocus => '专注';

  @override
  String get aiDjSceneRelax => '放松';

  @override
  String get aiDjSceneWorkout => '运动';

  @override
  String get aiDjSceneSleep => '睡前';

  @override
  String get aiDjSceneWeekend => '周末';

  @override
  String get aiDjLanguageMandarin => '华语';

  @override
  String get aiDjLanguageCantonese => '粤语';

  @override
  String get aiDjLanguageEnglish => '英语';

  @override
  String get aiDjLanguageJapanese => '日语';

  @override
  String get aiDjLanguageKorean => '韩语';

  @override
  String get aiDjLanguageInstrumental => '纯音乐';

  @override
  String get aiDjEraAny => '不限';

  @override
  String get aiDjEraRecent3 => '近三年';

  @override
  String get aiDjEra2010s => '2010s';

  @override
  String get aiDjEra2000s => '2000s';

  @override
  String get aiDjEraBefore90 => '90 年代及更早';

  @override
  String get aiDjPrefsAutoSaveHint => '修改会立即保存，下一批生成时生效。';

  @override
  String get aiDjPrefsReset => '恢复默认';

  @override
  String get aiDjPrefsResetTitle => '恢复默认偏好？';

  @override
  String get aiDjPrefsResetBody => '风格、场景与发送范围会恢复默认；已保存的推荐不受影响。';

  @override
  String get aiDjPrefsResetDone => '已恢复默认偏好';

  @override
  String get aiDjPrefsDataScope => '发送范围';

  @override
  String get aiDjScopeHint => '关闭的项不会发送；收藏和歌单默认关闭。';

  @override
  String get aiDjScopeSummary => '汇总统计';

  @override
  String get aiDjScopeTopArtists => '常听歌手';

  @override
  String get aiDjScopeTopTracks => '常听歌曲';

  @override
  String get aiDjScopeTimeAndSource => '时段与来源分布';

  @override
  String get aiDjScopeRecentEvents => '最近播放明细';

  @override
  String get aiDjScopeListenedExclusions => '已听歌曲排除清单';

  @override
  String get aiDjScopeFavorites => '收藏歌曲';

  @override
  String get aiDjScopePlaylists => '自建歌单';

  @override
  String get aiDjScopeFavoritesConfirm =>
      '会读取收藏歌曲的歌名与歌手（最多 100 首），用来避免推荐已经收藏的歌。';

  @override
  String get aiDjScopePlaylistsConfirm =>
      '会读取自建歌单的名称与曲目歌名、歌手（最多 10 个歌单），用来避免重复推荐。';

  @override
  String get aiDjSeedsTitle => '多来点这种';

  @override
  String get aiDjSeedsHint => '下一批生成成功后会清空';

  @override
  String get aiDjSeedsEmpty => '还没有「多来点这种」';

  @override
  String get aiDjClearMemory => '清空 AI 记忆';

  @override
  String get aiDjClearMemoryTitle => '清空 AI 记忆？';

  @override
  String get aiDjClearMemoryBody => '会删除长期保留的「不感兴趣」「喜欢」与「多来点这种」，本轮反馈也会清空。';

  @override
  String get aiDjMemoryCleared => '已清空 AI 记忆';

  @override
  String get aiDjFeedbackMemory => '长期记忆';

  @override
  String get aiDjFeedbackThisRound => '本轮';

  @override
  String aiDjSeedLabel(String label) {
    return '多来点 · $label';
  }

  @override
  String get settingsSyncTitle => '跨设备同步';

  @override
  String get settingsSyncItemSubtitle => '歌单、音源、设置与密钥';

  @override
  String get syncLocalSection => '本机';

  @override
  String get syncLocalSectionHint => '其它设备需要这些信息才能连上本机；这些地址也用于附近设备配对。';

  @override
  String get syncDeviceNameTitle => '设备名称';

  @override
  String get syncPassphraseTitle => '同步口令';

  @override
  String get syncPassphraseNotSet => '未设置';

  @override
  String get syncPassphraseTrustHint => '知道口令的设备可以读写全部同步数据；怀疑泄露请重置。';

  @override
  String get syncPassphraseCopy => '复制口令';

  @override
  String get syncPassphraseReset => '重置口令';

  @override
  String get syncPassphraseResetConfirm => '重置后所有设备需重新输入新口令，确定继续？';

  @override
  String get syncPassphraseInvalid => '口令无效（至少 16 位）';

  @override
  String get syncSave => '保存';

  @override
  String get syncNever => '尚未同步';

  @override
  String syncStatusSyncedPeers(int count) {
    return '已与 $count 台设备同步';
  }

  @override
  String get syncRelativeJustNow => '刚刚';

  @override
  String syncRelativeMinutes(int count) {
    return '$count 分钟前';
  }

  @override
  String syncRelativeHours(int count) {
    return '$count 小时前';
  }

  @override
  String syncRelativeDays(int count) {
    return '$count 天前';
  }

  @override
  String get syncOutcomeOk => '同步完成';

  @override
  String get syncOutcomeNoChanges => '无变化';

  @override
  String get syncOutcomeNoPeers => '未发现其它设备';

  @override
  String get syncOutcomePartial => '部分失败';

  @override
  String get syncOutcomeFailed => '同步失败';

  @override
  String get syncTriggerStartup => '启动';

  @override
  String get syncTriggerDebounce => '数据有变化';

  @override
  String get syncTriggerTimer => '定时';

  @override
  String get syncTriggerIncoming => '其它设备发来';

  @override
  String get syncTriggerResume => '回前台';

  @override
  String get syncTriggerPause => '退后台前';

  @override
  String get syncTriggerNetwork => '网络切换';

  @override
  String get syncTriggerDiscovery => '发现设备';

  @override
  String get syncTriggerCheck => '打开同步页';

  @override
  String get syncTriggerManual => '手动';

  @override
  String get syncActivitySection => '运行状态';

  @override
  String get syncActivityTitle => '近 24 小时';

  @override
  String syncActivityRounds(int rounds, int effective, String bytes) {
    return '运行 $rounds 次，其中 $effective 次有变化 · 流量 $bytes';
  }

  @override
  String syncActivityEnvironment(
      String level, String network, String powerSave) {
    return '$level · $network · $powerSave';
  }

  @override
  String get syncLevelActive => '活跃';

  @override
  String get syncLevelIdle => '空闲';

  @override
  String get syncLevelBackground => '后台';

  @override
  String get syncLevelPowerSave => '省电';

  @override
  String get syncLevelUnknown => '未运行';

  @override
  String get syncNetworkCellular => '移动数据';

  @override
  String get syncNetworkOther => 'Wi-Fi / 其它';

  @override
  String get syncPowerSaveOn => '省电模式';

  @override
  String get syncPowerSaveOff => '非省电';

  @override
  String get syncCellularSection => '移动数据';

  @override
  String get syncCellularPauseTitle => '移动数据下暂停自动同步';

  @override
  String get syncCellularPauseSubtitle => '关闭后，移动数据下只同步设置、歌单等小数据，统计与历史等 Wi-Fi';

  @override
  String syncAppliedItems(int applied) {
    return '已更新 $applied 项';
  }

  @override
  String syncPeerCount(int count) {
    return '$count 台设备';
  }

  @override
  String syncFailedCount(int count) {
    return '$count 项失败';
  }

  @override
  String syncBytes(String inbound, String outbound) {
    return '↓$inbound ↑$outbound';
  }

  @override
  String get syncRetry => '重试';

  @override
  String get syncContentSection => '同步内容';

  @override
  String get syncContentAllOn => '全部类别';

  @override
  String syncContentOffCount(int count) {
    return '已关闭 $count 项';
  }

  @override
  String get syncCategoryPlaylists => '歌单与收藏';

  @override
  String get syncCategorySources => '音源（脚本与配置）';

  @override
  String get syncCategorySettings => '应用设置';

  @override
  String get syncCategoryCovers => '自定义封面';

  @override
  String get syncCategoryStatistics => '听歌统计';

  @override
  String get syncCategoryHistory => '播放历史';

  @override
  String get syncCategorySession => '上次播放状态';

  @override
  String get syncCategoryCredentials => 'AI 推歌与密钥';

  @override
  String get syncTransportSection => '传输方式';

  @override
  String get syncTransportAllOffHint => '两种方式都关闭时不会同步；打开任一开关即可开始。';

  @override
  String get syncLanTitle => '局域网直连';

  @override
  String get syncWebdavTitle => 'WebDAV / 云盘';

  @override
  String get syncWebdavConfigTitle => 'WebDAV 配置';

  @override
  String get syncWebdavServer => '服务器地址';

  @override
  String get syncWebdavUsername => '用户名';

  @override
  String get syncWebdavPassword => '密码';

  @override
  String get syncWebdavRemoteDir => '云端目录';

  @override
  String get syncWebdavNotConfigured => '未配置';

  @override
  String get syncTransportRunning => '运行中';

  @override
  String get syncTransportStopped => '未运行';

  @override
  String get syncTransportDisabled => '已关闭';

  @override
  String get syncTransportNotConfigured => '未配置';

  @override
  String get syncTransportStartFailed => '启动失败';

  @override
  String get syncLogTitle => '同步日志';

  @override
  String get syncLogSection => '同步日志';

  @override
  String get syncLogEmpty => '暂无记录';

  @override
  String syncLogFailed(String error) {
    return '失败：$error';
  }

  @override
  String get syncAdvancedTitle => '高级设置';

  @override
  String get syncAdvancedSubtitle => '设备名、口令与网络地址';

  @override
  String get syncPeersSection => '设备';

  @override
  String get syncPeersHint => '打开局域网同步后，在「附近设备」里点击设备即可配对；找不到时请检查局域网权限，或改用手动地址。';

  @override
  String get syncPeersEmptyTitle => '还没有配对设备';

  @override
  String get syncPeersEmptySubtitle => '在「附近设备」里点击配对，或在高级设置里手动添加地址';

  @override
  String get syncNearbySection => '附近设备';

  @override
  String get syncNearbyTapToPair => '点击配对';

  @override
  String get syncNearbyHasGroup => '对方已在同步组中';

  @override
  String get syncNearbyLanOffTitle => '局域网同步未开启';

  @override
  String get syncNearbyLanOffHint => '打开上方的「局域网」开关后，附近设备会显示在这里。';

  @override
  String get syncNearbySearching => '正在查找附近设备…';

  @override
  String get syncNearbySearchHint => '请确认对方已打开 Molia 并开启局域网同步';

  @override
  String get syncNearbyRescan => '重新查找';

  @override
  String get syncNearbyEmptyTitle => '没有发现设备';

  @override
  String get syncNearbyEmptyHint => '让对方打开 Molia 并开启局域网同步';

  @override
  String get syncNearbyFooter =>
      '只接受你认识的设备；接受后对方可读取全部同步数据（含密钥）。找不到时可在高级设置手动添加地址。';

  @override
  String syncNearbyPairTitle(String name) {
    return '与「$name」配对';
  }

  @override
  String get syncNearbyContacting => '正在联系对方…';

  @override
  String get syncNearbyCodeLabel => '确认码';

  @override
  String get syncNearbyCheckCode => '请核对对方屏幕上的数字是否一致';

  @override
  String get syncNearbyWaiting => '等待对方接受…';

  @override
  String get syncNearbyJoined => '已加入同步组';

  @override
  String get syncNearbySameGroup => '已在同一同步组';

  @override
  String get syncNearbyResultRejected => '对方拒绝了配对请求，可以稍后重试。';

  @override
  String get syncNearbyResultExpired => '配对请求已过期，请重新点击设备配对。';

  @override
  String get syncNearbyResultConflict => '两台设备已在不同的同步组，请先重置其中一台的同步口令再试。';

  @override
  String get syncNearbyResultUnreachable => '连不上这台设备，请确认两台设备在同一网络且都开启了局域网同步。';

  @override
  String get syncNearbyResultBusy => '对方正在处理另一条配对请求，请稍后再试。';

  @override
  String get syncNearbyResultUnsupported => '这台设备暂不支持一键配对，请更新 Molia 后重试。';

  @override
  String get syncNearbyResultUnavailable => '配对暂时不可用，请确认两台设备都开启了局域网同步后重试。';

  @override
  String get syncNearbyResultCancelled => '已取消配对，需要时可以重新点击设备。';

  @override
  String syncNearbyIncomingJoinTitle(String name) {
    return '「$name」请求加入同步组';
  }

  @override
  String syncNearbyIncomingInviteTitle(String name) {
    return '「$name」邀请你加入同步组';
  }

  @override
  String get syncNearbyIncomingJoinWarning =>
      '接受后，对方可读取全部同步数据（含音源脚本和密钥）。只接受你认识的设备。';

  @override
  String get syncNearbyIncomingInviteWarning =>
      '接受后将加入对方的同步组，本机改用对方的同步口令；对方可读取全部同步数据（含音源脚本和密钥）。';

  @override
  String get syncNearbyAccept => '接受';

  @override
  String get syncNearbyReject => '拒绝';

  @override
  String get syncNearbyIncomingRejected => '已拒绝配对请求';

  @override
  String get syncNearbyIncomingExpired => '配对请求已过期';

  @override
  String get syncNearbyIncomingFailed => '配对没有完成，让对方重新发起。';

  @override
  String get syncNearbyIncomingNotCompleted =>
      '已接受，但对方还没有完成配对；如果对方没加入，请让对方重新发起。';

  @override
  String get syncNearbyManualProbeSent => '正在查找这台设备；出现在「附近设备」后点击即可配对';

  @override
  String syncPeerThisDevice(String id) {
    return '本机 · $id';
  }

  @override
  String get syncPeerThisDeviceTitle => '本机设备 ID';

  @override
  String get syncPeerNever => '还没连上';

  @override
  String get syncSyncing => '正在同步…';

  @override
  String syncPeerConnectedSince(String time) {
    return '已连接 · 上次同步 $time';
  }

  @override
  String syncPeerDisconnectedSince(String time) {
    return '未连接 · 上次同步 $time';
  }

  @override
  String syncPeerCloudSyncedSince(String time) {
    return '云端已同步 · 上次同步 $time';
  }

  @override
  String syncPeerCloudNotSyncedSince(String time) {
    return '云端未同步 · 上次同步 $time';
  }

  @override
  String syncPeerLastSuccess(String time) {
    return '上次同步 $time';
  }

  @override
  String syncPeerLastAttempt(String time) {
    return '上次尝试 $time';
  }

  @override
  String syncPeerLostSince(String time) {
    return '已失联 · 上次同步 $time';
  }

  @override
  String get syncPeerNameSeparator => '、';

  @override
  String get syncRoundNoConnectedPeers => '本轮没有连上设备';

  @override
  String get syncRoundNoRecords => '还没有连接记录';

  @override
  String syncRoundSynced(String names) {
    return '本轮已同步 $names';
  }

  @override
  String syncRoundSyncedMore(String names, int count) {
    return '本轮已同步 $names，另有 $count 台';
  }

  @override
  String syncPeerBehind(int count) {
    return '待同步 $count 项';
  }

  @override
  String syncPeerBehindBytes(int count, String size) {
    return '待同步 $count 项（约 $size）';
  }

  @override
  String syncPeerClockSkew(int minutes) {
    return '设备时间相差 $minutes 分钟';
  }

  @override
  String syncPeerLastError(String error) {
    return '最近失败：$error';
  }

  @override
  String get syncTransportPermissionDenied => '缺少局域网权限';

  @override
  String get syncLanPermissionTitle => '授予局域网权限';

  @override
  String get syncLanPermissionSubtitle => 'Android 17 起访问局域网设备需要「附近设备」权限';

  @override
  String get syncLanPermissionDenied => '未获得权限：局域网同步不可用（手动填地址同样无效），可改用 WebDAV';

  @override
  String get syncLanPermissionNeeded => '需要局域网权限';

  @override
  String get syncLanPermissionGrant => '去授权';

  @override
  String get syncOpenSystemSettings => '去系统设置';

  @override
  String get syncPeerHostLabel => '地址';

  @override
  String get syncPeerHostHint => '例如 192.168.1.23 或 2409:8a55::5';

  @override
  String get syncPeerNameLabel => '名称（可选）';

  @override
  String get syncPeerHostInvalid => '地址不能为空';

  @override
  String get syncPeerDelete => '移除设备';

  @override
  String get syncPeerDeleteConfirm =>
      '只从本机列表移除，不撤销对方的同步授权。对方如果仍持有同步口令并在线，会再次出现；要停止与它同步，请更换同步口令。';

  @override
  String get syncPeerRemoved => '已从本机移除';

  @override
  String get syncPeerManual => '手动添加';

  @override
  String get syncPeerLost => '已失联';

  @override
  String get syncPeerLostHint =>
      '该设备已超过 180 天没有连接（可能已重装或不再使用）。可以从本机移除，或清理它在云端的同步文件；本机数据不受影响。';

  @override
  String get syncPeerCleanupRemote => '清理云端文件';

  @override
  String get syncPeerCleanupRemoteHint => '删除该设备在 WebDAV 上的同步文件';

  @override
  String get syncPeerCleanupRemoteConfirm =>
      '将删除该设备在 WebDAV 上的同步文件，本机数据不受影响；该设备重新上线后会再写入。局域网直连无需清理。';

  @override
  String get syncPeerCleanupRemoteDone => '已清理云端文件';

  @override
  String get syncPeerCleanupRemoteNone => '没有可清理的云端文件';

  @override
  String syncPeerCleanupRemoteFailed(Object error) {
    return '清理失败：$error';
  }

  @override
  String get syncPeerNotContacted => '还没连上，设备上线后会自动重试';

  @override
  String syncPeerCandidatesTitle(int count) {
    return '可用地址 $count 个';
  }

  @override
  String get syncPeerCandidatesSubtitle => '还没连上 · 点开可查看或删除';

  @override
  String get syncLocalAddressCopied => '已复制地址';

  @override
  String get syncLocalAddressesEmptyTitle => '没有可用的网络地址';

  @override
  String get syncLocalAddressesHint => '这些地址用于附近设备连接本机。';

  @override
  String get syncLocalAddressesEmpty => '没有找到可用的局域网地址，请检查网络连接。';

  @override
  String get syncLocalProbePort => '发现端口';

  @override
  String get syncLocalProbePortUnavailable => '不可用；请手动添加设备地址';

  @override
  String syncLocalProbePortPerFamily(String v4, String v6) {
    return '$v4（IPv4）/ $v6（IPv6）';
  }

  @override
  String get syncLocalHttpPort => '连接端口';

  @override
  String get syncLocalHttpPortUnavailable => '尚未启动';

  @override
  String syncPeerDeviceId(String id) {
    return '设备 $id';
  }

  @override
  String get syncDeviceNameDialogTitle => '设备名称';

  @override
  String get syncRenameHint => '其它设备上显示的名称';

  @override
  String get syncDeviceNameEmpty => '名称不能为空';

  @override
  String get syncCategorySubtitle => '关闭后本机不再上传或接收该类数据';

  @override
  String get syncIssueDialogTitle => '同步问题';

  @override
  String get syncIssueUnknown => '未知原因；可先重试，持续失败可查看同步日志排查';

  @override
  String get syncIssueNotConfigured => '同步传输尚未配置';

  @override
  String get syncIssueStartFailed => '传输启动失败';

  @override
  String get syncIssuePermissionDenied => '缺少局域网权限（Android 17 起需「附近设备」权限）';

  @override
  String get syncIssueNoPassphrase => '尚未设置同步口令';

  @override
  String get syncIssueAllPeersUnreachable => '所有设备都连不上';

  @override
  String get syncIssuePullFailed => '读取同步数据失败';

  @override
  String get syncIssuePushFailed => '上传本机改动失败';

  @override
  String syncIssueApplyFailed(int count) {
    return '接收同步数据失败 $count 次';
  }

  @override
  String syncIssuePeerReadFailed(String peer) {
    return '$peer：读取同步数据失败';
  }

  @override
  String syncIssuePeerDecryptFailed(String peer) {
    return '$peer：口令不一致或数据损坏';
  }

  @override
  String syncIssuePeerPushFailed(String peer) {
    return '$peer：上传失败';
  }

  @override
  String get syncIssueBroadcastUnavailable => '自动发现失败（被网络策略拦截）';

  @override
  String get syncIssueProbePortUnavailable => '自动发现不可用，请用「添加设备」手动填写地址';

  @override
  String get syncIssueDiscoverySilent => '没有发现其它设备（可能被网络隔离）';

  @override
  String get syncIssueWebdavDirFailed => 'WebDAV 目录不可用';

  @override
  String get syncIssueWebdavListFailed => 'WebDAV 目录读取失败';

  @override
  String syncIssueWebdavReadFailed(String peer) {
    return '$peer：读取同步数据失败';
  }

  @override
  String syncIssueWebdavDecryptFailed(String peer) {
    return '$peer：口令不一致或数据损坏';
  }

  @override
  String get syncIssueWebdavUploadFailed => 'WebDAV 同步数据上传失败';

  @override
  String syncIssueDeleteRemoteFailed(String peer) {
    return '清理设备 $peer 的云端文件失败';
  }

  @override
  String get syncIssueInternal => '同步出错';

  @override
  String get syncActionGrantPermission => '授予权限';

  @override
  String get syncActionConfigure => '去配置';

  @override
  String get syncActionConfigurePassphrase => '去设置口令';

  @override
  String get syncActionAddManualPeer => '添加手动地址';

  @override
  String get syncActionUseWebdav => '改用 WebDAV';

  @override
  String get syncWebdavEnabled => '已启用 WebDAV';

  @override
  String get syncConfigureOnSettingsPage => '请在同步设置页设置口令';

  @override
  String get syncPeerUnknown => '未知设备';

  @override
  String get syncPeerDeviceIdCopied => '已复制完整设备 ID';

  @override
  String get syncPeerHostFormatInvalid => '地址格式不正确（支持 IP 或域名，不含端口）';

  @override
  String get syncPeerPortInvalid => '端口需为 1–65535';

  @override
  String get syncPeerAdded => '已添加设备';

  @override
  String get syncPeerUpdated => '设备已更新';

  @override
  String get syncPeerUnreachable => '没连上：确认设备在线且在同一网络，或更新它的地址';

  @override
  String get syncPeerProbePortLabel => '发现端口';

  @override
  String syncPeerProbePortHint(int port) {
    return '默认 $port';
  }

  @override
  String get syncPeerAlreadyAdded => '该地址已在列表中，已更新名称与端口';

  @override
  String get syncManualConnect => '手动连接';

  @override
  String get syncManualConnectSubtitle => '自动发现失败时，手动填写设备地址';

  @override
  String get syncManualConnectHint => '自动发现失败时在这里填写地址；未配对的设备会出现在「附近设备」，点击即可配对。';

  @override
  String get syncNetworkAddresses => '网络地址';

  @override
  String syncNetworkAddressesCount(int count) {
    return '$count 个可用地址';
  }

  @override
  String syncPeerAddressCount(int count) {
    return '$count 条地址';
  }

  @override
  String get syncPeerAddressEdit => '更新地址';

  @override
  String get syncPeerAddressDelete => '删除该地址';

  @override
  String get syncPeerAddressDeleteConfirm => '从地址簿移除该地址；已连上的设备不受影响。';

  @override
  String get syncPeerAddressUpdated => '地址已更新';

  @override
  String get syncPeerAddressRemoved => '已从地址簿移除';

  @override
  String get syncPeerContactQueued => '已添加设备，稍后自动连接';

  @override
  String syncPeerAddedOffline(String name) {
    return '已添加「$name」；暂时没连上，稍后自动重试';
  }

  @override
  String syncPeerConnected(String name) {
    return '已与「$name」连通';
  }

  @override
  String get syncPeerContacting => '正在连接…';

  @override
  String get syncLanPermissionPermanentSubtitle => '权限已被永久拒绝，请到系统设置开启「附近设备」权限';

  @override
  String get syncLogHint => '最近几轮同步结果；失败行可点开查看原因与下一步';

  @override
  String get settingsUpdateTitle => '关于与更新';

  @override
  String settingsUpdateSubtitle(String version) {
    return '当前版本 $version';
  }

  @override
  String settingsUpdateAvailable(String version) {
    return '可更新至 $version';
  }

  @override
  String get updateSettingsSection => '更新';

  @override
  String get updateChannelTitle => '更新渠道';

  @override
  String get updateChannelSubtitle => '稳定版只收正式发布，测试版提前体验';

  @override
  String get updateChannelStable => '稳定版';

  @override
  String get updateChannelBeta => '测试版';

  @override
  String get updateAutoCheckTitle => '自动检查更新';

  @override
  String get updateAutoCheckSubtitle => '启动时静默检查，每天最多一次';

  @override
  String get updateCheckTitle => '检查更新';

  @override
  String get updateStatusIdle => '尚未检查';

  @override
  String get updateStatusChecking => '正在检查…';

  @override
  String get updateStatusUpToDate => '已是最新版本';

  @override
  String updateStatusAvailable(String version) {
    return '发现新版本 $version';
  }

  @override
  String get updateStatusDownloading => '正在下载…';

  @override
  String get updateStatusDownloaded => '安装包已就绪';

  @override
  String get updateStatusInstalling => '正在安装…';

  @override
  String updateLastChecked(String time) {
    return '上次检查：$time';
  }

  @override
  String get updateReleaseSection => '新版本';

  @override
  String updateReleaseTitle(String version) {
    return 'Molia $version';
  }

  @override
  String updateReleaseDate(String date) {
    return '发布于 $date';
  }

  @override
  String get updateReleaseDateUnknown => '发布时间未知';

  @override
  String get updateCancelDownload => '取消下载';

  @override
  String get updateInstallingHint => '已交给安装程序，按系统提示完成即可。';

  @override
  String get updateIosHint => 'iOS 通过 App Store 更新，应用内不提供安装。';

  @override
  String get updateGrantInstallPermission => '去授权';

  @override
  String get updateInstallNow => '立即安装';

  @override
  String get updateDownloadAndInstall => '下载并安装';

  @override
  String get updateOpenDownloadPage => '打开下载页';

  @override
  String get updateAdvancedSection => '高级';

  @override
  String get updateManifestOverrideTitle => '更新信息地址';

  @override
  String get updateManifestOverrideDefault => '默认（官方 GitHub Release）';

  @override
  String get updateManifestOverrideHint => '留空使用官方地址';

  @override
  String get updateDownloadPrefixTitle => '下载镜像前缀';

  @override
  String get updateDownloadPrefixDefault => '默认（GitHub 直连）';

  @override
  String get updateDownloadPrefixHint =>
      '如 https://gh-proxy.com/（非官方镜像请自行确认可信）';

  @override
  String get updateAboutSection => '关于';

  @override
  String get updateCurrentVersion => '当前版本';

  @override
  String get updatePlatformTitle => '平台';

  @override
  String get updateGithubTitle => 'GitHub 项目主页';

  @override
  String get updateErrorNetwork => '网络错误，检查更新失败';

  @override
  String get updateErrorManifest => '更新信息无效';

  @override
  String get updateErrorUnsupported => '当前平台不支持应用内更新';

  @override
  String get updateErrorChecksum => '安装包校验失败，已删除';

  @override
  String get updateErrorPermission => '需要允许「安装未知应用」才能自动安装';

  @override
  String get updateErrorNotWritable => '安装目录不可写，请手动下载覆盖安装';

  @override
  String get updateErrorInstall => '安装失败';

  @override
  String updateDownloadProgress(
      String percent, String receivedMb, String speedMb) {
    return '已下载 $percent%（$receivedMb MB，$speedMb MB/s）';
  }

  @override
  String get trackInfoTabTitle => '详细';

  @override
  String get trackInfoEmpty => '暂无播放曲目';

  @override
  String get trackInfoQuality => '本次播放音质';

  @override
  String get trackInfoQualityAvailable => '可用音质';

  @override
  String get trackInfoQualityUnknown => '未知';

  @override
  String get trackInfoChannel => '渠道';

  @override
  String get trackInfoChannelUnknown => '未知渠道';

  @override
  String get trackInfoAlbum => '专辑';

  @override
  String get trackInfoArtist => '歌手';

  @override
  String get trackInfoDuration => '时长';

  @override
  String get trackInfoTrackId => '曲目 ID';

  @override
  String get trackInfoIdCopied => '曲目 ID 已复制';

  @override
  String get localDataTitle => '本地数据';

  @override
  String get trackInfoCacheResolve => '播放链接缓存';

  @override
  String get trackInfoCacheNone => '无缓存';

  @override
  String trackInfoCacheEntries(int count) {
    return '$count 条';
  }

  @override
  String trackInfoCacheCleared(String size) {
    return '已清理 $size';
  }

  @override
  String get trackInfoCachePlaying => '正在播放，音频缓存稍后再清';

  @override
  String get trackActionCommentsSubtitle => '热门与最新评论';

  @override
  String get trackActionSwapSubtitle => '跨音源找回音频或歌词';

  @override
  String get trackInfoSource => '来源';

  @override
  String get trackInfoLyricsSource => '歌词来源';

  @override
  String get trackInfoLyricsSourceNone => '暂无歌词';

  @override
  String get trackInfoAlbumOpen => '查看专辑';

  @override
  String get trackInfoArtistOpen => '查看歌手';

  @override
  String get trackInfoSourceUnknownId => '未知曲目 ID';

  @override
  String get sharePlatformPage => '分享平台页面';

  @override
  String get openPlatformPage => '打开平台页面';

  @override
  String get shareTrackFile => '分享歌曲文件';

  @override
  String get downloadAndShare => '下载并分享';

  @override
  String get platformPageUnavailable => '当前音源没有平台页面';

  @override
  String get shareDownloading => '正在下载，完成后自动分享';

  @override
  String get localDataCacheSection => '缓存占用';

  @override
  String get localDataStateCached => '已缓存';

  @override
  String get localDataOfflineAvailable => '可离线使用';

  @override
  String get localDataTransferToFolder => '转存到本地文件夹';

  @override
  String get localDataTransferHint => '已缓存 · 转存不触网';

  @override
  String get localDataAudioPlatformHint => '当前平台播放时不会写入缓存；播放后会补上缓存';

  @override
  String get trackCacheClearAll => '全部清理';

  @override
  String trackCacheClearConfirm(String part) {
    return '清理「$part」？';
  }

  @override
  String get trackCacheClearAllConfirm => '清理这首歌的全部缓存？';

  @override
  String get trackCacheClearHint => '只清理缓存，不影响已下载文件与当前播放。';

  @override
  String cacheClearPart(String part) {
    return '清理「$part」？';
  }

  @override
  String get clear => '清理';

  @override
  String get trackCacheEmpty => '这首歌没有缓存';

  @override
  String trackCacheAudioWriting(String size) {
    return '音频写入中 $size';
  }

  @override
  String get cacheAudioDisabled => '音频缓存已关闭';

  @override
  String get downloadAudioSection => '音频';

  @override
  String get downloadQualityLabel => '音质';

  @override
  String get downloadQualityCached => '已缓存';

  @override
  String get downloadExtrasSection => '附加内容';

  @override
  String get downloadCoverPart => '封面';

  @override
  String get downloadPartDownload => '单独下载';

  @override
  String get downloadPartRemove => '清理';

  @override
  String get downloadAll => '全部下载';

  @override
  String get downloadFromCache => '已有本地缓存，无需下载';

  @override
  String get downloadLyricsDone => '歌词已下载';

  @override
  String get downloadCoverDone => '封面已下载';

  @override
  String get downloadNoArtwork => '这首歌没有封面';

  @override
  String get downloadNoLyrics => '未找到歌词';

  @override
  String get downloadSettingsTitle => '下载设置';

  @override
  String get downloadSettingsSubtitle => '保存位置、文件名与标签嵌入';

  @override
  String get downloadSaveLocation => '保存位置';

  @override
  String get downloadSaveLocationDefault => '默认（系统「下载」目录）';

  @override
  String get downloadSaveLocationSharedHint => '下载与导出都保存到这里';

  @override
  String get downloadSaveLocationAndroid => '系统「下载」› Molia';

  @override
  String get downloadSaveLocationIos => '文件 App › 我的 iPhone › Molia';

  @override
  String get downloadSaveLocationFixedHintAndroid =>
      '播放副本在应用内；下载完成后在系统「下载」另存一份';

  @override
  String get downloadSaveLocationFixedHintAndroidOff =>
      '公共副本已关闭；文件只在应用内，可在下方打开「发布到公共下载目录」';

  @override
  String get downloadSaveLocationFixedHintIos =>
      '文件可在「文件」App › 我的 iPhone › Molia 中找到';

  @override
  String get downloadPickDirectory => '选择目录';

  @override
  String get downloadFilenameTemplate => '文件名格式';

  @override
  String get downloadFilenameTemplateHint =>
      '可用变量：artist（歌手）/ title（歌名）/ album（专辑）';

  @override
  String get downloadFilenamePreview => '预览';

  @override
  String get downloadReset => '恢复默认';

  @override
  String get downloadEmbedTags => '嵌入歌词与封面标签';

  @override
  String get downloadEmbedTagsSubtitle =>
      '写入音频标签（MP3 / FLAC），其它播放器也能读到；失败时保留原文件';

  @override
  String get downloadPublishToPublicDir => '发布到公共下载目录';

  @override
  String get downloadPublishToPublicDirSubtitle =>
      '完成后另存一份到系统「下载」目录（Android），文件管理器与其它播放器可见';

  @override
  String get downloadNotifications => '下载通知';

  @override
  String get downloadNotificationsSubtitle =>
      '在通知栏显示下载进度，退到后台也能继续（Android，需要通知权限）';

  @override
  String get downloadLocationInfo => '下载目录';

  @override
  String get downloadPlaybackLocation => '播放副本';

  @override
  String get downloadPublicCopyLocation => '另存目录';

  @override
  String get downloadLocationUnsupported => '当前平台不支持下载';

  @override
  String get save => '保存';

  @override
  String get lyricsEmptyState => '暂时没找到歌词，换个来源试试？';

  @override
  String get lyricsDisplaySettingsAction => '歌词显示设置';

  @override
  String get lyricsSwapAction => '换歌词';

  @override
  String get lyricsCopyModeAction => '复制歌词模式';

  @override
  String get lyricsCopyModeExit => '退出复制模式';

  @override
  String get commentsTitle => '评论';

  @override
  String get commentsTabHot => '热门';

  @override
  String commentsTabHotCount(int count) {
    return '热门 ($count)';
  }

  @override
  String get commentsTabLatest => '最新';

  @override
  String commentsTabLatestCount(int count) {
    return '最新 ($count)';
  }

  @override
  String get commentsEmpty => '还没有评论';

  @override
  String get commentsUnsupported => '当前渠道不支持评论';

  @override
  String get commentsLoadFailed => '评论加载失败';

  @override
  String get commentsPullToRetry => '下拉刷新重试';

  @override
  String get commentsLoadMoreFailed => '加载更多评论失败';

  @override
  String get commentsNoMore => '没有更多评论了';

  @override
  String commentsIpLocation(String location) {
    return 'IP 属地：$location';
  }

  @override
  String commentsQuotedAuthor(String name) {
    return '$name：';
  }

  @override
  String commentsLikedCount(int count) {
    return '$count 赞';
  }

  @override
  String get commentsTimeJustNow => '刚刚';

  @override
  String commentsTimeMinutesAgo(int count) {
    return '$count 分钟前';
  }

  @override
  String commentsTimeHoursAgo(int count) {
    return '$count 小时前';
  }

  @override
  String get downloadStatusNotDownloaded => '未下载';

  @override
  String get downloadStatusDownloading => '下载中';

  @override
  String get downloadStatusDownloaded => '已下载';

  @override
  String get downloadAction => '下载';

  @override
  String get downloadCancel => '取消下载';

  @override
  String get downloadDelete => '删除下载';

  @override
  String get downloadDeleteConfirm => '删除下载？音频、歌词与封面会一起删除。';

  @override
  String get downloadDeleteConfirmMixed => '删除下载？音频、歌词与封面会一起删除；导入的歌曲只从列表移除。';

  @override
  String get localSongsCachedTag => '缓存';

  @override
  String get localSongsCachedRemove => '清除缓存';

  @override
  String get localSongsCachedRemoveConfirm => '清除这首歌的音频缓存？只移除缓存，不影响下载与导入的文件。';

  @override
  String get localSongsMixedRemoveConfirm =>
      '删除所选内容？下载的会删除文件，导入的只从列表移除，缓存的会被清除。';

  @override
  String get downloadShare => '分享文件';

  @override
  String downloadProgressPercent(int percent) {
    return '$percent%';
  }

  @override
  String get downloadCompleted => '下载完成';

  @override
  String downloadFailed(String message) {
    return '下载失败：$message';
  }

  @override
  String get downloadUnsupported => '当前平台不支持下载';

  @override
  String get downloadAlreadyExists => '该曲目已下载';

  @override
  String get downloadCancelled => '已取消下载';

  @override
  String get downloadDataSaverTitle => '省流模式生效中';

  @override
  String get downloadDataSaverConfirm => '当前为移动数据且已开启省流，继续下载会消耗流量。是否继续？';

  @override
  String get downloadContinue => '继续';

  @override
  String get downloadFileMissing => '本地文件不存在，可能已被删除';

  @override
  String get downloadSourceLocal => '本地下载';

  @override
  String get downloadsManageTitle => '下载管理';

  @override
  String get downloadsManageSubtitle => '任务队列、批量下载与文件维护';

  @override
  String get downloadsActiveSection => '进行中';

  @override
  String get downloadsActiveEmpty => '没有进行中的下载';

  @override
  String downloadsActiveCount(int count) {
    return '$count 个任务';
  }

  @override
  String get downloadsBatchSection => '批量下载';

  @override
  String get downloadsBatchQueue => '下载当前队列';

  @override
  String downloadsBatchQueueSubtitle(int count) {
    return '共 $count 首；跳过已下载与本地曲目';
  }

  @override
  String downloadsBatchStarted(int count) {
    return '已开始批量下载（$count 首）';
  }

  @override
  String downloadsBatchDone(int done, int failed) {
    return '批量下载完成：成功 $done，失败 $failed';
  }

  @override
  String get downloadsMaintenanceSection => '文件维护';

  @override
  String get downloadsCleanupParts => '清理未完成的下载文件';

  @override
  String get downloadsCleanupPartsSubtitle => '清理上次中断留下的临时文件，不影响已完成的下载';

  @override
  String downloadsCleanupPartsDone(int count) {
    return '已清理 $count 个未完成文件';
  }

  @override
  String get downloadsCleanupOrphans => '清理残留文件';

  @override
  String get downloadsCleanupOrphansSubtitle => '删除下载目录里找不到记录的残留文件';

  @override
  String downloadsCleanupOrphansDone(int count) {
    return '已清理 $count 个残留文件';
  }

  @override
  String get downloadsBatchPlaylist => '下载指定歌单';

  @override
  String get downloadsBatchPlaylistSubtitle => '选择歌单后批量下载（跳过已下载与本地曲目）';

  @override
  String get downloadsPickPlaylist => '选择歌单';

  @override
  String get downloadsMigrateLegacy => '迁移旧位置的下载';

  @override
  String get downloadsMigrateLegacySubtitle => '把旧版应用目录里的下载文件搬到当前下载目录';

  @override
  String downloadsMigrateLegacyDone(int moved, int failed) {
    return '已迁移 $moved 首，失败 $failed 首';
  }

  @override
  String get downloadsPublishPublic => '补一份到公共目录';

  @override
  String get downloadsPublishPublicSubtitle =>
      '把还没复制到系统「下载」目录的下载文件补一份（Android）';

  @override
  String downloadsPublishPublicDone(int published, int failed) {
    return '已复制 $published 首，失败 $failed 首';
  }

  @override
  String get downloadsNoResume => '下载失败会从头重下（平台链接通常短期有效）。';

  @override
  String get downloadsEmpty => '还没有下载的歌曲';

  @override
  String get sleepTimerTitle => '定时关闭';

  @override
  String get sleepTimerOff => '未开启';

  @override
  String sleepTimerRemaining(String time) {
    return '剩余 $time';
  }

  @override
  String get sleepTimerAfterTrack => '播完当前歌曲后暂停';

  @override
  String get sleepTimerCancel => '关闭定时';

  @override
  String sleepTimerArmedSnackbar(String time) {
    return '已开启定时关闭 · $time 后暂停';
  }

  @override
  String get sleepTimerArmedAfterTrack => '已开启定时关闭 · 播完当前歌曲后暂停';

  @override
  String get sleepTimerHourLabel => '小时';

  @override
  String get sleepTimerMinuteLabel => '分钟';

  @override
  String get sleepTimerCustom => '自定义时长…';

  @override
  String get sleepTimerCustomTitle => '自定义时长';

  @override
  String get sleepTimerCustomInvalid => '时长需在 1 分钟到 10 小时之间';

  @override
  String get sleepTimerCustomConfirm => '设定';

  @override
  String get trayShowWindow => '显示主窗口';

  @override
  String get trayPrevious => '上一首';

  @override
  String get trayNext => '下一首';

  @override
  String get trayQuit => '退出';

  @override
  String get settingsDesktopSection => '桌面';

  @override
  String get settingsCloseToTray => '关闭时最小化到托盘';

  @override
  String get settingsCloseToTraySubtitle => '播放不中断；可从托盘图标重新打开或退出';

  @override
  String get settingsShortcutsTitle => '快捷键';

  @override
  String get settingsShortcutsSubtitle => '软件内与全局快捷键的开关与自定义';

  @override
  String get shortcutsInAppSection => '软件内快捷键';

  @override
  String get shortcutsInAppHint => '窗口聚焦时生效；点击按键可重新录制';

  @override
  String get shortcutsGlobalSection => '全局快捷键';

  @override
  String get shortcutsGlobalHint => '全局快捷键，窗口不在前台也生效；必须包含 Ctrl / Alt / Shift';

  @override
  String get shortcutsGlobalUnsupportedKey => '全局快捷键只支持字母、数字、F1–F12 与空格';

  @override
  String shortcutsGlobalFailed(String detail) {
    return '部分全局快捷键未能生效：$detail';
  }

  @override
  String get shortcutsGlobalLinuxHint => 'Linux 由桌面门户提供；精简桌面环境可能不支持，届时会提示失败';

  @override
  String get shortcutsEnabledSwitch => '启用软件内快捷键';

  @override
  String get shortcutsGlobalEnabledSwitch => '启用全局快捷键';

  @override
  String get shortcutsResetAll => '恢复默认';

  @override
  String get shortcutsRecording => '按下新按键…（Esc 取消）';

  @override
  String shortcutsConflict(Object action) {
    return '已被「$action」占用';
  }

  @override
  String get shortcutsGlobalNeedsModifier => '全局快捷键必须包含 Ctrl / Alt / Shift';

  @override
  String get shortcutsSwapDialogTitle => '替换快捷键？';

  @override
  String shortcutsSwapDialogMessage(String action) {
    return '「$action」已使用该组合，替换会交换两者的快捷键。';
  }

  @override
  String get shortcutsSwapConfirm => '替换';

  @override
  String shortcutsSwapDone(String action) {
    return '已与「$action」互换快捷键';
  }

  @override
  String get shortcutActionPlayPause => '播放 / 暂停';

  @override
  String get shortcutActionSeekBackward => '快退 5 秒';

  @override
  String get shortcutActionSeekForward => '快进 5 秒';

  @override
  String get shortcutActionPrevious => '上一首';

  @override
  String get shortcutActionNext => '下一首';

  @override
  String get shortcutActionVolumeUp => '音量 +';

  @override
  String get shortcutActionVolumeDown => '音量 −';

  @override
  String get shortcutActionMute => '静音开关';

  @override
  String get shortcutActionSearch => '聚焦搜索';

  @override
  String get shortcutActionDestination1 => '切到第 1 个页面';

  @override
  String get shortcutActionDestination2 => '切到第 2 个页面';

  @override
  String get shortcutActionDestination3 => '切到第 3 个页面';

  @override
  String get shortcutActionCloseQueue => '关闭队列面板';

  @override
  String get shortcutActionShowWindow => '显示主窗口';

  @override
  String get settingsRememberWindowBounds => '记住窗口位置与大小';

  @override
  String get settingsRememberWindowBoundsSubtitle => '下次启动时恢复上次的位置、大小与最大化状态';

  @override
  String get settingsTrayLinuxHint =>
      'GNOME 等桌面需安装托盘扩展才能显示图标；没有托盘时，关闭窗口会直接退出应用';
}
