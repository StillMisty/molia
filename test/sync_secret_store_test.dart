import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/settings/settings_secret_store.dart';
import 'package:molia/data/sync/sync_state_store.dart';

/// 安全存储读取容错（回归：WSLg / 容器等无系统钥匙串的环境里
/// libsecret 抛异常，未捕获会打断 `main()` 的 `runApp` 之前部分，
/// 桌面端表现为「窗口已显示但没有首帧」的永久黑窗，见 pitfalls #31）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = SecureSettingsSecretStore();

  test('读取失败降级为「未设置」：返回 null，不抛异常', () async {
    // 单测环境没有 libsecret 平台实现：修复前这里会抛 MissingPluginException。
    expect(await store.read('sync_passphrase_v1'), isNull);
  });

  test('写入仍然抛出：用户主动操作要知道没存进去', () async {
    await expectLater(
      store.write('sync_passphrase_v1', 'secret'),
      throwsA(isA<Exception>()),
    );
  });

  test('SyncStateStore.readPassphrase 在无钥匙串时同样返回 null', () async {
    final state = SyncStateStore(secrets: store, deviceId: 'test-device');
    expect(await state.readPassphrase(), isNull);
    expect(await state.readWebdavPassword(), isNull);
  });
}
