/// 听歌同步的本地发件箱：有界、可持久、按服务隔离。
///
/// 设计要点：
/// - 只存事件与重试状态，不存令牌；写入走 SharedPreferences 单键 JSON
///   （设备本地，不登记同步）；
/// - 每个服务最多 [maxEntriesPerTarget] 条、最多 [maxAge] 天；先丢最旧的；
/// - 失败后的退避时间由 [ScrobbleRules.backoffFor] 计算，429 的
///   `Retry-After` 优先；
/// - 发送成功（或判定不可恢复）才删除条目；进程被杀时最多重发一条，
///   协议侧按时间戳去重。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/scrobble.dart';
import '../../domain/scrobble/scrobble_rules.dart';

class ScrobbleOutboxEntry {
  const ScrobbleOutboxEntry({
    required this.event,
    this.attempts = 0,
    this.nextAttemptAt,
  });

  final ScrobbleEvent event;
  final int attempts;
  final DateTime? nextAttemptAt;

  ScrobbleOutboxEntry copyWith({int? attempts, DateTime? nextAttemptAt}) =>
      ScrobbleOutboxEntry(
        event: event,
        attempts: attempts ?? this.attempts,
        nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      );

  Map<String, Object?> toJson() => {
    'id': event.id,
    'target': event.target.name,
    'kind': event.kind.name,
    'created_at': event.createdAt.toUtc().millisecondsSinceEpoch,
    'started_at': event.listen.startedAt.toUtc().millisecondsSinceEpoch,
    'title': event.listen.track.title,
    'artist': event.listen.track.artist,
    'album': event.listen.track.album,
    'duration_ms': event.listen.track.duration.inMilliseconds,
    'track_number': event.listen.track.trackNumber,
    'attempts': attempts,
    'next_attempt_at': nextAttemptAt?.toUtc().millisecondsSinceEpoch,
  };

  /// 容错解析：缺字段 / 非法枚举返回 null（整条丢弃）。
  static ScrobbleOutboxEntry? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final targetName = value['target'];
    final kindName = value['kind'];
    final title = value['title'];
    final artist = value['artist'];
    final createdAt = value['created_at'];
    final startedAt = value['started_at'];
    final durationMs = value['duration_ms'];
    if (id is! String ||
        targetName is! String ||
        kindName is! String ||
        title is! String ||
        artist is! String ||
        createdAt is! int ||
        startedAt is! int ||
        durationMs is! int) {
      return null;
    }
    final target = _targetByName(targetName);
    final kind = _kindByName(kindName);
    if (target == null || kind == null) return null;
    final album = value['album'];
    final trackNumber = value['track_number'];
    final attempts = value['attempts'];
    final nextAttemptAt = value['next_attempt_at'];
    return ScrobbleOutboxEntry(
      event: ScrobbleEvent(
        id: id,
        target: target,
        kind: kind,
        listen: ScrobbleListen(
          track: ScrobbleTrack(
            title: title,
            artist: artist,
            album: album is String ? album : null,
            duration: Duration(milliseconds: durationMs),
            trackNumber: trackNumber is int ? trackNumber : null,
          ),
          startedAt: DateTime.fromMillisecondsSinceEpoch(
            startedAt,
            isUtc: true,
          ),
        ),
        createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true),
      ),
      attempts: attempts is int && attempts >= 0 ? attempts : 0,
      nextAttemptAt: nextAttemptAt is int
          ? DateTime.fromMillisecondsSinceEpoch(nextAttemptAt, isUtc: true)
          : null,
    );
  }

  static ScrobbleTarget? _targetByName(String name) {
    for (final target in ScrobbleTarget.values) {
      if (target.name == name) return target;
    }
    return null;
  }

  static ScrobbleEventKind? _kindByName(String name) {
    for (final kind in ScrobbleEventKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

class ScrobbleOutbox {
  ScrobbleOutbox({
    SharedPreferences? prefs,
    DateTime Function()? clock,
    double Function()? random,
  }) : _prefsOverride = prefs,
       _clock = clock ?? DateTime.now,
       _random = random ?? math.Random().nextDouble;

  /// 设备本地单键（不登记同步、不进备份）。
  static const String key = 'scrobble_outbox_v1';
  static const int maxEntriesPerTarget = 100;
  static const Duration maxAge = Duration(days: 30);

  final SharedPreferences? _prefsOverride;
  final DateTime Function() _clock;
  final double Function() _random;
  SharedPreferences? _prefs;
  final List<ScrobbleOutboxEntry> _entries = [];

  Future<SharedPreferences> _prefsStore() async =>
      _prefs ??= _prefsOverride ?? await SharedPreferences.getInstance();

  /// 读取并清理过期 / 超量条目；损坏的 JSON 按空箱处理。
  Future<void> load() async {
    _entries.clear();
    try {
      final prefs = await _prefsStore();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final item in decoded) {
        final entry = ScrobbleOutboxEntry.tryFromJson(item);
        if (entry != null) _entries.add(entry);
      }
      _prune();
    } catch (_) {
      _entries.clear();
    }
  }

  /// 当前条目数（测试 / 诊断）。
  int get length => _entries.length;

  int lengthFor(ScrobbleTarget target) =>
      _entries.where((entry) => entry.event.target == target).length;

  /// 已到期、按入队时间排序的条目（每个服务一条在途由服务层保证）。
  List<ScrobbleOutboxEntry> due(ScrobbleTarget target, {DateTime? now}) {
    final at = now ?? _clock();
    final list = [
      for (final entry in _entries)
        if (entry.event.target == target &&
            (entry.nextAttemptAt == null || !entry.nextAttemptAt!.isAfter(at)))
          entry,
    ]..sort((a, b) => a.event.createdAt.compareTo(b.event.createdAt));
    return list;
  }

  bool get hasAnyDue {
    final now = _clock();
    return _entries.any(
      (entry) =>
          entry.nextAttemptAt == null || !entry.nextAttemptAt!.isAfter(now),
    );
  }

  /// 入队（先复制目标，避免规则层的中性占位泄漏到 outbox）。
  Future<void> add(ScrobbleEvent event) async {
    _entries.add(ScrobbleOutboxEntry(event: event, nextAttemptAt: _clock()));
    _prune();
    await _persist();
  }

  /// 成功：删除该条。
  Future<void> markDelivered(String eventId) async {
    _entries.removeWhere((entry) => entry.event.id == eventId);
    await _persist();
  }

  /// 可重试失败：累加次数并写入下次尝试时间；[retryAfter] 优先于退避。
  Future<void> markRetry(String eventId, {Duration? retryAfter}) async {
    final index = _entries.indexWhere((entry) => entry.event.id == eventId);
    if (index < 0) return;
    final entry = _entries[index];
    final attempts = entry.attempts + 1;
    final delay =
        retryAfter ?? ScrobbleRules.backoffFor(attempts, jitter: _random());
    _entries[index] = entry.copyWith(
      attempts: attempts,
      nextAttemptAt: _clock().add(delay),
    );
    await _persist();
  }

  /// 不可恢复：删除该条，避免永久重试。
  Future<void> drop(String eventId) async {
    _entries.removeWhere((entry) => entry.event.id == eventId);
    await _persist();
  }

  /// 断开某个服务：丢弃它全部排队事件。
  Future<void> discardTarget(ScrobbleTarget target) async {
    _entries.removeWhere((entry) => entry.event.target == target);
    await _persist();
  }

  Future<void> clear() async {
    _entries.clear();
    await _persist();
  }

  /// 下一次需要唤醒的最早时间（无条目返回 null）。
  DateTime? nextDueAt({Set<ScrobbleTarget>? targets}) {
    DateTime? earliest;
    for (final entry in _entries) {
      if (targets != null && !targets.contains(entry.event.target)) continue;
      final at = entry.nextAttemptAt;
      if (at == null) return _clock();
      if (earliest == null || at.isBefore(earliest)) earliest = at;
    }
    return earliest;
  }

  /// 数量与年龄上限：先按年龄过期，再按服务裁掉最旧的。
  void _prune() {
    final cutoff = _clock().subtract(maxAge);
    _entries.removeWhere((entry) => entry.event.createdAt.isBefore(cutoff));
    for (final target in ScrobbleTarget.values) {
      final targetEntries = [
        for (final entry in _entries)
          if (entry.event.target == target) entry,
      ]..sort((a, b) => a.event.createdAt.compareTo(b.event.createdAt));
      final overflow = targetEntries.length - maxEntriesPerTarget;
      if (overflow <= 0) continue;
      final dropIds = targetEntries
          .take(overflow)
          .map((e) => e.event.id)
          .toSet();
      _entries.removeWhere((entry) => dropIds.contains(entry.event.id));
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await _prefsStore();
      await prefs.setString(
        key,
        jsonEncode([for (final entry in _entries) entry.toJson()]),
      );
    } catch (_) {
      // 发件箱落盘失败不打断播放；下一次写入会再尝试。
    }
  }
}
