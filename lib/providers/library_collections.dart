import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/library_repository.dart' show kFavoritesPlaylistName;
import '../domain/models/library.dart';

/// 合集（收藏 / 播放历史 / 自建列表）的哨兵、顺序、选择与滚动位置策略。
///
/// 从收藏页抽出的逻辑：默认选择解析、顺序/选择/滚动位置的持久化可独立
/// 测试，页面只保留 UI 状态（搜索/排序态）。列表顺序键为
/// `playlist:<id>`，收藏 / 历史为固定键。
class LibraryCollections {
  LibraryCollections({SharedPreferences? prefs}) : _prefsOverride = prefs;

  /// 尚未手动选择：每次解析按默认策略。
  static const int unset = -2;

  /// 「我的收藏」哨兵（可能还没有对应的 playlist 行）。
  static const int favoritesSentinel = -1;

  /// 播放历史伪合集哨兵（仅显式选择进入，不参与默认回退）。
  static const int historySentinel = -3;

  static const String orderKey = 'favorites_collection_order';
  static const String favoritesOrderKey = 'favorites';
  static const String historyOrderKey = 'history';

  /// 上次选中的合集（含收藏/历史哨兵；未保存时不存在）。
  static const String selectionKey = 'favorites_selected_collection';

  /// 各合集的滚动位置（JSON map：合集键 → offset）。
  static const String scrollOffsetsKey = 'favorites_scroll_offsets';

  static String playlistOrderKey(int id) => 'playlist:$id';

  final SharedPreferences? _prefsOverride;
  SharedPreferences? _prefs;

  /// 默认收藏列表 id（按名称查找；空收藏可能不存在对应行）。
  static int? favoritesPlaylistId(List<PlaylistInfo> playlists) {
    for (final playlist in playlists) {
      if (playlist.name == kFavoritesPlaylistName) return playlist.id;
    }
    return null;
  }

  /// 当前应展示的合集：手动选择有效则沿用；否则优先有曲目的收藏，
  /// 其次第一个非空列表，最后回退到（可能为空的）收藏。
  ///
  /// 播放历史是显式选择才会进入的伪合集，不参与默认回退。
  static int resolveSelection({
    required int selected,
    required List<PlaylistInfo> playlists,
    required int? favoritesId,
  }) {
    if (selected == historySentinel) return historySentinel;
    if (selected != unset && selected != favoritesSentinel) {
      if (playlists.any((playlist) => playlist.id == selected)) return selected;
    } else if (selected == favoritesSentinel) {
      return favoritesSentinel;
    }

    for (final playlist in playlists) {
      if (playlist.id == favoritesId) {
        if (playlist.trackCount > 0) return favoritesSentinel;
        break;
      }
    }
    for (final playlist in playlists) {
      if (playlist.id != favoritesId && playlist.trackCount > 0) {
        return playlist.id;
      }
    }
    return favoritesSentinel;
  }

  /// 顺序应用：持久化顺序优先，未记录的新键按自然顺序追加；
  /// 已删除列表的键自动忽略（只返回 [natural] 中存在的键）。
  static List<String> applyOrder(List<String> natural, List<String> stored) {
    final pending = <String>{...natural};
    final result = <String>[];
    for (final key in stored) {
      if (pending.remove(key)) result.add(key);
    }
    for (final key in natural) {
      if (pending.remove(key)) result.add(key);
    }
    return result;
  }

  /// 读取持久化顺序；不可用时返回空列表。
  Future<List<String>> loadOrder() async {
    try {
      final prefs = await _prefsOrNull();
      return prefs?.getStringList(orderKey) ?? const [];
    } catch (e) {
      debugPrint('[LibraryCollections] 读取合集顺序失败: $e');
      return const [];
    }
  }

  /// 保存顺序；失败静默（顺序丢失不影响功能）。
  Future<void> saveOrder(List<String> keys) async {
    try {
      final prefs = await _prefsOrNull();
      await prefs?.setStringList(orderKey, keys);
    } catch (e) {
      debugPrint('[LibraryCollections] 保存合集顺序失败: $e');
    }
  }

  /// 读取上次选中的合集；未保存/不可用时返回 null。
  Future<int?> loadSelection() async {
    try {
      final prefs = await _prefsOrNull();
      return prefs?.getInt(selectionKey);
    } catch (e) {
      debugPrint('[LibraryCollections] 读取合集选择失败: $e');
      return null;
    }
  }

  /// 保存当前选中的合集（含哨兵）；失败静默。
  Future<void> saveSelection(int id) async {
    try {
      final prefs = await _prefsOrNull();
      await prefs?.setInt(selectionKey, id);
    } catch (e) {
      debugPrint('[LibraryCollections] 保存合集选择失败: $e');
    }
  }

  /// 读取各合集滚动位置；未保存/数据非法时返回空 map。
  Future<Map<String, double>> loadScrollOffsets() async {
    try {
      final prefs = await _prefsOrNull();
      final raw = prefs?.getString(scrollOffsetsKey);
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is num)
            entry.key.toString(): (entry.value as num).toDouble(),
      };
    } catch (e) {
      debugPrint('[LibraryCollections] 读取滚动位置失败: $e');
      return const {};
    }
  }

  /// 保存各合集滚动位置（合集键 → offset）；失败静默。
  Future<void> saveScrollOffsets(Map<String, double> offsets) async {
    try {
      final prefs = await _prefsOrNull();
      await prefs?.setString(scrollOffsetsKey, jsonEncode(offsets));
    } catch (e) {
      debugPrint('[LibraryCollections] 保存滚动位置失败: $e');
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
}
