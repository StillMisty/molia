import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../app/bootstrap/runtime_providers.dart';
import '../data/settings/device_settings.dart';
import '../data/settings/device_settings_keys.dart';
import '../data/settings/settings_access.dart';
import '../data/settings/settings_key.dart';
import '../data/settings/settings_keys.dart';
import '../data/settings/settings_module.dart';
import '../domain/models/shell_destination.dart';

export '../domain/models/shell_destination.dart' show ShellDestination;

part 'nav_provider.g.dart';

final logger = Logger('molia.nav_provider');

typedef _NavLayout = ({
  List<ShellDestination> order,
  Set<ShellDestination> hidden,
  ShellDestination home,
});

/// 导航偏好对 UI 暴露的不可变快照。
@immutable
class NavState {
  const NavState({
    required this.order,
    required this.hidden,
    required this.homeDestination,
    required this.showLyricsOnEnter,
    required this.restoreLastDestination,
    required this.lastDestination,
  });

  /// 全部目的地的当前顺序（含隐藏项，设置页按此顺序展示）。
  final List<ShellDestination> order;

  final Set<ShellDestination> hidden;

  /// 存储的启动首页；同步推来的 hidden 列表可能让它当前不可见。
  final ShellDestination homeDestination;

  /// 从其它一级页进入播放页时是否固定先显示歌词。
  final bool showLyricsOnEnter;

  /// 启动时是否恢复到上次停留的一级页。
  final bool restoreLastDestination;

  /// 上次停留的一级页；null = 没有记录。
  final ShellDestination? lastDestination;

  bool isVisible(ShellDestination destination) => !hidden.contains(destination);

  /// 实际渲染到壳层的目的地（按顺序过滤隐藏项）。
  List<ShellDestination> get visibleDestinations =>
      order.where(isVisible).toList(growable: false);

  /// 有效启动首页：存储值可见则用它；不可见时按 [order] 取第一个可见项。
  ShellDestination get effectiveHomeDestination => isVisible(homeDestination)
      ? homeDestination
      : order.firstWhere(isVisible, orElse: () => order.first);

  /// 启动落点：「恢复上次页面」开启且记录仍可见时回到上次停留的一级页。
  ShellDestination get startupDestination {
    final last = lastDestination;
    if (restoreLastDestination && last != null && isVisible(last)) {
      return last;
    }
    return effectiveHomeDestination;
  }

  NavState copyWith({
    List<ShellDestination>? order,
    Set<ShellDestination>? hidden,
    ShellDestination? homeDestination,
    bool? showLyricsOnEnter,
    bool? restoreLastDestination,
    ShellDestination? lastDestination,
    bool clearLastDestination = false,
  }) => NavState(
    order: order ?? this.order,
    hidden: hidden ?? this.hidden,
    homeDestination: homeDestination ?? this.homeDestination,
    showLyricsOnEnter: showLyricsOnEnter ?? this.showLyricsOnEnter,
    restoreLastDestination:
        restoreLastDestination ?? this.restoreLastDestination,
    lastDestination: clearLastDestination
        ? null
        : (lastDestination ?? this.lastDestination),
  );
}

/// 底部导航定制：顺序 + 显示/隐藏 + 启动首页 + 进入播放页的歌词偏好，
/// SharedPreferences 持久化。
@Riverpod(keepAlive: true, name: 'navProvider')
class NavProvider extends _$NavProvider {
  /// 默认顺序来自登记键默认值（资料 / 播放 / 收藏），避免两处各写一份。
  static List<ShellDestination> get defaultOrder =>
      List<ShellDestination>.unmodifiable(
        _orderOf(kShellNavOrder.defaultValue),
      );

  /// 本 provider 读写的登记设置键：组合根按这份表挂载 `SettingsScope`。
  static const List<SettingsKey<Object?>> settingsKeys = [
    kShellNavLayout,
    // 旧版三键只读兜底：升级后首次启动仍能恢复导航定制，下次编辑写新键。
    kShellNavOrder,
    kShellNavHidden,
    kShellHomeDestination,
    // 进入播放页的歌词偏好与导航布局同属壳层导航偏好，共用一次重载。
    kShellNowPlayingLyricsOnEnter,
    kShellRestoreLastDestination,
  ];

  late final SettingsAccess _settings;
  late final DeviceSettings _deviceSettings;

  Future<void> _preferencesReady = Future.value();

  @override
  NavState build() {
    _settings = ref
        .watch(settingsRegistryProvider)
        .mount(
          SettingsModule(keys: settingsKeys, reload: reloadFromPreferences),
        );
    _deviceSettings = ref.watch(deviceSettingsProvider);
    _preferencesReady = _loadPreferences();
    return NavState(
      order: defaultOrder,
      hidden: _hiddenOf(kShellNavHidden.defaultValue),
      homeDestination: _homeOf(kShellHomeDestination.defaultValue),
      showLyricsOnEnter: kShellNowPlayingLyricsOnEnter.defaultValue,
      restoreLastDestination: kShellRestoreLastDestination.defaultValue,
      lastDestination: null,
    );
  }

  Future<void> get preferencesReady => _preferencesReady;

  Future<void> reloadFromPreferences() => _loadPreferences();

  /// 兼容旧读接口。
  List<ShellDestination> get order => state.order;
  List<ShellDestination> get visibleDestinations => state.visibleDestinations;
  bool isVisible(ShellDestination destination) => state.isVisible(destination);
  ShellDestination get homeDestination => state.homeDestination;
  ShellDestination get effectiveHomeDestination =>
      state.effectiveHomeDestination;
  ShellDestination get startupDestination => state.startupDestination;
  bool get showLyricsOnEnter => state.showLyricsOnEnter;
  bool get restoreLastDestination => state.restoreLastDestination;

  Future<void> setHomeDestination(ShellDestination destination) async {
    if (state.homeDestination == destination) return;
    state = state.copyWith(homeDestination: destination);
    await _persist();
  }

  Future<void> setRestoreLastDestination(bool value) async {
    if (state.restoreLastDestination == value) return;
    state = state.copyWith(
      restoreLastDestination: value,
      clearLastDestination: !value,
    );
    if (!value) {
      await _deviceSettings.remove(kShellLastDestinationKey);
    }
    try {
      await _settings.write(kShellRestoreLastDestination, value);
    } catch (e) {
      logger.severe('保存「恢复上次页面」偏好失败: $e');
    }
  }

  Future<void> recordLastDestination(ShellDestination destination) async {
    if (!state.restoreLastDestination || state.lastDestination == destination) {
      return;
    }
    state = state.copyWith(lastDestination: destination);
    await _deviceSettings.write(kShellLastDestinationKey, destination.name);
  }

  Future<void> setShowLyricsOnEnter(bool value) async {
    if (state.showLyricsOnEnter == value) return;
    state = state.copyWith(showLyricsOnEnter: value);
    try {
      await _settings.write(kShellNowPlayingLyricsOnEnter, value);
    } catch (e) {
      logger.severe('保存「进入播放页显示歌词」偏好失败: $e');
    }
  }

  Future<bool> setVisible(ShellDestination destination, bool visible) async {
    final hidden = Set<ShellDestination>.of(state.hidden);
    if (visible) {
      if (!hidden.remove(destination)) return true;
    } else {
      if (destination == state.homeDestination) return false;
      if (state.visibleDestinations.length <= 1) return false;
      if (!hidden.add(destination)) return true;
    }
    state = state.copyWith(hidden: hidden);
    await _persist();
    return true;
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= state.order.length) return;
    final target = newIndex.clamp(0, state.order.length - 1);
    if (target == oldIndex) return;
    final order = List<ShellDestination>.of(state.order);
    final moved = order.removeAt(oldIndex);
    order.insert(target, moved);
    state = state.copyWith(order: order);
    await _persist();
  }

  Future<void> _loadPreferences() async {
    try {
      final showLyrics = await _settings.read(kShellNowPlayingLyricsOnEnter);
      final restore = await _settings.read(kShellRestoreLastDestination);
      final last = _destinationOf(
        await _deviceSettings.read(kShellLastDestinationKey),
      );
      final layout = _decodeLayout(await _settings.read(kShellNavLayout));
      if (layout != null) {
        final hidden = Set<ShellDestination>.of(layout.hidden);
        final order = layout.order;
        if (order.every(hidden.contains)) hidden.remove(order.first);
        state = state.copyWith(
          order: order,
          hidden: hidden,
          homeDestination: layout.home,
          showLyricsOnEnter: showLyrics,
          restoreLastDestination: restore,
          lastDestination: last,
        );
        return;
      }

      final names = await _settings.read(kShellNavOrder);
      final order = names.isNotEmpty ? _orderOf(names) : state.order;
      final hiddenNames = await _settings.read(kShellNavHidden);
      final hidden = hiddenNames.isNotEmpty
          ? _hiddenOf(hiddenNames)
          : Set<ShellDestination>.of(state.hidden);
      if (order.every(hidden.contains)) hidden.remove(order.first);
      final homeName = await _settings.read(kShellHomeDestination);
      state = state.copyWith(
        order: order,
        hidden: hidden,
        homeDestination: _homeOf(homeName),
        showLyricsOnEnter: showLyrics,
        restoreLastDestination: restore,
        lastDestination: last,
      );
    } catch (e) {
      logger.severe('加载底部导航偏好失败: $e');
    }
  }

  static _NavLayout? _decodeLayout(String raw) {
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final order = decoded['order'];
      final hidden = decoded['hidden'];
      final home = decoded['home'];
      if (order is! List || hidden is! List || home is! String) return null;
      final orderNames = order.whereType<String>().toList(growable: false);
      if (orderNames.isEmpty) return null;
      return (
        order: _orderOf(orderNames),
        hidden: _hiddenOf(hidden.whereType<String>().toList(growable: false)),
        home: _homeOf(home),
      );
    } on FormatException {
      return null;
    }
  }

  static List<ShellDestination> _orderOf(List<String> names) {
    final restored = <ShellDestination>[];
    for (final name in names) {
      for (final destination in ShellDestination.values) {
        if (destination.name == name && !restored.contains(destination)) {
          restored.add(destination);
        }
      }
    }
    for (final destination in ShellDestination.values) {
      if (!restored.contains(destination)) restored.add(destination);
    }
    return restored;
  }

  static Set<ShellDestination> _hiddenOf(List<String> names) => ShellDestination
      .values
      .where((value) => names.contains(value.name))
      .toSet();

  static ShellDestination _homeOf(String name) =>
      ShellDestination.values.firstWhere(
        (destination) => destination.name == name,
        orElse: () => ShellDestination.values.firstWhere(
          (destination) =>
              destination.name == kShellHomeDestination.defaultValue,
        ),
      );

  static ShellDestination? _destinationOf(String name) {
    for (final destination in ShellDestination.values) {
      if (destination.name == name) return destination;
    }
    return null;
  }

  Future<void> _persist() async {
    try {
      await _settings.write(
        kShellNavLayout,
        jsonEncode({
          'order': state.order.map((destination) => destination.name).toList(),
          'hidden': state.hidden
              .map((destination) => destination.name)
              .toList(),
          'home': state.homeDestination.name,
        }),
      );
    } catch (e) {
      logger.severe('保存底部导航偏好失败: $e');
    }
  }
}
