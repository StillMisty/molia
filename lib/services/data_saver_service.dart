import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sources/source_track.dart' show capQualityFor;

/// 省流模式（数据节省）服务。
///
/// 行为（产品定义）：
/// - **默认关闭**，由用户在设置页手动开启；
/// - 开启后**仅在移动数据（蜂窝）下生效**：Wi-Fi / 以太网 / 检测不到时
///   一律保持原偏好音质、不干预封面加载；
/// - 生效时：取链音质压到用户设定的上限（默认 128k），封面只使用本地缓存
///   （是否省封面可单独关闭）。
///
/// 设计要点：
/// - 网络探测通过 [cellularProbe] / [cellularChanges] 注入，单测不触发
///   插件平台通道；默认实现包一层 `connectivity_plus`；
/// - 检测失败（桌面无 NetworkManager、测试环境等）静默降级为「未生效」，
///   由 [detectionAvailable] 供 UI 提示；
/// - 本服务只提供策略判定，不直接改播放行为：音质在 composition root 的
///   取链回调里套用，封面在 `ArtworkCache` 网关注入判定。
class DataSaverService extends ChangeNotifier {
  DataSaverService({
    SharedPreferences? prefs,
    Future<bool> Function()? cellularProbe,
    Stream<bool>? cellularChanges,
  })  : _prefsOverride = prefs,
        _cellularProbe = cellularProbe,
        _cellularChanges = cellularChanges;

  // --- 持久化键名（设置 UI / 测试共用） ---
  static const String keyEnabled = 'data_saver_enabled';
  static const String keyQuality = 'data_saver_quality';
  static const String keyCovers = 'data_saver_covers';

  // --- 默认值 ---
  static const bool defaultEnabled = false;
  static const String defaultQuality = '128k';
  static const bool defaultCovers = true;

  /// 省流音质上限可选项（值为 LX 音质标识，与取链链路同源）。
  static const List<String> qualityOptions = ['128k', '192k', '320k'];

  final SharedPreferences? _prefsOverride;
  final Future<bool> Function()? _cellularProbe;
  final Stream<bool>? _cellularChanges;
  final Logger _logger = Logger();

  SharedPreferences? _prefs;
  StreamSubscription<bool>? _subscription;

  bool _enabled = defaultEnabled;
  String _quality = defaultQuality;
  bool _coversSaverEnabled = defaultCovers;
  bool _onCellular = false;
  bool _detectionAvailable = true;

  /// 是否开启省流模式（用户手动开关；开启不等于已生效）。
  bool get enabled => _enabled;

  /// 省流音质上限。
  String get qualityCap => _quality;

  /// 生效时是否同时限制封面（仅使用本地缓存）。
  bool get coversSaverEnabled => _coversSaverEnabled;

  /// 当前是否处于移动数据网络。
  bool get onCellular => _onCellular;

  /// 网络类型检测是否可用（失败时 UI 可提示「无法检测网络类型」）。
  bool get detectionAvailable => _detectionAvailable;

  /// 省流是否实际生效：已开启且当前为移动数据。
  bool get active => _enabled && _onCellular;

  /// 当前实际应使用的取链音质：生效时把偏好压到上限，否则原样返回。
  String effectiveQuality(String preferred) =>
      active ? capQualityFor(preferred, _quality) : preferred;

  /// 是否阻止封面发起网络请求（生效 + 封面省流开启）。
  ///
  /// `ArtworkCache` / 播放器取色 / 预加载 / 通知封面 / 桌面小组件共用该判定。
  bool get blockNetworkArtwork => active && _coversSaverEnabled;

  /// 读取持久化偏好并开始监听网络变化（启动时调用一次）。
  Future<void> init() async {
    await _loadPreferences();
    await refreshConnectivity();
    try {
      final changes = _cellularChanges ??
          Connectivity()
              .onConnectivityChanged
              .map(_resultsAreCellular);
      _subscription = changes.listen(
        (value) {
          _detectionAvailable = true;
          _setOnCellular(value);
        },
        onError: (Object error) {
          _logger.w('省流模式：网络变化监听失败: $error');
        },
      );
    } catch (e) {
      _logger.w('省流模式：网络变化监听初始化失败: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await _write(keyEnabled, value);
  }

  Future<void> setQualityCap(String value) async {
    if (!qualityOptions.contains(value) || _quality == value) return;
    _quality = value;
    notifyListeners();
    await _write(keyQuality, value);
  }

  Future<void> setCoversSaverEnabled(bool value) async {
    if (_coversSaverEnabled == value) return;
    _coversSaverEnabled = value;
    notifyListeners();
    await _write(keyCovers, value);
  }

  /// 重新探测当前网络类型。
  ///
  /// Android 在后台不再广播网络变化（Android 8+），因此 App 回到前台时
  /// 必须主动刷新一次，否则「离开 Wi-Fi 后仍按 Wi-Fi 判定」。
  Future<void> refreshConnectivity() async {
    try {
      final cellular = await (_cellularProbe ?? _probeCellular)();
      _detectionAvailable = true;
      _setOnCellular(cellular);
    } catch (e) {
      _logger.w('省流模式：网络类型检测失败: $e');
      final changed = _detectionAvailable || _onCellular;
      _detectionAvailable = false;
      // 检测不到时保守保持「未生效」，避免在未知网络上误降音质。
      _onCellular = false;
      if (changed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  void _setOnCellular(bool value) {
    if (_onCellular == value) return;
    _onCellular = value;
    notifyListeners();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await _prefsOrNull();
      if (prefs == null) return;
      _enabled = prefs.getBool(keyEnabled) ?? defaultEnabled;
      final quality = prefs.getString(keyQuality);
      if (quality != null && qualityOptions.contains(quality)) {
        _quality = quality;
      }
      _coversSaverEnabled = prefs.getBool(keyCovers) ?? defaultCovers;
    } catch (e) {
      _logger.w('省流模式：读取偏好失败: $e');
    }
  }

  Future<void> _write(String key, Object value) async {
    try {
      final prefs = await _prefsOrNull();
      if (prefs == null) return;
      if (value is bool) {
        await prefs.setBool(key, value);
      } else {
        await prefs.setString(key, value.toString());
      }
    } catch (e) {
      _logger.w('省流模式：保存偏好失败: $e');
    }
  }

  Future<SharedPreferences?> _prefsOrNull() async {
    if (_prefsOverride != null) return _prefsOverride;
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _probeCellular() async =>
      _resultsAreCellular(await Connectivity().checkConnectivity());

  /// 是否为蜂窝网络：结果含 mobile，且不同时存在 wifi / ethernet。
  ///
  /// Android 在同时开启移动数据与 Wi-Fi 时只返回 wifi；仍显式排除
  /// wifi/ethernet 以覆盖多结果返回与桌面平台的行为差异。
  static bool _resultsAreCellular(List<ConnectivityResult> results) {
    return results.contains(ConnectivityResult.mobile) &&
        !results.contains(ConnectivityResult.wifi) &&
        !results.contains(ConnectivityResult.ethernet);
  }
}
