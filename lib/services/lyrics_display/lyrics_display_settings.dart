import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 未同步歌词（无时间轴）的展示策略。
enum UnsyncedBehavior { title, hide, firstLine }

/// 暂停时的歌词回退策略（桌面歌词 / 媒体元数据共用语义）。
enum LyricsPauseBehavior { keep, title, clear }

/// 无歌词（来源为空）时桌面悬浮窗的行为。
enum DesktopNoLyricsBehavior { title, hide }

/// 媒体元数据写入字段。
enum LyricsMetadataTarget { subtitle, artist, title, album }

/// 媒体元数据文本格式。
enum LyricsMetadataFormat { lyric, lyricTitle, titleLyric }

/// 桌面歌词文本水平对齐。
enum DesktopTextAlignX { left, center, right }

/// 桌面歌词文本垂直对齐。
enum DesktopTextAlignY { top, center, bottom }

/// 桌面悬浮歌词控制条按钮键（与 [LyricsDisplaySettings.desktopControls] 对应）。
abstract final class DesktopControlKeys {
  static const playPause = 'playPause';
  static const previous = 'previous';
  static const next = 'next';
  static const translation = 'translation';
  static const lock = 'lock';
  static const close = 'close';

  static const all = [
    playPause,
    previous,
    next,
    translation,
    lock,
    close,
  ];
}

/// 歌词显示配置：共享项 + 桌面歌词 / 通知栏·锁屏 / 蓝牙三组。
///
/// - 持久化为 SharedPreferences 单 JSON 键（`lyrics_display_settings_v1`），
///   读取时与默认值合并，新增键对旧数据向前兼容；
/// - 模型平台无关：颜色为 ARGB int、宽度为百分比、字号为逻辑字号
///   （Android 侧按 sp 解释，未来桌面窗口按逻辑 px 解释）；
/// - 悬浮窗位置由原生侧自行持久化（系统级窗口状态），不进本模型。
class LyricsDisplaySettings extends ChangeNotifier {
  LyricsDisplaySettings({SharedPreferences? prefs}) : _prefsOverride = prefs;

  // --- 持久化键名 ---
  static const String storageKey = 'lyrics_display_settings_v1';

  // --- 默认值 ---
  static const int defaultOffsetMs = 0;
  static const bool defaultTranslationEnabled = true;
  static const bool defaultRomaEnabled = false;
  static const UnsyncedBehavior defaultUnsyncedBehavior = UnsyncedBehavior.title;

  static const bool defaultDesktopEnabled = false;
  static const double defaultDesktopFontSize = 22;
  static const double defaultDesktopOpacity = 1.0;
  static const int defaultDesktopPlayedColor = 0xFFFFFFFF;
  static const int defaultDesktopUnplayedColor = 0xB3FFFFFF;
  static const int defaultDesktopShadowColor = 0x99000000;
  static const double defaultDesktopWidthPercent = 100;
  static const bool defaultDesktopSingleLine = false;
  static const int defaultDesktopMaxLines = 3;
  static const DesktopTextAlignX defaultDesktopTextAlignX = DesktopTextAlignX.center;
  static const DesktopTextAlignY defaultDesktopTextAlignY = DesktopTextAlignY.center;
  static const bool defaultDesktopLock = false;
  static const bool defaultDesktopFreezeOnScreenOff = true;
  static const LyricsPauseBehavior defaultDesktopPauseBehavior = LyricsPauseBehavior.keep;
  static const DesktopNoLyricsBehavior defaultDesktopNoLyricsBehavior = DesktopNoLyricsBehavior.title;
  static const bool defaultDesktopShowToggleAnimation = true;

  static const bool defaultNotificationEnabled = false;
  static const LyricsMetadataTarget defaultNotificationTarget = LyricsMetadataTarget.subtitle;
  static const LyricsMetadataFormat defaultNotificationFormat = LyricsMetadataFormat.lyric;
  static const bool defaultNotificationIncludeTranslation = true;
  static const LyricsPauseBehavior defaultNotificationPauseBehavior = LyricsPauseBehavior.title;

  static const bool defaultBluetoothEnabled = false;
  static const bool defaultBluetoothOnlyWhenA2dp = true;
  static const LyricsMetadataTarget defaultBluetoothTarget = LyricsMetadataTarget.artist;
  static const LyricsMetadataFormat defaultBluetoothFormat = LyricsMetadataFormat.lyric;
  static const bool defaultBluetoothIncludeTranslation = false;
  static const int defaultBluetoothUpdateIntervalMs = 0;
  static const LyricsPauseBehavior defaultBluetoothPauseBehavior = LyricsPauseBehavior.title;

  static const List<int> offsetRange = [-500, 500];
  static const List<double> fontSizeRange = [12, 48];
  static const List<double> opacityRange = [0.2, 1.0];
  static const List<double> widthRange = [40, 100];
  static const List<int> maxLinesRange = [1, 5];
  static const List<int> updateIntervalOptions = [0, 1000, 2000];

  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;

  bool _loaded = false;
  bool get loaded => _loaded;

  int _offsetMs = defaultOffsetMs;
  bool _translationEnabled = defaultTranslationEnabled;
  bool _romaEnabled = defaultRomaEnabled;
  UnsyncedBehavior _unsyncedBehavior = defaultUnsyncedBehavior;

  bool _desktopEnabled = defaultDesktopEnabled;
  double _desktopFontSize = defaultDesktopFontSize;
  double _desktopOpacity = defaultDesktopOpacity;
  int _desktopPlayedColor = defaultDesktopPlayedColor;
  int _desktopUnplayedColor = defaultDesktopUnplayedColor;
  int _desktopShadowColor = defaultDesktopShadowColor;
  double _desktopWidthPercent = defaultDesktopWidthPercent;
  bool _desktopSingleLine = defaultDesktopSingleLine;
  int _desktopMaxLines = defaultDesktopMaxLines;
  DesktopTextAlignX _desktopTextAlignX = defaultDesktopTextAlignX;
  DesktopTextAlignY _desktopTextAlignY = defaultDesktopTextAlignY;
  bool _desktopLock = defaultDesktopLock;
  bool _desktopFreezeOnScreenOff = defaultDesktopFreezeOnScreenOff;
  LyricsPauseBehavior _desktopPauseBehavior = defaultDesktopPauseBehavior;
  DesktopNoLyricsBehavior _desktopNoLyricsBehavior = defaultDesktopNoLyricsBehavior;
  bool _desktopShowToggleAnimation = defaultDesktopShowToggleAnimation;
  Map<String, bool> _desktopControls = {
    for (final key in DesktopControlKeys.all) key: true,
  };

  bool _notificationEnabled = defaultNotificationEnabled;
  LyricsMetadataTarget _notificationTarget = defaultNotificationTarget;
  LyricsMetadataFormat _notificationFormat = defaultNotificationFormat;
  bool _notificationIncludeTranslation = defaultNotificationIncludeTranslation;
  LyricsPauseBehavior _notificationPauseBehavior = defaultNotificationPauseBehavior;

  bool _bluetoothEnabled = defaultBluetoothEnabled;
  bool _bluetoothOnlyWhenA2dp = defaultBluetoothOnlyWhenA2dp;
  LyricsMetadataTarget _bluetoothTarget = defaultBluetoothTarget;
  LyricsMetadataFormat _bluetoothFormat = defaultBluetoothFormat;
  bool _bluetoothIncludeTranslation = defaultBluetoothIncludeTranslation;
  int _bluetoothUpdateIntervalMs = defaultBluetoothUpdateIntervalMs;
  LyricsPauseBehavior _bluetoothPauseBehavior = defaultBluetoothPauseBehavior;

  // --- 共享项 ---
  int get offsetMs => _offsetMs;
  bool get translationEnabled => _translationEnabled;
  bool get romaEnabled => _romaEnabled;
  UnsyncedBehavior get unsyncedBehavior => _unsyncedBehavior;

  // --- 桌面歌词 ---
  bool get desktopEnabled => _desktopEnabled;
  double get desktopFontSize => _desktopFontSize;
  double get desktopOpacity => _desktopOpacity;
  int get desktopPlayedColor => _desktopPlayedColor;
  int get desktopUnplayedColor => _desktopUnplayedColor;
  int get desktopShadowColor => _desktopShadowColor;
  double get desktopWidthPercent => _desktopWidthPercent;
  bool get desktopSingleLine => _desktopSingleLine;
  int get desktopMaxLines => _desktopMaxLines;
  DesktopTextAlignX get desktopTextAlignX => _desktopTextAlignX;
  DesktopTextAlignY get desktopTextAlignY => _desktopTextAlignY;
  bool get desktopLock => _desktopLock;
  bool get desktopFreezeOnScreenOff => _desktopFreezeOnScreenOff;
  LyricsPauseBehavior get desktopPauseBehavior => _desktopPauseBehavior;
  DesktopNoLyricsBehavior get desktopNoLyricsBehavior => _desktopNoLyricsBehavior;
  bool get desktopShowToggleAnimation => _desktopShowToggleAnimation;
  Map<String, bool> get desktopControls => Map.unmodifiable(_desktopControls);

  // --- 通知栏 / 锁屏 ---
  bool get notificationEnabled => _notificationEnabled;
  LyricsMetadataTarget get notificationTarget => _notificationTarget;
  LyricsMetadataFormat get notificationFormat => _notificationFormat;
  bool get notificationIncludeTranslation => _notificationIncludeTranslation;
  LyricsPauseBehavior get notificationPauseBehavior => _notificationPauseBehavior;

  // --- 蓝牙 ---
  bool get bluetoothEnabled => _bluetoothEnabled;
  bool get bluetoothOnlyWhenA2dp => _bluetoothOnlyWhenA2dp;
  LyricsMetadataTarget get bluetoothTarget => _bluetoothTarget;
  LyricsMetadataFormat get bluetoothFormat => _bluetoothFormat;
  bool get bluetoothIncludeTranslation => _bluetoothIncludeTranslation;
  int get bluetoothUpdateIntervalMs => _bluetoothUpdateIntervalMs;
  LyricsPauseBehavior get bluetoothPauseBehavior => _bluetoothPauseBehavior;

  /// 读取持久化配置（启动时调用一次；缺键回落默认值）。
  Future<void> init() async {
    final prefs = await _prefsOrNull();
    final raw = prefs?.getString(storageKey);
    if (raw != null) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          _applyJson(json.cast<String, dynamic>());
        }
      } catch (_) {
        // 损坏数据按默认值处理，不阻塞启动。
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setOffsetMs(int value) async {
    final clamped = value.clamp(offsetRange.first, offsetRange.last);
    if (clamped == _offsetMs) return;
    _offsetMs = clamped;
    _commit();
  }

  Future<void> setTranslationEnabled(bool value) async {
    if (value == _translationEnabled) return;
    _translationEnabled = value;
    _commit();
  }

  Future<void> setRomaEnabled(bool value) async {
    if (value == _romaEnabled) return;
    _romaEnabled = value;
    _commit();
  }

  Future<void> setUnsyncedBehavior(UnsyncedBehavior value) async {
    if (value == _unsyncedBehavior) return;
    _unsyncedBehavior = value;
    _commit();
  }

  Future<void> setDesktopEnabled(bool value) async {
    if (value == _desktopEnabled) return;
    _desktopEnabled = value;
    _commit();
  }

  Future<void> setDesktopFontSize(double value) async {
    final clamped = value.clamp(fontSizeRange.first, fontSizeRange.last);
    if (clamped == _desktopFontSize) return;
    _desktopFontSize = clamped;
    _commit();
  }

  Future<void> setDesktopOpacity(double value) async {
    final clamped = value.clamp(opacityRange.first, opacityRange.last);
    if (clamped == _desktopOpacity) return;
    _desktopOpacity = clamped;
    _commit();
  }

  Future<void> setDesktopPlayedColor(int value) async {
    if (value == _desktopPlayedColor) return;
    _desktopPlayedColor = value;
    _commit();
  }

  Future<void> setDesktopUnplayedColor(int value) async {
    if (value == _desktopUnplayedColor) return;
    _desktopUnplayedColor = value;
    _commit();
  }

  Future<void> setDesktopShadowColor(int value) async {
    if (value == _desktopShadowColor) return;
    _desktopShadowColor = value;
    _commit();
  }

  Future<void> setDesktopWidthPercent(double value) async {
    final clamped = value.clamp(widthRange.first, widthRange.last);
    if (clamped == _desktopWidthPercent) return;
    _desktopWidthPercent = clamped;
    _commit();
  }

  Future<void> setDesktopSingleLine(bool value) async {
    if (value == _desktopSingleLine) return;
    _desktopSingleLine = value;
    _commit();
  }

  Future<void> setDesktopMaxLines(int value) async {
    final clamped = value.clamp(maxLinesRange.first, maxLinesRange.last);
    if (clamped == _desktopMaxLines) return;
    _desktopMaxLines = clamped;
    _commit();
  }

  Future<void> setDesktopTextAlignX(DesktopTextAlignX value) async {
    if (value == _desktopTextAlignX) return;
    _desktopTextAlignX = value;
    _commit();
  }

  Future<void> setDesktopTextAlignY(DesktopTextAlignY value) async {
    if (value == _desktopTextAlignY) return;
    _desktopTextAlignY = value;
    _commit();
  }

  Future<void> setDesktopLock(bool value) async {
    if (value == _desktopLock) return;
    _desktopLock = value;
    _commit();
  }

  Future<void> setDesktopFreezeOnScreenOff(bool value) async {
    if (value == _desktopFreezeOnScreenOff) return;
    _desktopFreezeOnScreenOff = value;
    _commit();
  }

  Future<void> setDesktopPauseBehavior(LyricsPauseBehavior value) async {
    if (value == _desktopPauseBehavior) return;
    _desktopPauseBehavior = value;
    _commit();
  }

  Future<void> setDesktopNoLyricsBehavior(DesktopNoLyricsBehavior value) async {
    if (value == _desktopNoLyricsBehavior) return;
    _desktopNoLyricsBehavior = value;
    _commit();
  }

  Future<void> setDesktopShowToggleAnimation(bool value) async {
    if (value == _desktopShowToggleAnimation) return;
    _desktopShowToggleAnimation = value;
    _commit();
  }

  Future<void> setDesktopControlVisible(String key, bool value) async {
    if (!DesktopControlKeys.all.contains(key)) return;
    if (_desktopControls[key] == value) return;
    _desktopControls = {..._desktopControls, key: value};
    _commit();
  }

  Future<void> setNotificationEnabled(bool value) async {
    if (value == _notificationEnabled) return;
    _notificationEnabled = value;
    _commit();
  }

  Future<void> setNotificationTarget(LyricsMetadataTarget value) async {
    if (value == _notificationTarget) return;
    _notificationTarget = value;
    _commit();
  }

  Future<void> setNotificationFormat(LyricsMetadataFormat value) async {
    if (value == _notificationFormat) return;
    _notificationFormat = value;
    _commit();
  }

  Future<void> setNotificationIncludeTranslation(bool value) async {
    if (value == _notificationIncludeTranslation) return;
    _notificationIncludeTranslation = value;
    _commit();
  }

  Future<void> setNotificationPauseBehavior(LyricsPauseBehavior value) async {
    if (value == _notificationPauseBehavior) return;
    _notificationPauseBehavior = value;
    _commit();
  }

  Future<void> setBluetoothEnabled(bool value) async {
    if (value == _bluetoothEnabled) return;
    _bluetoothEnabled = value;
    _commit();
  }

  Future<void> setBluetoothOnlyWhenA2dp(bool value) async {
    if (value == _bluetoothOnlyWhenA2dp) return;
    _bluetoothOnlyWhenA2dp = value;
    _commit();
  }

  Future<void> setBluetoothTarget(LyricsMetadataTarget value) async {
    if (value == _bluetoothTarget) return;
    _bluetoothTarget = value;
    _commit();
  }

  Future<void> setBluetoothFormat(LyricsMetadataFormat value) async {
    if (value == _bluetoothFormat) return;
    _bluetoothFormat = value;
    _commit();
  }

  Future<void> setBluetoothIncludeTranslation(bool value) async {
    if (value == _bluetoothIncludeTranslation) return;
    _bluetoothIncludeTranslation = value;
    _commit();
  }

  Future<void> setBluetoothUpdateIntervalMs(int value) async {
    if (!updateIntervalOptions.contains(value)) return;
    if (value == _bluetoothUpdateIntervalMs) return;
    _bluetoothUpdateIntervalMs = value;
    _commit();
  }

  Future<void> setBluetoothPauseBehavior(LyricsPauseBehavior value) async {
    if (value == _bluetoothPauseBehavior) return;
    _bluetoothPauseBehavior = value;
    _commit();
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'offsetMs': _offsetMs,
        'translationEnabled': _translationEnabled,
        'romaEnabled': _romaEnabled,
        'unsyncedBehavior': _unsyncedBehavior.name,
        'desktop.enabled': _desktopEnabled,
        'desktop.fontSize': _desktopFontSize,
        'desktop.opacity': _desktopOpacity,
        'desktop.playedColor': _desktopPlayedColor,
        'desktop.unplayedColor': _desktopUnplayedColor,
        'desktop.shadowColor': _desktopShadowColor,
        'desktop.widthPercent': _desktopWidthPercent,
        'desktop.singleLine': _desktopSingleLine,
        'desktop.maxLines': _desktopMaxLines,
        'desktop.textAlignX': _desktopTextAlignX.name,
        'desktop.textAlignY': _desktopTextAlignY.name,
        'desktop.lock': _desktopLock,
        'desktop.freezeOnScreenOff': _desktopFreezeOnScreenOff,
        'desktop.pauseBehavior': _desktopPauseBehavior.name,
        'desktop.noLyricsBehavior': _desktopNoLyricsBehavior.name,
        'desktop.showToggleAnimation': _desktopShowToggleAnimation,
        'desktop.controls': _desktopControls,
        'notification.enabled': _notificationEnabled,
        'notification.target': _notificationTarget.name,
        'notification.format': _notificationFormat.name,
        'notification.includeTranslation': _notificationIncludeTranslation,
        'notification.pauseBehavior': _notificationPauseBehavior.name,
        'bluetooth.enabled': _bluetoothEnabled,
        'bluetooth.onlyWhenA2dp': _bluetoothOnlyWhenA2dp,
        'bluetooth.target': _bluetoothTarget.name,
        'bluetooth.format': _bluetoothFormat.name,
        'bluetooth.includeTranslation': _bluetoothIncludeTranslation,
        'bluetooth.updateIntervalMs': _bluetoothUpdateIntervalMs,
        'bluetooth.pauseBehavior': _bluetoothPauseBehavior.name,
      };

  void _applyJson(Map<String, dynamic> json) {
    _offsetMs = _intOf(json['offsetMs'], _offsetMs)
        .clamp(offsetRange.first, offsetRange.last);
    _translationEnabled =
        _boolOf(json['translationEnabled'], _translationEnabled);
    _romaEnabled = _boolOf(json['romaEnabled'], _romaEnabled);
    _unsyncedBehavior = _enumOf(
        json['unsyncedBehavior'], UnsyncedBehavior.values, _unsyncedBehavior);

    _desktopEnabled = _boolOf(json['desktop.enabled'], _desktopEnabled);
    _desktopFontSize = _doubleOf(json['desktop.fontSize'], _desktopFontSize)
        .clamp(fontSizeRange.first, fontSizeRange.last);
    _desktopOpacity = _doubleOf(json['desktop.opacity'], _desktopOpacity)
        .clamp(opacityRange.first, opacityRange.last);
    _desktopPlayedColor =
        _intOf(json['desktop.playedColor'], _desktopPlayedColor);
    _desktopUnplayedColor =
        _intOf(json['desktop.unplayedColor'], _desktopUnplayedColor);
    _desktopShadowColor =
        _intOf(json['desktop.shadowColor'], _desktopShadowColor);
    _desktopWidthPercent =
        _doubleOf(json['desktop.widthPercent'], _desktopWidthPercent)
            .clamp(widthRange.first, widthRange.last);
    _desktopSingleLine =
        _boolOf(json['desktop.singleLine'], _desktopSingleLine);
    _desktopMaxLines = _intOf(json['desktop.maxLines'], _desktopMaxLines)
        .clamp(maxLinesRange.first, maxLinesRange.last);
    _desktopTextAlignX = _enumOf(
        json['desktop.textAlignX'], DesktopTextAlignX.values, _desktopTextAlignX);
    _desktopTextAlignY = _enumOf(
        json['desktop.textAlignY'], DesktopTextAlignY.values, _desktopTextAlignY);
    _desktopLock = _boolOf(json['desktop.lock'], _desktopLock);
    _desktopFreezeOnScreenOff =
        _boolOf(json['desktop.freezeOnScreenOff'], _desktopFreezeOnScreenOff);
    _desktopPauseBehavior = _enumOf(json['desktop.pauseBehavior'],
        LyricsPauseBehavior.values, _desktopPauseBehavior);
    _desktopNoLyricsBehavior = _enumOf(json['desktop.noLyricsBehavior'],
        DesktopNoLyricsBehavior.values, _desktopNoLyricsBehavior);
    _desktopShowToggleAnimation = _boolOf(
        json['desktop.showToggleAnimation'], _desktopShowToggleAnimation);
    final controls = json['desktop.controls'];
    if (controls is Map) {
      _desktopControls = {
        for (final key in DesktopControlKeys.all)
          key: _boolOf(controls[key], _desktopControls[key] ?? true),
      };
    }

    _notificationEnabled =
        _boolOf(json['notification.enabled'], _notificationEnabled);
    _notificationTarget = _enumOf(json['notification.target'],
        LyricsMetadataTarget.values, _notificationTarget);
    _notificationFormat = _enumOf(json['notification.format'],
        LyricsMetadataFormat.values, _notificationFormat);
    _notificationIncludeTranslation = _boolOf(
        json['notification.includeTranslation'],
        _notificationIncludeTranslation);
    _notificationPauseBehavior = _enumOf(json['notification.pauseBehavior'],
        LyricsPauseBehavior.values, _notificationPauseBehavior);

    _bluetoothEnabled =
        _boolOf(json['bluetooth.enabled'], _bluetoothEnabled);
    _bluetoothOnlyWhenA2dp = _boolOf(
        json['bluetooth.onlyWhenA2dp'], _bluetoothOnlyWhenA2dp);
    _bluetoothTarget = _enumOf(json['bluetooth.target'],
        LyricsMetadataTarget.values, _bluetoothTarget);
    _bluetoothFormat = _enumOf(json['bluetooth.format'],
        LyricsMetadataFormat.values, _bluetoothFormat);
    _bluetoothIncludeTranslation = _boolOf(
        json['bluetooth.includeTranslation'], _bluetoothIncludeTranslation);
    final interval = _intOf(
        json['bluetooth.updateIntervalMs'], _bluetoothUpdateIntervalMs);
    if (updateIntervalOptions.contains(interval)) {
      _bluetoothUpdateIntervalMs = interval;
    }
    _bluetoothPauseBehavior = _enumOf(json['bluetooth.pauseBehavior'],
        LyricsPauseBehavior.values, _bluetoothPauseBehavior);
  }

  void _commit() {
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> _persist() async {
    final prefs = await _prefsOrNull();
    if (prefs == null) return;
    await prefs.setString(storageKey, jsonEncode(toJson()));
  }

  Future<SharedPreferences?> _prefsOrNull() async {
    if (_prefsOverride != null) return _prefsOverride;
    try {
      return _prefs ??= await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  static bool _boolOf(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  static int _intOf(Object? value, int fallback) =>
      value is num ? value.toInt() : fallback;

  static double _doubleOf(Object? value, double fallback) =>
      value is num ? value.toDouble() : fallback;

  static T _enumOf<T extends Enum>(Object? value, List<T> values, T fallback) {
    if (value is! String) return fallback;
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return fallback;
  }
}
