import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 封面内容身份 → palette seed 的设备本地持久缓存。
///
/// 为什么需要：冷启动时封面往往已在磁盘缓存里，但重新解码整张图取色仍是
/// 启动路径上最贵的一步；记住「内容身份 → seed」后，首帧可以直接复用上次
/// 的结果，把取色留给稳态链路。
///
/// 这是**派生缓存**：seed 永远可以从封面像素重新算出来，因此：
/// - 只存本机，不登记 `SettingsRegistry`，不参与同步 / 备份；换设备或清数据
///   的代价只是下次启动多取一次色；
/// - 读取失败、版本不符、JSON 损坏都按「没有记录」处理，不阻断启动；
/// - 单键 JSON + 最多 [maxEntries] 条 LRU，避免 prefs 里散落大量小键。
class ArtworkPaletteSeedStore {
  /// [preferences] 仅测试注入；生产环境懒加载 `SharedPreferences` 单例。
  ArtworkPaletteSeedStore({SharedPreferences? preferences})
    : _preferencesOverride = preferences;

  /// 设备本地单键（值为 [formatVersion] 描述的 JSON）。
  static const String storageKey = 'cover_palette_seed_v1';

  /// 当前缓存版本；读取时不一致直接当空。
  ///
  /// 不只是 JSON 结构版本：只要会让同一 cacheKey 得到不同 seed / 方案的
  /// 行为变化都必须递增，否则旧 seed 会被当成新算法的结果，生成错误配色。
  /// 包括采样尺寸（`ArtworkPaletteService` 的 100px）、量化器 / 打分策略、
  /// `buildColorScheme` 的取色与配色生成逻辑。
  static const int formatVersion = 1;

  /// 最多保留的封面条目数。封面内容身份是 URL 派生值，32 条足够覆盖最近
  /// 播放 / 浏览过的封面，同时把 JSON 控制在几 KB。
  static const int maxEntries = 32;

  final SharedPreferences? _preferencesOverride;

  final Logger _logger = Logger('molia.artwork_palette_seed_store');

  /// 写队列尾：所有写 / 清请求按调用顺序串行，后一个能看到前一个的结果。
  Future<void>? _pendingWrite;

  /// 读取 [cacheKey] 的 seed；无记录 / 记录无效 / 存储不可用返回 null。
  ///
  /// 不等待写队列：`SharedPreferences.setString` 会先同步更新进程内缓存，
  /// 紧跟在写之后发起的读取已经能看到新值；让它排在一次慢写入后面只会
  /// 拖慢启动路径。
  Future<int?> read(String cacheKey) async {
    try {
      final prefs = await _resolvePreferences();
      return _decode(prefs.getString(storageKey))[cacheKey];
    } catch (e) {
      // 派生缓存不可用不是错误：上层按「需要重新取色」继续。
      _logger.warning('读取封面取色缓存失败: $e');
      return null;
    }
  }

  /// 写入 [cacheKey] 的 seed（内容变化时同 key 先删再插到 LRU 末尾，
  /// 超出上限淘汰最旧）。
  ///
  /// 相同 seed 不重复落盘，也不刷新 LRU 顺序：封面不变时每次启动 / 切歌
  /// 都会调用，重复整键 JSON 写入没有收益。写失败只记日志，不向调用方抛出。
  Future<void> write(String cacheKey, int seed) {
    return _enqueueWrite(() async {
      final prefs = await _resolvePreferences();
      final entries = _decode(prefs.getString(storageKey));
      if (entries[cacheKey] == seed) return;
      // 同 key 先删再插：即使内容变了，也要刷新它在 LRU 里的位置。
      entries.remove(cacheKey);
      entries[cacheKey] = seed;
      while (entries.length > maxEntries) {
        entries.remove(entries.keys.first);
      }
      final written = await prefs.setString(storageKey, _encode(entries));
      if (!written) {
        _logger.warning('封面取色缓存写入被平台拒绝');
      }
    });
  }

  /// 清空本机缓存（派生数据，只影响下次取色成本）。
  Future<void> clear() {
    return _enqueueWrite(() async {
      final prefs = await _resolvePreferences();
      final removed = await prefs.remove(storageKey);
      if (!removed) {
        _logger.warning('清除封面取色缓存被平台拒绝');
      }
    });
  }

  /// 懒加载：注入的 prefs 优先，生产环境才触碰平台通道。
  Future<SharedPreferences> _resolvePreferences() {
    final injected = _preferencesOverride;
    if (injected != null) return Future.value(injected);
    return SharedPreferences.getInstance();
  }

  /// 串行执行写请求：把新请求接在当前队尾之后。
  ///
  /// 每个 [write] 都在轮到自己时才解码当前 JSON，因此并发写不会互相覆盖
  /// （后来者能看到先到者刚写入的条目）。
  Future<void> _enqueueWrite(Future<void> Function() action) {
    final previous = _pendingWrite;
    final next = previous == null
        ? _runWrite(action)
        : previous.then((_) => _runWrite(action));
    _pendingWrite = next;
    return next;
  }

  Future<void> _runWrite(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      // 平台异常（通道不可用 / 磁盘满）只记日志：派生缓存写不进去，
      // 下次会比上次多一次取色，但不能让启动或 UI 路径看到失败。
      _logger.warning('写入封面取色缓存失败: $e');
    }
  }

  String _encode(Map<String, int> entries) =>
      jsonEncode({'v': formatVersion, 'entries': entries});

  /// 解码单键 JSON；任何结构问题都返回空表，且不抛异常。
  ///
  /// 返回的普通 Map 字面量在 Dart 里是 LinkedHashMap，按插入顺序迭代——
  /// 这份顺序就是持久化的 LRU 顺序。
  Map<String, int> _decode(String? raw) {
    final entries = <String, int>{};
    if (raw == null || raw.isEmpty) return entries;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return entries;
      if (decoded['v'] != formatVersion) return entries;
      final stored = decoded['entries'];
      if (stored is! Map) return entries;
      for (final entry in stored.entries) {
        final key = entry.key;
        final value = entry.value;
        // 单条不是 String → int 说明整份记录已不可信（旧格式 / 手工改坏）：
        // 整份当空，避免把部分条目和错误类型混在一起继续使用。
        if (key is! String || value is! int) {
          return <String, int>{};
        }
        entries[key] = value;
      }
      return entries;
    } catch (_) {
      // JSON 损坏：静默按空，派生缓存丢了只是多一次取色。
      return <String, int>{};
    }
  }
}
