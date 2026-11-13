/// 本地身份迁移的第三阶段：自定义封面键清扫（可重试、设备本地）。
///
/// 为什么与 DB 迁移分开：封面索引在 SharedPreferences，不能进 SQLite 事务；
/// 失败时 DB 已经是 v3，下次启动重跑即可。完成标记只在成功后写入。
library;

import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/downloads/downloads_repository.dart';
import '../../data/local_identity.dart';
import 'covers/cover_resolution.dart' show normalizeCoverKey;
import 'covers/custom_cover_store.dart';

class LocalCoverIdentitySweep {
  LocalCoverIdentitySweep({
    required this.covers,
    required this.downloads,
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  /// 设备本地完成标记（不登记进设置注册表、不参与同步）。
  static const String prefsMarkerKey = 'local_cover_identity_sweep_v1';

  final CustomCoverStore covers;
  final DownloadsRepository downloads;
  final Future<SharedPreferences> Function() _preferences;
  final Logger _logger = Logger('molia.local_cover_identity_sweep');

  /// 未完成时执行一次；已完成 / 失败都不阻断启动。
  Future<void> sweepIfNeeded() async {
    final SharedPreferences prefs;
    try {
      prefs = await _preferences();
    } catch (_) {
      return;
    }
    if (prefs.getBool(prefsMarkerKey) == true) return;
    try {
      final imports = await downloads.listImported();
      final renames = <String, String>{};
      for (final record in imports) {
        final localKey = record.localKey;
        final path = record.filePath;
        if (localKey == null || !isStableLocalKey(localKey)) continue;
        if (path == null || path.isEmpty) continue;
        final legacyKey = legacyLocalIdentityOf(path);
        // 索引里可能是规范形式（剥过一层 local:）或原始形式；按优先级取
        // 实际存在的那一个，两个都存在时保留原始键（另一个按孤儿留下）。
        for (final candidate in [legacyKey, normalizeCoverKey(legacyKey)]) {
          if (candidate == localKey) continue;
          if (covers.trackEntry(candidate) != null) {
            renames[candidate] = localKey;
            break;
          }
        }
      }
      final moved = await covers.migrateTrackCoverKeys(renames);
      await prefs.setBool(prefsMarkerKey, true);
      if (moved > 0) _logger.info('本地封面键已迁移 $moved 个');
    } catch (e) {
      // 不写完成标记：下次启动重试；重复执行不会二次改写。
      _logger.warning('本地封面键迁移失败，下次启动重试：$e');
    }
  }
}
