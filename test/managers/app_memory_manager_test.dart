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
  int maximumSizeBytes = kFullImageCacheLimitBytes;

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

  testWidgets('attach 捕获 64 MiB 完整上限；托盘隐藏压到 16 MiB，恢复还原', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);

    presence.markTrayHidden();
    // 休眠树在下一帧换上，守卫等该帧结束才清（live 引用先释放）。
    await tester.pump();
    await tester.pump();

    expect(cache.clearCount, 1);
    expect(cache.clearLiveCount, 1);
    expect(cache.maximumSizeBytes, kTrayImageCacheLimitBytes);

    presence.markVisible();
    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);
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
    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);
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
    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);
  });

  testWidgets('托盘隐藏：业务缓存释放回调在休眠帧后执行；最小化 / 恢复不执行', (tester) async {
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
    // 收尾恢复：延迟 trim 计时不能在测试结束时仍挂着。
    presence.markVisible();
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
    presence.markVisible();
  });

  testWidgets('移动端退后台 30s：清图片缓存但不清 live，上限压到 16 MiB，回前台恢复', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    manager.onAppBackground();
    await tester.pump(kMobileBackgroundTrimDelay - const Duration(seconds: 1));
    expect(cache.clearCount, 0, reason: '30s 内快速切回不应触发清理');
    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);

    await tester.pump(const Duration(seconds: 1));
    expect(cache.clearCount, 1);
    expect(cache.clearLiveCount, 0, reason: 'Android 退后台不卸载 UI，live 封面必须保留');
    expect(cache.maximumSizeBytes, kTrayImageCacheLimitBytes);

    manager.onAppForeground();
    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);
  });

  testWidgets('移动端快速往返：回前台取消计时，不误清', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    manager.onAppBackground();
    await tester.pump(const Duration(seconds: 29));
    manager.onAppForeground();
    await tester.pump(const Duration(seconds: 5));

    expect(cache.clearCount, 0);
    expect(cache.clearLiveCount, 0);
    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);
  });

  testWidgets('移动端重复退后台事件不重置 30s 计时', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    manager.onAppBackground();
    await tester.pump(const Duration(seconds: 20));
    manager.onAppBackground(); // Android 的 hide / pause 可能先后到达同一状态
    await tester.pump(const Duration(seconds: 10));

    expect(cache.clearCount, 1);
  });

  testWidgets('dispose 取消移动端后台计时', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    manager.attach();

    manager.onAppBackground();
    manager.dispose();
    await tester.pump(kMobileBackgroundTrimDelay);

    expect(cache.clearCount, 0);
    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);
  });

  testWidgets('系统低内存：去抖后跑低内存 releaser，清非 live 图片缓存但保持完整上限', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    var trayReleases = 0;
    var lowMemoryReleases = 0;
    manager.addReleaser(() => trayReleases++);
    manager.addLowMemoryReleaser(() => lowMemoryReleases++);

    manager.onMemoryPressure();
    expect(cache.clearCount, 0, reason: '先给紧随其后的 UI_HIDDEN 一个取消窗口');
    await tester.pump(kMemoryPressureDebounce);

    expect(lowMemoryReleases, 1);
    expect(trayReleases, 0, reason: '低内存与托盘隐藏是两套触发时机，不能混用');
    expect(cache.clearCount, 1);
    expect(cache.clearLiveCount, 0, reason: 'live 封面仍被当前界面引用');
    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);
  });

  testWidgets('退后台的 UI_HIDDEN 伪低内存：取消清理，不清浏览缓存', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    var lowMemoryReleases = 0;
    manager.addLowMemoryReleaser(() => lowMemoryReleases++);

    // Android 实测顺序：先 didHaveMemoryPressure(UI_HIDDEN)，再生命周期
    // 退后台。后者必须取消前者，否则每次切后台都会清空浏览列表。
    manager.onMemoryPressure();
    manager.onAppBackground();
    await tester.pump(kMemoryPressureDebounce);

    expect(lowMemoryReleases, 0);
    expect(cache.clearCount, 0);
    expect(cache.maximumSizeBytes, kFullImageCacheLimitBytes);
    manager.onAppForeground();
  });

  testWidgets('已在后台超过过渡窗口后的低内存仍释放（不是 UI_HIDDEN）', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    var lowMemoryReleases = 0;
    manager.addLowMemoryReleaser(() => lowMemoryReleases++);

    manager.onAppBackground();
    await tester.pump(kMemoryPressureTransitionGuard);
    manager.onMemoryPressure();
    await tester.pump(kMemoryPressureDebounce);

    expect(lowMemoryReleases, 1);
    expect(cache.clearCount, 1);
    manager.onAppForeground();
  });

  testWidgets('移动端退后台不触达低内存 releaser', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    final manager = AppMemoryManager(presence: presence, imageCache: cache);
    addTearDown(manager.dispose);
    manager.attach();

    var lowMemoryReleases = 0;
    manager.addLowMemoryReleaser(() => lowMemoryReleases++);

    manager.onAppBackground();
    await tester.pump(kMobileBackgroundTrimDelay);

    expect(lowMemoryReleases, 0, reason: '普通退后台不清浏览列表，恢复不能空列表');
    expect(cache.clearCount, 1, reason: '图片缓存仍按 30s 策略回收');
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
    presence.markVisible();
  });

  testWidgets('托盘隐藏后延迟补一次 trim；恢复 / 快速往返取消', (tester) async {
    final presence = AppPresence();
    final cache = _FakeImageCache();
    var releases = 0;
    final manager = AppMemoryManager(
      presence: presence,
      imageCache: cache,
      releaseToOs: () => releases++,
    );
    addTearDown(manager.dispose);
    manager.attach();

    presence.markTrayHidden();
    await tester.pump();
    await tester.pump();
    expect(releases, 1, reason: '休眠帧后先 trim 一次');

    await tester.pump(kTrayLateTrimDelay);
    expect(releases, 2, reason: '窗口 hide 收尾 touch 的页再归还一次');

    // 恢复后计时作废，不再多跑。
    presence.markVisible();
    await tester.pump(kTrayLateTrimDelay);
    expect(releases, 2);

    // 隐藏后立刻恢复：第一次 trim 已发生，延迟 trim 必须被 token 取消。
    presence.markTrayHidden();
    await tester.pump();
    await tester.pump();
    expect(releases, 3);
    presence.markVisible();
    await tester.pump(kTrayLateTrimDelay);
    expect(releases, 3, reason: '快速往返不留下补跑的 trim');
  });
}
