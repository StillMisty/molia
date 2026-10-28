import 'package:flutter_test/flutter_test.dart';
import 'package:molia/managers/app_memory_manager.dart';
import 'package:molia/services/app_presence.dart';

/// 托盘期内存守卫：隐藏后清图片缓存并压低上限，恢复还原；最小化不动缓存。
///
/// 用假 [ImageCacheTarget]：真实 `ImageCache` 的清理语义不在本文件断言面内
/// （生产实现只是一层转发）。
class _FakeImageCache implements ImageCacheTarget {
  _FakeImageCache();

  @override
  int currentSizeBytes = 42 * 1024 * 1024;

  @override
  int maximumSizeBytes = 100 * 1024 * 1024;

  int clearCount = 0;
  int clearLiveCount = 0;

  @override
  void clear() {
    clearCount++;
    currentSizeBytes = 0;
  }

  @override
  void clearLiveImages() => clearLiveCount++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('托盘隐藏：等休眠帧后清缓存并压低上限；恢复还原', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    presence.markTrayHidden();
    // 休眠树在下一帧换上，守卫等该帧结束才清（live 引用先释放）。
    await tester.pump();
    await tester.pump();

    expect(cache.clearCount, 1);
    expect(cache.clearLiveCount, 1);
    expect(cache.maximumSizeBytes, kTrayImageCacheLimitBytes);

    presence.markVisible();
    expect(cache.maximumSizeBytes, 100 * 1024 * 1024);
  });

  testWidgets('最小化不动缓存（只由消费者停后台解码）', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    presence.markMinimized();
    await tester.pump();

    expect(cache.clearCount, 0);
    expect(cache.maximumSizeBytes, 100 * 1024 * 1024);
  });

  testWidgets('隐藏→恢复快速往返：在途清理作废，不误清已恢复的会话', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    presence.markTrayHidden();
    presence.markVisible();
    await tester.pump();
    await tester.pump();

    expect(cache.clearCount, 0);
    expect(cache.maximumSizeBytes, 100 * 1024 * 1024);
  });

  testWidgets('托盘隐藏：业务缓存释放回调在休眠帧后执行；最小化 / 恢复不执行',
      (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    var releases = 0;
    void releaser() => releases++;
    manager.addReleaser(releaser);

    presence.markMinimized();
    await tester.pump();
    expect(releases, 0, reason: '最小化要跟手恢复，不释放业务缓存');

    presence.markTrayHidden();
    await tester.pump();
    await tester.pump();
    expect(releases, 1);

    presence.markVisible();
    expect(releases, 1, reason: '恢复窗口不触发释放');

    // 取消注册后再次隐藏不再触发。
    manager.removeReleaser(releaser);
    presence.markTrayHidden();
    await tester.pump();
    await tester.pump();
    expect(releases, 1);
  });

  testWidgets('隐藏→恢复快速往返：不触发业务缓存释放', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    var releases = 0;
    manager.addReleaser(() => releases++);

    presence.markTrayHidden();
    presence.markVisible();
    await tester.pump();
    await tester.pump();

    expect(releases, 0, reason: 'token 已变，休眠帧后不再释放');
  });

  testWidgets('单个释放回调抛错不影响其它回调与图片缓存清理', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    var releases = 0;
    manager.addReleaser(() => throw StateError('boom'));
    manager.addReleaser(() => releases++);

    presence.markTrayHidden();
    await tester.pump();
    await tester.pump();

    expect(releases, 1);
    expect(cache.clearCount, 1);
  });

  testWidgets('attach 时已处于托盘隐藏：立即校正一次', (tester) async {
    final presence = AppPresence(AppPresenceState.trayHidden);
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    await tester.pump();
    await tester.pump();

    expect(cache.clearCount, 1);
    expect(cache.maximumSizeBytes, kTrayImageCacheLimitBytes);
  });
}
