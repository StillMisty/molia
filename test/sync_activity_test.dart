import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_activity.dart';

/// 近 24 小时活动汇总：窗口过滤、有效传输判定与流量合计。
void main() {
  const hour = 60 * 60 * 1000;
  const now = 100 * hour;

  SyncActivityEntry entry({
    required int at,
    int bytesIn = 0,
    int bytesOut = 0,
    int applied = 0,
  }) =>
      SyncActivityEntry(
        at: at,
        bytesIn: bytesIn,
        bytesOut: bytesOut,
        applied: applied,
      );

  test('只统计 24 小时窗口内的轮次', () {
    final summary = SyncActivitySummary.fromEntries([
      entry(at: now - 25 * hour, bytesOut: 999),
      entry(at: now - 23 * hour, bytesOut: 100),
      entry(at: now, bytesOut: 50),
    ], nowMs: now);

    expect(summary.rounds, 2);
    expect(summary.bytesOut, 150);
  });

  test('有效传输轮数：有字节流转或有记录落地', () {
    final summary = SyncActivitySummary.fromEntries([
      entry(at: now, bytesIn: 10), // 有效（有字节）
      entry(at: now, applied: 3), // 有效（有落地）
      entry(at: now), // 空闲轮：无效传输
      entry(at: now), // 空闲轮：无效传输
    ], nowMs: now);

    expect(summary.rounds, 4);
    expect(summary.effectiveRounds, 2);
    expect(summary.bytes, 10);
  });

  test('没有轮次时为空', () {
    final summary = SyncActivitySummary.fromEntries(const [], nowMs: now);
    expect(summary.isEmpty, isTrue);
    expect(summary.rounds, 0);
    expect(summary.effectiveRounds, 0);
    expect(summary.bytes, 0);
  });

  test('活动记录序列化往返（缺省字段不写）', () {
    const entry = SyncActivityEntry(
      at: 1234,
      bytesIn: 10,
      bytesOut: 20,
      applied: 3,
    );
    final restored = SyncActivityEntry.fromJson(entry.toJson());
    expect(restored!.at, 1234);
    expect(restored.bytesIn, 10);
    expect(restored.bytesOut, 20);
    expect(restored.applied, 3);

    const empty = SyncActivityEntry(at: 99);
    expect(empty.toJson(), {'at': 99});
    expect(SyncActivityEntry.fromJson({'nope': 1}), isNull);
  });
}
