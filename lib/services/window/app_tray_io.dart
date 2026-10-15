import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:tray_manager/tray_manager.dart';

import 'tray_menu_labels.dart';

/// Linux / Windows 桌面托盘：tray_manager（nativeapi 后端）实现。
///
/// 全仓只有本文件 import `tray_manager`（条件导出入口见 `app_tray.dart`）。
///
/// nativeapi 的包装对象（TrayIcon / Menu / MenuItem / Image）都挂 finalizer，
/// 对象被 GC 时会释放原生句柄——托盘图标与菜单会从系统里消失。因此本类把
/// 创建过的每个对象都持有到 [dispose]，禁止只保留「本地变量」。
class AppTray {
  AppTray._();

  /// 托盘图标资产（64×64，品牌瓦片形式，亮 / 暗面板都可辨识）。
  static const String _iconAsset = 'assets/icons/tray_icon.png';

  static final Logger _logger = Logger('molia.app_tray');

  static bool get isSupported => Platform.isLinux || Platform.isWindows;

  /// Linux 的托盘图标由桌面面板（StatusNotifierItem 宿主）承载：GNOME 需安装
  /// AppIndicator 扩展，否则图标不显示（设置页据此显示提示）。
  static bool get isLinuxDesktop => Platform.isLinux;

  static TrayIcon? _icon;
  static Menu? _menu;
  static MenuItem? _showWindowItem;
  static MenuItem? _playPauseItem;
  static MenuItem? _previousItem;
  static MenuItem? _nextItem;
  static MenuItem? _favoriteItem;
  static MenuItem? _quitItem;

  /// 菜单项与它的事件监听（dispose 时逐项摘除，避免监听器活过对象）。
  static final List<(MenuItem, ListenerId)> _itemListeners =
      <(MenuItem, ListenerId)>[];

  /// 原生 Image 句柄（托盘图标）：持有到 dispose。
  static final List<Image> _images = <Image>[];

  static ListenerId? _iconListener;

  static TrayMenuLabels? _labels;
  static bool _hasTrack = false;
  static bool _isPlaying = false;
  static bool _isFavorite = false;
  static String? _tooltip;

  /// 托盘图标当前是否已创建（集成测试 / 诊断用）。
  @visibleForTesting
  static bool get debugIsActive => _icon != null;

  static Future<bool>? _hostProbe;

  /// 系统是否存在托盘宿主（Linux 的 StatusNotifierWatcher / Windows 恒有）。
  ///
  /// 无宿主的桌面（GNOME 未装 AppIndicator 扩展、无面板的裸 WM）里图标不会
  /// 出现在任何地方：此时「关闭到托盘」会把窗口藏成一个没有找回入口的状态，
  /// 组合根据此把关闭行为退回「直接退出」。结果缓存（宿主运行期出现/消失
  /// 都按启动后的首次结论处理）。
  static Future<bool> detectHost() => _hostProbe ??= _detectHost();

  static Future<bool> _detectHost() async {
    if (Platform.isWindows) return true;
    // 不引入 D-Bus 客户端依赖：一次性进程查询（dbus-send 随 dbus 本体分发）。
    // 查询不确定（无工具 / 无 session bus）时按「有宿主」处理——保持用户
    // 设置的原意；只有明确回答「没有持有者」才算无宿主。
    const watchers = [
      'org.kde.StatusNotifierWatcher',
      'com.canonical.StatusNotifierWatcher',
    ];
    var conclusive = false;
    for (final watcher in watchers) {
      final owned = await _nameHasOwner(watcher);
      if (owned == true) {
        _logger.info('检测到托盘宿主：$watcher');
        return true;
      }
      if (owned == false) conclusive = true;
    }
    if (!conclusive) {
      _logger.info('托盘宿主检测不确定（无可用 D-Bus 查询工具），按有宿主处理');
      return true;
    }
    _logger.info('未检测到托盘宿主（StatusNotifierWatcher）：关闭到托盘将退回直接退出');
    return false;
  }

  /// D-Bus 名字是否有持有者；查询失败返回 null（不判定）。
  static Future<bool?> _nameHasOwner(String name) async {
    try {
      final result = await Process.run('dbus-send', [
        '--session',
        '--dest=org.freedesktop.DBus',
        '--print-reply',
        '/org/freedesktop/DBus',
        'org.freedesktop.DBus.NameHasOwner',
        'string:$name',
      ]).timeout(const Duration(seconds: 2));
      if (result.exitCode != 0) return null;
      final output = result.stdout.toString();
      if (output.contains('boolean true')) return true;
      if (output.contains('boolean false')) return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 创建托盘图标与菜单；动作与文案由组合根注入。
  ///
  /// 失败（D-Bus 不可用 / 桌面无面板 / 图标资源缺失）时静默降级：托盘缺席
  /// 不影响应用其余功能，也不阻塞启动（无面板的 Xvfb / CI 环境即此路径）。
  static void init({
    required TrayMenuLabels labels,
    required void Function() onShowWindow,
    required void Function() onTogglePlay,
    required void Function() onPrevious,
    required void Function() onNext,
    required void Function() onToggleFavorite,
    required void Function() onQuit,
  }) {
    if (!isSupported || _icon != null) return;
    _labels = labels;
    try {
      final trayIcon = TrayIcon.create();
      // 没有像素的托盘项无法点击：图标资源缺失（打包异常）时直接放弃。
      final image =
          trayIcon == null ? null : ImageAsset.fromAsset(_iconAsset);
      if (trayIcon == null || image == null) {
        image?.dispose();
        trayIcon?.dispose();
        _logger.info('托盘不可用：原生创建失败或图标资源缺失，继续无托盘运行');
        return;
      }

      _icon = trayIcon;
      _images.add(image);
      _menu = _buildMenu(
        onShowWindow: onShowWindow,
        onTogglePlay: onTogglePlay,
        onPrevious: onPrevious,
        onNext: onNext,
        onToggleFavorite: onToggleFavorite,
        onQuit: onQuit,
      );
      _applyItemState();

      trayIcon
        ..icon = image
        // 右键弹菜单（Windows 惯例；Linux 由面板决定触发方式，但只有
        // clicked / rightClicked 才会把菜单暴露给面板，不能留默认的 none）。
        ..setContextMenuTrigger(ContextMenuTrigger.rightClicked)
        ..setContextMenu(_menu)
        ..setVisible(true);
      // 左键单击 / 双击唤起窗口：Windows 直接上报点击；Linux 由宿主的
      // `Activate` 上报（KDE 计入单击、GNOME 扩展计入双击，见 pitfalls #35）。
      _iconListener = trayIcon.addListener((event) {
        if (event is TrayIconClickedEvent ||
            event is TrayIconDoubleClickedEvent) {
          onShowWindow();
        }
      });
      final tooltip = _tooltip;
      if (tooltip != null) trayIcon.setTooltip(tooltip);
      _logger.info('托盘已创建');
    } catch (error) {
      _logger.warning('托盘创建失败（继续无托盘运行）：$error');
      dispose();
    }
  }

  /// 更新菜单文案（界面语言切换时由组合根重新注入）。
  static void setLabels(TrayMenuLabels labels) {
    _labels = labels;
    _applyItemState();
  }

  /// 播放态 / 有无曲目：菜单文案与可用性（无曲目时禁用控制项）。
  static void setPlaybackState({
    required bool hasTrack,
    required bool isPlaying,
  }) {
    if (_hasTrack == hasTrack && _isPlaying == isPlaying) return;
    _hasTrack = hasTrack;
    _isPlaying = isPlaying;
    _applyItemState();
  }

  /// 当前曲目的收藏态（菜单在「收藏 / 取消收藏」间切换）。
  static void setFavorite(bool isFavorite) {
    if (_isFavorite == isFavorite) return;
    _isFavorite = isFavorite;
    _applyItemState();
  }

  /// 悬浮提示：无曲目时是应用名，有曲目时附「曲名 - 歌手」。
  static void setTooltip(String tooltip) {
    if (_tooltip == tooltip) return;
    _tooltip = tooltip;
    _icon?.setTooltip(tooltip);
  }

  /// 销毁图标与菜单（集成测试 / 退出前清理用；进程正常退出不依赖它）。
  static void dispose() {
    final trayIcon = _icon;
    _icon = null;
    final iconListener = _iconListener;
    _iconListener = null;
    if (trayIcon != null) {
      if (iconListener != null) trayIcon.removeListener(iconListener);
      trayIcon.dispose();
    }
    for (final (item, listenerId) in _itemListeners) {
      item.removeListener(listenerId);
      item.dispose();
    }
    _itemListeners.clear();
    for (final image in _images) {
      image.dispose();
    }
    _images.clear();
    _menu?.dispose();
    _menu = null;
    _showWindowItem = null;
    _playPauseItem = null;
    _previousItem = null;
    _nextItem = null;
    _favoriteItem = null;
    _quitItem = null;
  }

  static Menu _buildMenu({
    required void Function() onShowWindow,
    required void Function() onTogglePlay,
    required void Function() onPrevious,
    required void Function() onNext,
    required void Function() onToggleFavorite,
    required void Function() onQuit,
  }) {
    final labels = _labels!;
    final menu = Menu.create();
    if (menu == null) throw StateError('无法创建托盘菜单');

    MenuItem add(
      String label,
      void Function() onTap, {
      bool enabled = true,
    }) {
      final item =
          MenuItem.createWithLabelAndType(label, MenuItemType.normal);
      if (item == null) throw StateError('无法创建托盘菜单项：$label');
      item.isEnabled = enabled;
      final listenerId = item.addListener((event) {
        if (event is MenuItemClickedEvent) onTap();
      });
      _itemListeners.add((item, listenerId));
      menu.addItem(item);
      return item;
    }

    _showWindowItem = add(labels.showWindow, onShowWindow);
    menu.addSeparator();
    _playPauseItem = add(labels.play, onTogglePlay, enabled: _hasTrack);
    _previousItem = add(labels.previous, onPrevious, enabled: _hasTrack);
    _nextItem = add(labels.next, onNext, enabled: _hasTrack);
    _favoriteItem =
        add(labels.addFavorite, onToggleFavorite, enabled: _hasTrack);
    menu.addSeparator();
    _quitItem = add(labels.quit, onQuit);
    return menu;
  }

  /// 把当前状态写回菜单项（label / enabled）：仅在值真正变化时下发原生调用
  /// （Linux 侧每次 label 变更都会广播 dbusmenu 更新，重复写没有意义）。
  static void _applyItemState() {
    final labels = _labels;
    if (labels == null || _icon == null) return;
    _setLabel(_showWindowItem, labels.showWindow);
    _setLabel(_quitItem, labels.quit);
    _setLabel(_playPauseItem, _isPlaying ? labels.pause : labels.play);
    _setLabel(_previousItem, labels.previous);
    _setLabel(_nextItem, labels.next);
    _setLabel(
      _favoriteItem,
      _isFavorite ? labels.removeFavorite : labels.addFavorite,
    );
    for (final item in <MenuItem?>[
      _playPauseItem,
      _previousItem,
      _nextItem,
      _favoriteItem,
    ]) {
      if (item != null && item.isEnabled != _hasTrack) {
        item.isEnabled = _hasTrack;
      }
    }
  }

  static void _setLabel(MenuItem? item, String label) {
    if (item == null || item.label == label) return;
    item.label = label;
  }
}
