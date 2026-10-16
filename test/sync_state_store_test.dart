import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/sync/sync_state_store.dart';
import 'package:molia/domain/models/device_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/sync_test_support.dart';

/// 同步状态存储：蜂窝策略的持久化与宽容解析。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<SyncStateStore> freshStore() async {
    final store = SyncStateStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySyncSecretStore(),
      clock: () => 1000,
    );
    await store.init();
    return store;
  }

  test('蜂窝策略默认 auto，写入后跨实例保持', () async {
    final store = await freshStore();
    expect(store.cellularPolicy, SyncCellularPolicy.auto);

    await store.setCellularPolicy(SyncCellularPolicy.pause);

    final reloaded = await freshStore();
    expect(reloaded.cellularPolicy, SyncCellularPolicy.pause);
  });

  test('未知策略值回落到 auto', () async {
    final store = SyncStateStore(
      preferences: await SharedPreferences.getInstance(),
      secrets: MemorySyncSecretStore(),
      clock: () => 1000,
    );
    await store.init();
    expect(SyncCellularPolicy.parse('unknown'), SyncCellularPolicy.auto);
    expect(SyncCellularPolicy.parse(null), SyncCellularPolicy.auto);
  });
}
