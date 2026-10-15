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
  String get lyricsCopyModeSnackbar => '歌词复制模式：已切到单曲循环、暂停自动跟随；退出时恢复原播放模式。';

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
  String get settingsBaseColorWallpaper => '系统壁纸（莫奈）';

  @override
  String get settingsBaseColorCustom => '自定义颜色';

  @override
  String get settingsMonetUnavailable => '当前平台不支持';

  @override
  String get settingsPureBlack => '纯黑背景';

  @override
  String get settingsPureBlackSubtitle => '深色模式下表面纯黑（OLED 省电；可与取色叠加）';

  @override
  String get settingsSeedColor => '自定义颜色';

  @override
  String get settingsFollowArtwork => '播放时跟随封面';

  @override
  String get settingsFollowArtworkSubtitle => '播放有封面歌曲时用封面取色，无封面回退基础配色';

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
  String get settingsDefaultPlayModeSubtitle => '新播放会话的初始模式，不打断当前播放';

  @override
  String get settingsRestoreSessionTitle => '启动时恢复上次播放';

  @override
  String get settingsRestoreSessionSubtitle => '启动时恢复上次的曲目、队列与进度（默认开启）';

  @override
  String get settingsAutoSourceSwap => '自动换源';

  @override
  String get settingsAutoSourceSwapSubtitle => '播放失败时自动在其它音源找回同一首歌并切换（默认开启）';

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
  String get settingsSourcesItemSubtitle => '导入 LX Music 音源脚本，搜索第三方平台歌曲';

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
  String get playModeSequential => '顺序播放';

  @override
  String get playModeShuffle => '随机播放';

  @override
  String get playModeSingleRepeat => '单曲循环';

  @override
  String get generalTitle => '通用';

  @override
  String get settingsGeneralAndDataTitle => '通用与数据';

  @override
  String get settingsGeneralSubtitle => '语言、应用名称与底部导航';

  @override
  String get dataManagementTitle => '数据与存储';

  @override
  String get settingsDataSubtitle => '缓存、听歌统计与数据导入导出';

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
  String get saveChanges => '保存';

  @override
  String get selectLyrics => '选择歌词';

  @override
  String get selectLyricsTooltip => '选择歌词片段生成海报或分享';

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
  String get loadingGenerating => '正在生成海报...';

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
  String get anyListenIntroBody =>
      'any-listen 是自托管的私有音乐播放服务。填写服务器地址并启用后，服务器提供的在线音源会出现在搜索页的音源列表中。';

  @override
  String get anyListenIntroHint =>
      '当前为骨架实现：握手探测（/api/ipc/hello、/api/ipc/id）已对照官方源码，搜索/取链/歌词/封面接口尚未与真实服务器验证，可能暂不可用。';

  @override
  String get anyListenServerSection => '服务器配置';

  @override
  String get anyListenServerUrl => '服务器地址';

  @override
  String get anyListenServerUrlHint => 'Docker / 桌面端部署的 any-listen 服务地址';

  @override
  String get anyListenServerUrlRequired => '请先填写服务器地址';

  @override
  String get anyListenServerUrlRequiredToEnable => '启用前请填写服务器地址';

  @override
  String get anyListenToken => '访问令牌（可选）';

  @override
  String get anyListenTokenPlaceholder => '连接测试通过后可粘贴服务器下发的令牌';

  @override
  String get anyListenTokenShow => '显示令牌';

  @override
  String get anyListenTokenHide => '隐藏令牌';

  @override
  String get anyListenEnable => '启用 any-listen 音源';

  @override
  String get anyListenEnableSubtitle => '关闭后不会出现在搜索页，也不发起任何请求';

  @override
  String get anyListenSave => '保存';

  @override
  String get anyListenTest => '连接测试';

  @override
  String get anyListenSaveFailed => '保存失败：无法写入本地存储';

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
  String get sourcesQualityHint => '取链优先使用该音质，不可用时自动回退';

  @override
  String get sourcesSortTitle => '渠道排序';

  @override
  String get sourcesSortReset => '重置';

  @override
  String get sourcesSortResetSubtitle => '恢复「脚本音源在前、内置平台在后」的默认顺序';

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
  String get sortByTitle => '按标题';

  @override
  String get sortByArtist => '按艺术家';

  @override
  String get playAll => '播放全部';

  @override
  String get nextTrackTooltip => '下一首';

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
  String get sourceSwapDuplicateMessage => '目标列表已包含这首歌。换源将移除重复项，并以所选版本替换。';

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
  String get appName => '茉咏';

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
    return '建议 $value（内部存储的 1/128）';
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
  String get lyricsDesktopAlignVertical => '垂直对齐';

  @override
  String get lyricsDesktopAlignLeft => '左';

  @override
  String get lyricsDesktopAlignCenter => '中';

  @override
  String get lyricsDesktopAlignRight => '右';

  @override
  String get lyricsDesktopAlignTop => '上';

  @override
  String get lyricsDesktopAlignBottom => '下';

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
  String get lyricsDesktopLock => '锁定位置（点击穿透）';

  @override
  String get lyricsDesktopFreeze => '息屏时冻结歌词';

  @override
  String get lyricsDesktopPauseBehavior => '暂停时';

  @override
  String get lyricsDesktopNoLyrics => '无歌词时';

  @override
  String get lyricsDesktopAnimation => '行切换动画';

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
  String get lyricsNotificationEnableSubtitle => '把当前歌词行写入媒体元数据';

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
  String get lyricsBluetoothEnableSubtitle => '把当前歌词行写入媒体元数据（通知栏 / 锁屏会同步显示）';

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
  String get lyricsNotificationPermissionSubtitle =>
      '允许通知后媒体控制卡才能稳定展示；点按前往系统设置';

  @override
  String get lyricsMediaSessionUnavailable => '系统媒体会话初始化失败：通知栏 / 锁屏歌词与播放控制不可用';

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
      '取色来源决定三行「跟随主题角色」用哪套方案：跟随应用主题随外观设置变化；跟随封面按当前曲目封面取色并实时更新。';

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
  String get aiDjSettingsSubtitle => '自备 Key 的 AI 推荐电台（默认关闭）';

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
  String get aiDjToggleSubtitle => '开启后 AI 持续选歌入队，播完自动续推';

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
      '开启后会把你的听歌画像（聚合统计、最近 200 条播放明细、已听曲目清单）发送给你配置的 AI 服务用于生成推荐；数据直达该服务、不经过本应用中转，应用不含内置 Key。关闭模式即停止续推，清除配置即断开连接。';

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
  String get aiDjSaveConfig => '保存配置';

  @override
  String get aiDjClearConfig => '清除配置';

  @override
  String get aiDjConfigSaved => '已保存';

  @override
  String aiDjQueued(int count) {
    return '本会话已入队 $count 首';
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
    return '最近 $events 条播放记录 · Top 艺人 $artists 位 · 已听排除 $exclusions 首';
  }

  @override
  String get aiDjUpstreamHint => '只包含以上统计与曲名/歌手，不含播放链接与设备信息。';

  @override
  String get aiDjCacheTtlTitle => '推荐缓存';

  @override
  String aiDjCacheTtlDays(int days) {
    return '保留 $days 天';
  }

  @override
  String get aiDjCacheTtlForever => '永久保留';

  @override
  String get aiDjCacheTtlHint => '过期后不再作为续推来源，下一次续推自动生成新一批（不打断播放、不提示）。';

  @override
  String get aiDjGenerate => '生成推荐';

  @override
  String get aiDjEmptyList => '还没有推荐列表';

  @override
  String get aiDjEmptyListHint => '生成一批今日推荐，之后可随时播放。';

  @override
  String get aiDjEnqueueEmpty => '列表里的歌都已在队列中';

  @override
  String get settingsSyncTitle => '跨设备同步';

  @override
  String get settingsSyncItemSubtitle => '歌单、音源、设置与凭证';

  @override
  String get syncGeneralSection => '同步';

  @override
  String get syncTrustModelTitle => '信任模型';

  @override
  String get syncEnabledTitle => '启用同步';

  @override
  String get syncEnabledSubtitle => '与持有同一口令的设备交换数据';

  @override
  String get syncDeviceNameTitle => '设备名称';

  @override
  String get syncPassphraseTitle => '同步口令';

  @override
  String get syncPassphraseNotSet => '未设置';

  @override
  String get syncPassphraseTrustHint => '口令即信任根：持有者完全互信；怀疑泄露请重置。';

  @override
  String get syncPassphraseCopy => '复制口令';

  @override
  String get syncPassphraseReset => '重置口令';

  @override
  String get syncPassphraseResetConfirm => '重置后所有设备需重新输入新口令，确定继续？';

  @override
  String get syncPassphraseJoin => '输入已有口令加入';

  @override
  String get syncPassphraseJoinTitle => '输入同步口令';

  @override
  String get syncPassphraseJoinHint => '输入其它设备上显示的同步口令';

  @override
  String get syncPassphraseInvalid => '口令无效（至少 16 位）';

  @override
  String get syncSave => '保存';

  @override
  String get syncSyncNow => '立即同步';

  @override
  String get syncSyncing => '同步中…';

  @override
  String get syncNever => '尚未同步';

  @override
  String syncLastResultOk(String time, int applied) {
    return '上次同步 $time · 应用 $applied 项';
  }

  @override
  String syncLastResultFail(String error) {
    return '上次同步失败：$error';
  }

  @override
  String get syncContentSection => '同步内容';

  @override
  String get syncCategoryPlaylists => '歌单与收藏';

  @override
  String get syncCategorySources => '音源（脚本与配置）';

  @override
  String get syncCategorySettings => '应用设置';

  @override
  String get syncCategoryStatistics => '听歌统计';

  @override
  String get syncCategoryHistory => '播放历史';

  @override
  String get syncCategorySession => '上次播放会话';

  @override
  String get syncCategoryCredentials => 'AI DJ 与凭证';

  @override
  String get syncTransportSection => '传输方式';

  @override
  String get syncLanTitle => '局域网直连';

  @override
  String get syncLanSubtitle => '同一 Wi-Fi 下设备直连，无需服务器';

  @override
  String get syncWebdavTitle => 'WebDAV / 云盘';

  @override
  String get syncWebdavSubtitle => '经你自备的 WebDAV 跨网络同步';

  @override
  String get syncWebdavConfigTitle => 'WebDAV 配置';

  @override
  String get syncWebdavServer => '服务器地址';

  @override
  String get syncWebdavUsername => '用户名';

  @override
  String get syncWebdavPassword => '密码';

  @override
  String get syncWebdavRemoteDir => '远端目录';

  @override
  String get syncWebdavNotConfigured => '未配置';

  @override
  String get syncLogSection => '同步日志';

  @override
  String get syncLogEmpty => '暂无记录';

  @override
  String syncLogApplied(int applied, int skipped) {
    return '应用 $applied 项、跳过 $skipped 项';
  }

  @override
  String syncLogFailed(String error) {
    return '失败：$error';
  }

  @override
  String get syncDeviceNameDialogTitle => '设备名称';

  @override
  String get syncRenameHint => '其它设备上显示的名称';

  @override
  String get syncDeviceNameEmpty => '名称不能为空';

  @override
  String get syncCategorySubtitle => '关闭后本机不推送也不应用该类数据';

  @override
  String get syncGeneratedHint => '已生成同步口令，在其它设备输入同一口令即可加入';

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
  String get updateReloadNow => '立即刷新';

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
  String get updateManifestOverrideTitle => '更新清单地址';

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
  String get updateErrorNetwork => '网络错误，检查更新失败';

  @override
  String get updateErrorManifest => '更新清单无效';

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
  String get trackInfoTabTitle => '歌曲信息';

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
  String get trackInfoDuration => '时长';

  @override
  String get trackInfoTrackId => '曲目 ID';

  @override
  String get trackInfoIdCopied => '曲目 ID 已复制';

  @override
  String get trackInfoCacheSection => '缓存';

  @override
  String get trackInfoCacheResolve => '取链缓存';

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
  String get trackCachePageTitle => '单曲缓存';

  @override
  String get trackCacheClearAll => '全部清理';

  @override
  String trackCacheClearConfirm(String part) {
    return '清理「$part」？';
  }

  @override
  String get trackCacheClearAllConfirm => '清理这首歌的全部缓存？';

  @override
  String get trackCacheClearHint => '只清理缓存副本，不影响已下载文件与当前播放。';

  @override
  String cacheClearPart(String part) {
    return '清理「$part」？';
  }

  @override
  String get clear => '清理';

  @override
  String get trackCacheEmpty => '这首歌没有缓存';

  @override
  String get cacheAudioPlatformUnsupported => '当前平台不缓存音频';

  @override
  String get cacheAudioDisabled => '音频缓存已关闭';

  @override
  String get downloadAudioSection => '音频';

  @override
  String get downloadQualityLabel => '音质';

  @override
  String get downloadQualityCached => '本地缓存';

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
  String get downloadFromCache => '命中本地缓存，无需下载';

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
  String get downloadSaveLocationDefault => '默认（系统下载目录）';

  @override
  String get downloadSaveLocationFixedHint => '当前平台固定在应用目录，文件可在系统「文件」应用中访问';

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
      '写入音频文件标签（MP3 / FLAC），其它播放器也能读到；失败时保留同名文件';

  @override
  String get downloadPublishToPublicDir => '发布到公共下载目录';

  @override
  String get downloadPublishToPublicDirSubtitle =>
      '下载完成后额外拷贝一份到系统「下载」目录（Android 公共目录），文件管理器与其它播放器可见；播放仍用应用内的副本';

  @override
  String get downloadLocationInfo => '下载目录';

  @override
  String get downloadLocationUnsupported => '当前平台不支持下载';

  @override
  String get save => '保存';

  @override
  String get lyricsEmptyState => '这首歌暂时没找到词，换一个来源试试？ (´･ω･`)';

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
  String get commentsLoadMoreFailed => '加载更多评论失败';

  @override
  String get commentsNoMore => '没有更多评论了';

  @override
  String get commentsRefresh => '刷新评论';

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
  String get downloadSection => '下载';

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
  String get downloadDeleteConfirm => '删除本地副本？音频、歌词与封面文件将一并删除。';

  @override
  String get downloadDeleteConfirmMixed =>
      '删除本地副本？音频、歌词与封面文件将一并删除；导入的本地歌曲只从列表移除。';

  @override
  String get downloadStatusCachedCopy => '缓存副本';

  @override
  String get downloadToFolder => '下载到本地文件夹';

  @override
  String get localSongsCachedTag => '缓存';

  @override
  String get localSongsCachedRemove => '清除缓存';

  @override
  String get localSongsCachedRemoveConfirm => '清除这首歌的音频缓存？只移除缓存副本，不影响下载与导入的文件。';

  @override
  String get localSongsMixedRemoveConfirm =>
      '删除所选内容？下载副本会删除文件，导入项只从列表移除，缓存副本会被清除。';

  @override
  String get downloadShare => '分享导出';

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
  String get downloadsCleanupPartsSubtitle => '崩溃遗留的半成品（.part），不影响已完成下载';

  @override
  String downloadsCleanupPartsDone(int count) {
    return '已清理 $count 个未完成文件';
  }

  @override
  String get downloadsCleanupOrphans => '清理无记录的孤儿文件';

  @override
  String get downloadsCleanupOrphansSubtitle => '删除下载目录中不被任何记录引用的文件';

  @override
  String downloadsCleanupOrphansDone(int count) {
    return '已清理 $count 个孤儿文件';
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
  String get downloadsPublishPublic => '补发布到公共目录';

  @override
  String get downloadsPublishPublicSubtitle => '把还没有公共副本的下载拷进系统「下载」目录（Android）';

  @override
  String downloadsPublishPublicDone(int published, int failed) {
    return '已发布 $published 首，失败 $failed 首';
  }

  @override
  String get downloadsNoResume => '不做断点续传：平台直链多为一次性签名地址，失败后重下更可靠';

  @override
  String get downloadsEmpty => '还没有下载的歌曲';

  @override
  String get sleepTimerTitle => '定时关闭';

  @override
  String get sleepTimerHint => '到点自动暂停播放';

  @override
  String get sleepTimerCountdownSection => '倒计时';

  @override
  String get sleepTimerOff => '未开启';

  @override
  String sleepTimerRemaining(String time) {
    return '剩余 $time';
  }

  @override
  String get sleepTimerAfterTrack => '播完当前歌曲后暂停';

  @override
  String sleepTimerMinutesShort(int minutes) {
    return '$minutes 分钟';
  }

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
}
