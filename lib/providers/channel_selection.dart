import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/settings/settings_access.dart';
import '../data/settings/settings_keys.dart';

/// 全局当前渠道的唯一持有者（发现内容与搜索共用）。
///
/// 为什么单独成模块：渠道偏好原来在 `DiscoverProvider` 与 `SearchProvider`
/// 各存一份，靠组合根 / 资料页 / Ctrl+F 在多个时机手工同步；任何一处漏同步
/// 都会让「热榜渠道」和「搜索渠道」分叉。这里只保留一个 key，两个消费方都读
/// 同一个实例，切换渠道只经 [select]。
///
/// 校验（停用 / 删除后的回退）规则也在本模块：调用方只提供「当前有效 key」
/// 的快照，[ensureValid] 负责在快照非空时把失效 key 换到第一个有效项。音源
/// 尚未初始化 / 脚本仍在激活时快照为空——此时绝不回退，避免覆盖用户保存的
/// 脚本渠道偏好。
///
/// **不自动订阅音源状态**：旧行为是资料页在渠道缺失且音源就绪时触发纠偏，
/// 搜索侧保持失效 key、只清空结果。模块只提供规则，触发时机仍留给页面。
class ChannelSelection extends ChangeNotifier {
  ChannelSelection({
    SettingsAccess? settings,
    required List<String> Function() validKeys,
    required String Function() defaultKey,
    String? initialKey,
  }) : // 公开参数名保持 settings / validKeys / ...，字段仍按本类惯例私有。
       // ignore: prefer_initializing_formals
       _settings = settings,
       // ignore: prefer_initializing_formals
       _validKeys = validKeys,
       // ignore: prefer_initializing_formals
       _defaultKey = defaultKey {
    final explicit = initialKey?.trim() ?? '';
    _explicitInitialKey = explicit.isNotEmpty;
    _key = _explicitInitialKey ? explicit : _defaultKey().trim();

    final settings = _settings;
    if (settings != null) {
      // 首次恢复；跨设备同步应用远端值后的 reload 由组合根挂载时绑定。
      unawaited(reloadFromPreferences());
    }
  }

  final SettingsAccess? _settings;
  final List<String> Function() _validKeys;
  final String Function() _defaultKey;

  /// 显式初始值（测试 / 恢复）优先于异步读盘，与旧 DiscoverProvider 的
  /// `initialChannelKey` 语义一致。
  bool _explicitInitialKey = false;

  /// 用户选择的代际：读盘 / reload 在 await 前抓取，返回时代际不同即丢弃。
  int _generation = 0;

  bool _disposed = false;

  String _key = '';

  /// 当前渠道 key（`''` 只可能出现在没有默认 key 的测试装配里）。
  String get key => _key;

  /// 切换渠道：空白或同值忽略；先通知（UI 立即响应），再异步落盘。
  ///
  /// 写失败静默：渠道偏好是可重建的 UI 状态，不值得为一次 prefs 写入失败
  /// 打断用户操作（与旧实现一致）。
  void select(String key) {
    final normalized = key.trim();
    if (normalized.isEmpty || normalized == _key) return;
    _generation++;
    _key = normalized;
    notifyListeners();
    final settings = _settings;
    if (settings == null) return;
    unawaited(
      settings.write(kDiscoverChannelKey, normalized).catchError((Object _) {}),
    );
  }

  /// 当前 key 不在有效集合时回退到第一个有效项。
  ///
  /// [validKeys] 为空表示「有效集合还没准备好」（音源未初始化 / 脚本激活
  /// 中），此时不做任何事；否则一次失效事件会把保存的脚本渠道临时冲掉。
  void ensureValid() {
    if (_disposed) return;
    final keys = _validKeys();
    if (keys.isEmpty) return;
    if (keys.contains(_key)) return;
    select(keys.first);
  }

  /// 读取持久化值（首次恢复与跨设备 reload 共用）。
  ///
  /// 代际守卫保证在途读取不会覆盖用户刚做出的选择。
  Future<void> reloadFromPreferences() async {
    final settings = _settings;
    if (settings == null) return;
    final generation = _generation;
    try {
      final value = (await settings.read(kDiscoverChannelKey)).trim();
      if (_disposed ||
          _explicitInitialKey ||
          generation != _generation ||
          value.isEmpty ||
          value == _key) {
        return;
      }
      _key = value;
      notifyListeners();
      // 读回的值可能已被停用 / 删除：保持旧时序，不在这里自动纠偏；由资料页
      // 在音源就绪后触发 [ensureValid]。
    } catch (_) {
      // 读取失败保持当前渠道（默认值 / 用户选择）。
    }
  }

  @override
  void dispose() {
    _disposed = true;
    // 让在途读盘的结果在返回时失效，dispose 后不再 notifyListeners。
    _generation++;
    super.dispose();
  }
}
