/// 渠道偏好模块：音质偏好 / 渠道顺序 / 停用渠道的唯一持有者与持久化边界。
///
/// 从 `SourceManager` 拆出（原先三份状态与 9 处各写一份 try/catch 的持久化
/// 混在管理器里）：状态与读写只有这一份，写失败统一吞掉（存储不可用不阻塞
/// UI，内存状态已生效——与迁移前行为逐处对齐）。
///
/// 边界：
/// - 本模块是 [ChangeNotifier]：偏好变化在改完内存后立即通知；
///   `SourceManager` 订阅并转发自己的通知，UI（音源页 / 设置页）据此刷新；
/// - 跨设备同步应用远端值后的定向重载在构造时自绑（键的声明仍是
///   `data/settings/settings_keys.dart` 的唯一事实）；
/// - 「渠道列表怎么排/有哪些」不属于本模块：那依赖激活脚本声明的源，
///   由 `SourceManager.channels` 消费本模块的顺序与停用集合。
library;

import 'package:flutter/foundation.dart';

import '../data/settings/settings_keys.dart';
import '../data/settings/settings_registry.dart';
import 'source_track.dart' show kLxQualityOrder;

class SourcePreferences extends ChangeNotifier {
  SourcePreferences(SettingsRegistry settings) : _settings = settings {
    // 应用远端设置后的定向重载：三个键共用一个幂等的整表重读。
    _settings.bindReload(kLxDefaultQuality, reload);
    _settings.bindReload(kLxSourceOrder, reload);
    _settings.bindReload(kLxChannelDisabled, reload);
  }

  /// 音质偏好的默认值（`reload` 的先重置值，与键默认值一致）。
  static const String _defaultQuality = '320k';

  static const List<String> _supportedQualitys = kLxQualityOrder;

  final SettingsRegistry _settings;

  String _preferredQuality = _defaultQuality;
  List<String> _sourceOrder = const [];
  Set<String> _disabledChannels = {};

  /// 默认音质偏好。
  String get preferredQuality => _preferredQuality;

  /// 用户自定义的渠道顺序（持久化；未列出的渠道排在末尾，见
  /// `SourceManager.applySourceOrder`）。
  List<String> get sourceOrder => List.unmodifiable(_sourceOrder);

  /// 已停用的渠道集合（持久化；停用只影响列表/选择，不影响已保存曲目的取链）。
  Set<String> get disabledChannels => Set.unmodifiable(_disabledChannels);

  /// 从存储读取偏好；不通知（调用方决定刷新时机：启动时静默，
  /// 重载时由 [reload] 统一通知）。
  Future<void> load() async {
    try {
      final quality = await _settings.read(kLxDefaultQuality);
      if (_supportedQualitys.contains(quality)) {
        _preferredQuality = quality;
      }
      final order = await _settings.read(kLxSourceOrder);
      if (order.isNotEmpty) {
        _sourceOrder = order;
      }
      final disabled = await _settings.read(kLxChannelDisabled);
      if (disabled.isNotEmpty) {
        _disabledChannels = disabled.toSet();
      }
    } catch (_) {
      // 存储不可用按默认值处理，不阻塞启动。
    }
  }

  /// 重新读取偏好（顺序 / 停用 / 音质）。跨设备同步应用远端设置后由
  /// 组合根经 [SettingsRegistry.bindReload] 触发；先重置为默认再加载，
  /// 保证远端「清空」也能生效。
  Future<void> reload() async {
    _preferredQuality = _defaultQuality;
    _sourceOrder = const [];
    _disabledChannels = <String>{};
    await load();
    notifyListeners();
  }

  Future<void> setPreferredQuality(String quality) async {
    if (!_supportedQualitys.contains(quality)) return;
    _preferredQuality = quality;
    notifyListeners();
    await _persist(() => _settings.write(kLxDefaultQuality, quality));
  }

  /// 覆盖渠道顺序（去重后持久化）。
  Future<void> setSourceOrder(List<String> keys) async {
    final cleaned = <String>[];
    for (final key in keys) {
      if (key.isEmpty || cleaned.contains(key)) continue;
      cleaned.add(key);
    }
    if (listEquals(_sourceOrder, cleaned)) return;
    _sourceOrder = cleaned;
    notifyListeners();
    await _persist(() => _settings.write(kLxSourceOrder, cleaned));
  }

  /// 启用 / 停用渠道（持久化）。停用后该渠道不再出现在资料页渠道选择
  /// 与搜索结果中；已保存内容仍可通过内部路由取链播放。
  Future<void> setChannelEnabled(String key, bool enabled) async {
    if (key.isEmpty) return;
    final changed =
        enabled ? _disabledChannels.remove(key) : _disabledChannels.add(key);
    if (!changed) return;
    notifyListeners();
    await _persist(
        () => _settings.write(kLxChannelDisabled, _disabledChannels.toList()));
  }

  /// 清空自定义渠道顺序，恢复「脚本音源在前、内置平台在后」的默认排序。
  Future<void> resetChannelOrder() async {
    if (_sourceOrder.isEmpty) return;
    _sourceOrder = const [];
    notifyListeners();
    await _persist(() => _settings.clear(kLxSourceOrder));
  }

  /// 统一持久化策略：写入失败吞掉（存储不可用不打断交互，内存状态已生效）。
  Future<void> _persist(Future<void> Function() write) async {
    try {
      await write();
    } catch (_) {}
  }
}
