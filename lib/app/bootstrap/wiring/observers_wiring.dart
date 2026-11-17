/// 业务观察者接线：渠道 / 搜索、通知收藏、统计与听歌同步、全局热键。
///
/// 这些动作都挂在已建好的 provider / 服务上，不创建新的子系统；调用顺序由
/// `build_core_stacks.dart`（渠道 / 收藏 / 热键）与 `build_aux_stacks.dart`
/// （统计 / 听歌同步）保证，与拆分前一致。
library;

import 'dart:async';

import '../../../data/settings/settings_keys.dart';
import '../../../data/settings/settings_module.dart';
import '../../../providers/channel_selection.dart';
import '../../../providers/library_provider.dart';
import '../../../providers/search_provider.dart';
import '../../../services/global_hotkeys.dart';
import '../../../services/shortcut_actions.dart';
import '../../../sources/builtin/discover_source.dart';
import '../catalog_stack.dart';
import '../library_stack.dart';
import '../playback_stack.dart';
import '../scrobble_stack.dart';
import '../startup_trace.dart';

/// 渠道 + 搜索的成对产物：同一个 [ChannelSelection] 被两者共用。
typedef ChannelSearchRuntime = ({
  ChannelSelection channelSelection,
  SearchProvider searchProvider,
});

/// 创建当前渠道与搜索 provider。
///
/// 渠道是发现内容与搜索的唯一所有者：持久化 / 跨设备重载 / 失效回退规则都在
/// 模块内（页面与 Ctrl+F 不再手工同步两份渠道）。搜索 provider 也必须在这里
/// 创建，托盘期缓存释放回调要注册到同一个实例上。
ChannelSearchRuntime buildChannelSearchRuntime({
  required CatalogStack catalog,
  required PlaybackStack playback,
}) {
  // 自引用只服务「远端应用设置后的 reload」：挂载时需要回调，实例在下一行
  // 才建好。late 仅存在于本函数内，不跨 builder 回填。
  late final ChannelSelection channelSelection;
  final channelSettings = catalog.settings.mount(
    SettingsModule(
      keys: [kDiscoverChannelKey],
      reload: () => channelSelection.reloadFromPreferences(),
    ),
  );
  channelSelection = ChannelSelection(
    settings: channelSettings,
    validKeys: () {
      final manager = catalog.sourceManager;
      // 音源未初始化 / 脚本激活中时有效集合为空：不允许回退，否则会覆盖
      // 用户保存的脚本渠道偏好。
      if (!manager.initialized || manager.isActivating) return const [];
      return [
        for (final channel in manager.channels)
          if (channel.enabled) channel.key,
      ];
    },
    defaultKey: () => BuiltinDiscover.sourceKeys.first,
  );
  final searchProvider = SearchProvider(
    playback.playbackProvider,
    selection: channelSelection,
    catalogService: catalog.catalogService,
    sourceRegistry: catalog.sourceRegistry,
  );
  return (channelSelection: channelSelection, searchProvider: searchProvider);
}

/// 通知 / 系统媒体会话的「收藏」动作 ↔ 曲库。
///
/// 必须在 provider 建好之后接线（handler 先于它创建）；没有媒体会话时是
/// 空操作（见 [wireNotificationFavorite]）。
void wireNotificationFavoriteAction({
  required PlaybackStack playback,
  required LibraryProvider libraryProvider,
}) {
  wireNotificationFavorite(
    audioHandler: playback.audioHandler,
    libraryProvider: libraryProvider,
  );
}

/// 全局热键：注册启动期副作用，runApp 前 await 一次即可。
///
/// 命令执行器用刚建好的播放 provider 接线——热键回调不依赖 widget 树。注册
/// 失败在层内降级，不阻断启动（见 `global_hotkeys.dart`）。
Future<void> startGlobalHotkeys({required PlaybackStack playback}) {
  GlobalHotkeys.bindActions(
    ShortcutActions(playback: playback.playbackProvider),
  );
  // 热键注册（平台通道）不参与首帧内容：与桌面壳 / 主题预解析并行推进，
  // 在 runApp 前 await 一次即可（窗口出现时热键已就绪）。
  final hotkeysWatch = Stopwatch()..start();
  return GlobalHotkeys.attach().whenComplete(
    () => markStartupStep('sub.hotkeys.attach', hotkeysWatch),
  );
}

/// 听歌统计 + 听歌同步的观察者接线（纯观察：快照 + 进度 tick）。
///
/// 不进入播放命令路径；`wirePlayStatistics` 与听歌同步同源，各自只读 provider。
void wirePlaybackObservers({
  required PlaybackStack playback,
  required LibraryStack library,
  required ScrobbleStack scrobble,
}) {
  wirePlayStatistics(
    playback: playback.playbackProvider,
    service: library.playStatisticsService,
  );
  playback.playbackProvider.addListener(
    () => scrobble.service.onSnapshot(playback.playbackProvider.snapshot),
  );
  playback.playbackProvider.position.addListener(
    () =>
        scrobble.service.onPosition(playback.playbackProvider.currentPosition),
  );
  scrobble.service.onSnapshot(playback.playbackProvider.snapshot);
}
