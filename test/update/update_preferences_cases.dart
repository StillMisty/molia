/// 更新偏好：pending 更新标记的写入 / 重新加载 / 清除与版本判定。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:molia/services/update/update_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('pending 写入后新实例 load 能读到；clear 后为空', () async {
    final preferences = UpdatePreferences();
    await preferences.load();
    expect(preferences.pendingUpdate, isNull);

    await preferences.markPendingUpdate(version: '1.2.3', build: 42);
    expect(preferences.pendingUpdate?.version, '1.2.3');
    expect(preferences.pendingUpdate?.build, 42);

    final reloaded = UpdatePreferences();
    await reloaded.load();
    expect(reloaded.pendingUpdate?.version, '1.2.3');
    expect(reloaded.pendingUpdate?.build, 42);

    await reloaded.clearPendingUpdate();
    expect(reloaded.pendingUpdate, isNull);

    final afterClear = UpdatePreferences();
    await afterClear.load();
    expect(afterClear.pendingUpdate, isNull);
  });

  test('PendingUpdate.isSatisfiedBy：当前更高 / 同版本 build 达标才算完成', () {
    const pending = PendingUpdate(version: '1.2.3', build: 42);

    expect(pending.isSatisfiedBy(version: '1.2.4', build: 43), isTrue);
    expect(pending.isSatisfiedBy(version: '1.2.3', build: 42), isTrue);
    expect(pending.isSatisfiedBy(version: '1.2.3', build: 43), isTrue);
    expect(pending.isSatisfiedBy(version: '1.2.3', build: 41), isFalse);
    expect(pending.isSatisfiedBy(version: '1.2.2', build: 99), isFalse);
  });
}
