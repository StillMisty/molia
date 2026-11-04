import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/downloads/download_notifications.dart';
import 'package:molia/domain/models/app_release.dart';
import 'package:molia/providers/update_provider.dart';
import 'package:molia/services/update/update_installer_types.dart';
import 'package:molia/services/update/update_notification_presenter.dart';
import 'package:molia/services/update/update_preferences.dart';

import '../support/fake_download_notifications.dart';
import '../support/update_test_support.dart';

void main() {
  late FakeUpdateService service;
  late FakeUpdatePreferences preferences;
  late FakeDownloadNotifications notifications;
  late int quitCalls;
  late int permissionRequests;
  late bool permissionRequestFails;
  late DateTime now;

  UpdateProvider buildProvider({
    String currentVersion = '1.2.2',
    int currentBuild = 41,
  }) {
    final provider = UpdateProvider(
      service: service,
      preferences: preferences,
      notificationPresenter: UpdateNotificationPresenter(
        notifications: notifications,
        clock: () => now.millisecondsSinceEpoch,
      ),
      ensureNotificationPermission: () async {
        permissionRequests++;
        if (permissionRequestFails) throw StateError('permission denied');
      },
      currentVersion: currentVersion,
      currentBuild: currentBuild,
      quitApp: () async => quitCalls++,
      now: () => now,
    );
    addTearDown(provider.dispose);
    return provider;
  }

  setUp(() {
    service = FakeUpdateService();
    preferences = FakeUpdatePreferences();
    notifications = FakeDownloadNotifications();
    quitCalls = 0;
    permissionRequests = 0;
    permissionRequestFails = false;
    now = DateTime(2026, 10, 14, 12);
  });

  test('init 装载偏好与平台信息', () async {
    preferences.autoCheckEnabled = true;
    preferences.channel = UpdateChannel.beta;
    final provider = buildProvider();
    await provider.init();

    expect(provider.autoCheckEnabled, isTrue);
    expect(provider.channel, UpdateChannel.beta);
    expect(provider.platform?.platform, 'linux');
    expect(provider.supportsInAppInstall, isTrue);
    expect(provider.currentVersionLabel, '1.2.2+41');
  });

  test('pending 回执：当前版本已达到 → succeeded 并清除', () async {
    preferences.pendingUpdate = const PendingUpdate(
      version: '1.2.1',
      build: 40,
    );
    final provider = buildProvider();
    await provider.init();

    expect(provider.installResult, UpdateInstallResult.succeeded);
    expect(provider.installResultVersion, '1.2.1');
    expect(preferences.pendingUpdate, isNull);
    expect(preferences.clearPendingCalls, 1);
  });

  test('pending 回执：仍低于目标 → incomplete 并清除', () async {
    preferences.pendingUpdate = const PendingUpdate(
      version: '1.2.4',
      build: 43,
    );
    final provider = buildProvider();
    await provider.init();

    expect(provider.installResult, UpdateInstallResult.incomplete);
    expect(provider.installResultVersion, '1.2.4');
    expect(preferences.pendingUpdate, isNull);
    expect(preferences.clearPendingCalls, 1);
  });

  test('手动 check 清除旧回执；静默启动检查保留', () async {
    preferences.pendingUpdate = const PendingUpdate(
      version: '1.2.4',
      build: 43,
    );
    final provider = buildProvider();
    await provider.init();
    expect(provider.installResult, UpdateInstallResult.incomplete);

    await provider.check(silent: true);
    expect(
      provider.installResult,
      UpdateInstallResult.incomplete,
      reason: '静默检查不能把启动回执吞掉',
    );

    await provider.check();
    expect(provider.installResult, isNull);
    expect(provider.installResultVersion, isNull);
  });

  test('check：有更新 → available，并记录检查时间', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    expect(provider.status, UpdateStatus.available);
    expect(provider.release?.version, '1.2.3');
    expect(provider.releaseAsset?.kind, 'tar.gz');
    expect(provider.releaseAsset?.size, 12 * 1024 * 1024);
    expect(provider.updateAvailable, isTrue);
    expect(provider.lastCheckedAt, now);
  });

  test('check：版本不新 → upToDate', () async {
    service.manifest = service.release('1.2.2', 41);
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    expect(provider.status, UpdateStatus.upToDate);
    expect(provider.updateAvailable, isFalse);
  });

  test('check 失败：显式检查进错误态，静默检查不动状态', () async {
    service.checkError = const UpdateFailureException(
      UpdateFailureKind.manifestInvalid,
      'bad manifest',
    );
    final provider = buildProvider();
    await provider.init();

    await provider.check();
    expect(provider.status, UpdateStatus.error);
    expect(provider.failure, UpdateFailureKind.manifestInvalid);

    await provider.check(silent: true);
    expect(provider.status, UpdateStatus.idle);
    expect(provider.failure, isNull);
  });

  test('maybeAutoCheck：默认关；开启后按 24h 节流', () async {
    final provider = buildProvider();
    await provider.init();

    expect(await provider.maybeAutoCheck(), isFalse);

    await provider.setAutoCheckEnabled(true);
    expect(await provider.maybeAutoCheck(), isTrue);
    expect(provider.status, UpdateStatus.available);
    expect(provider.lastCheckedAt, now);

    // 刚刚检查过：24h 内不再自动检查。
    final again = buildProvider();
    await again.init();
    expect(await again.maybeAutoCheck(), isFalse);

    // 超过 24h 再检查。
    now = now.add(const Duration(hours: 25));
    expect(await again.maybeAutoCheck(), isTrue);
  });

  test('启动自动检查失败不写时间：紧接着再次调用会重试并记录成功时间', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.setAutoCheckEnabled(true);
    service.checkError = const UpdateFailureException(
      UpdateFailureKind.network,
      'offline',
    );

    expect(await provider.maybeAutoCheck(), isTrue);
    expect(provider.status, UpdateStatus.idle, reason: '静默检查失败不进错误态');
    expect(provider.lastCheckedAt, isNull, reason: '失败不算检查成功');

    // 上次成功时间仍为空：同一 Provider 再调用会重新尝试，不被 24h 节流拦住。
    service.checkError = null;
    expect(await provider.maybeAutoCheck(), isTrue);
    expect(provider.status, UpdateStatus.available);
    expect(provider.lastCheckedAt, now);
  });

  test('检查挂起时切换渠道：旧结果丢弃，保持 idle', () async {
    final provider = buildProvider();
    await provider.init();
    service.checkGate = Completer<void>();
    final pending = provider.check();
    await Future<void>.delayed(Duration.zero);
    expect(provider.status, UpdateStatus.checking);

    await provider.setChannel(UpdateChannel.beta);
    expect(provider.status, UpdateStatus.idle);
    expect(provider.release, isNull);

    service.checkGate!.complete();
    await pending;

    // 旧渠道的结果即使回来也不能回填：渠道已经切换，状态应保持 idle。
    expect(provider.status, UpdateStatus.idle);
    expect(provider.release, isNull);
    expect(provider.releaseAsset, isNull);
    expect(provider.lastCheckedAt, isNull, reason: '被丢弃的检查不记成功时间');
  });

  test('写检查时间期间切换渠道：旧检查结果不再回填', () async {
    final provider = buildProvider();
    await provider.init();
    preferences.markCheckedStarted = Completer<void>();
    preferences.markCheckedGate = Completer<void>();
    final pending = provider.check();
    await preferences.markCheckedStarted!.future;
    expect(provider.release?.version, '1.2.3');

    await provider.setChannel(UpdateChannel.beta);
    expect(provider.status, UpdateStatus.idle);
    expect(provider.release, isNull);

    preferences.markCheckedGate!.complete();
    await pending;

    expect(provider.status, UpdateStatus.idle);
    expect(provider.release, isNull);
  });

  test('检查挂起时改清单地址：旧结果丢弃，保持 idle', () async {
    final provider = buildProvider();
    await provider.init();
    service.checkGate = Completer<void>();
    final pending = provider.check();
    await Future<void>.delayed(Duration.zero);
    expect(provider.status, UpdateStatus.checking);

    await provider.setManifestUrlOverride(
      'https://mirror.example.com/latest.json',
    );
    expect(provider.status, UpdateStatus.idle);

    service.checkGate!.complete();
    await pending;

    expect(provider.status, UpdateStatus.idle);
    expect(provider.release, isNull);
    expect(provider.lastCheckedAt, isNull);
  });

  test('安装中调用 check：不改变 installing 状态与当前发布', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();
    expect(provider.status, UpdateStatus.installing);
    final release = provider.release;

    service.manifest = service.release('1.2.4', 43);
    await provider.check();

    expect(provider.status, UpdateStatus.installing);
    expect(provider.release, same(release));
  });

  test('续传首个回调作为速度基准：不把已有 part 字节算成本次速度', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    service.onProgressHook = (received, total) {
      // 模拟续传：首个回调直接是已有 5 字节，1 秒后收到最后 5 字节。
      if (received == 10) now = now.add(const Duration(seconds: 1));
    };

    await provider.downloadAndInstall();

    expect(provider.progress.value.received, 10);
    expect(provider.progress.value.total, 10);
    // 速度基准是首个 5 字节回调，不会把 10 字节都算到 1 秒内（10 B/s）。
    expect(provider.progress.value.bytesPerSecond, 5);
  });

  test('配置变更：作废旧发布、产物与已下载包', () async {
    service.installOutcome = InstallOutcome.notWritable;
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    expect(provider.status, UpdateStatus.available);
    expect(provider.releaseAsset, isNotNull);

    await provider.setManifestUrlOverride(
      'https://mirror.example.com/latest.json',
    );
    expect(provider.status, UpdateStatus.idle);
    expect(provider.release, isNull);
    expect(provider.releaseAsset, isNull);
    expect(provider.hasDownloadedPackage, isFalse);

    // 重新检查并下载到「安装包已就绪」后再改镜像前缀：已下载状态同样作废。
    await provider.check();
    expect(provider.status, UpdateStatus.available);
    await provider.downloadAndInstall();
    expect(provider.status, UpdateStatus.downloaded);
    expect(provider.hasDownloadedPackage, isTrue);

    await provider.setDownloadPrefix('https://gh-proxy.com/');
    expect(provider.status, UpdateStatus.idle);
    expect(provider.release, isNull);
    expect(provider.releaseAsset, isNull);
    expect(provider.hasDownloadedPackage, isFalse);
  });

  test('配置变更：下载中不清当前发布 / 状态，等流程结束', () async {
    service.downloadGate = Completer<void>();
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    final release = provider.release;
    final asset = provider.releaseAsset;

    final download = provider.downloadAndInstall();
    await Future<void>.delayed(Duration.zero);
    expect(provider.status, UpdateStatus.downloading);

    await provider.setManifestUrlOverride(
      'https://mirror.example.com/latest.json',
    );
    await provider.setChannel(UpdateChannel.beta);

    expect(provider.status, UpdateStatus.downloading);
    expect(provider.channel, UpdateChannel.beta);
    expect(provider.release, same(release));
    expect(provider.releaseAsset, same(asset));

    service.downloadGate!.complete();
    await download;
    expect(provider.release, isNotNull);
  });

  test('下载安装：进度通道 / 状态推进 / 桌面重启前退出进程', () async {
    service.installOutcome = InstallOutcome.restartPending;
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(provider.status, UpdateStatus.installing);
    expect(provider.progress.value.received, 10);
    expect(provider.progress.value.total, 10);
    expect(provider.progress.value.fraction, 1.0);
    expect(provider.hasDownloadedPackage, isTrue);
    expect(quitCalls, 1);
  });

  test('交给安装器前 mark pending；restartPending 保留回执', () async {
    service.installOutcome = InstallOutcome.restartPending;
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(preferences.markPendingCalls, 1);
    expect(preferences.pendingUpdate?.version, '1.2.3');
    expect(preferences.pendingUpdate?.build, 42);
    expect(preferences.clearPendingCalls, 0);
    expect(provider.status, UpdateStatus.installing);
  });

  test('notWritable：没有真正交接，清除 pending', () async {
    service.installOutcome = InstallOutcome.notWritable;
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(preferences.markPendingCalls, 1);
    expect(preferences.clearPendingCalls, 1);
    expect(preferences.pendingUpdate, isNull);
    expect(provider.failure, UpdateFailureKind.notWritable);
  });

  test('安装异常：清除 pending，避免下次启动误报未完成', () async {
    service.installError = StateError('boom');
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(preferences.markPendingCalls, 1);
    expect(preferences.clearPendingCalls, 1);
    expect(preferences.pendingUpdate, isNull);
    expect(provider.failure, UpdateFailureKind.installFailed);
  });

  test('handleAppResumed 取消安装：清除 pending 并回到 downloaded', () async {
    service.installOutcome = InstallOutcome.handedOff;
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();
    expect(provider.status, UpdateStatus.installing);
    expect(preferences.pendingUpdate, isNotNull);

    await provider.handleAppResumed();

    expect(provider.status, UpdateStatus.downloaded);
    expect(preferences.pendingUpdate, isNull);
    expect(preferences.clearPendingCalls, greaterThanOrEqualTo(1));
  });

  test('下载开始发更新通知：进度更新，成功后收尾', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(notifications.methods, ['start', 'update', 'update', 'stop']);
    final start = notifications.events.first;
    expect(start.id, UpdateNotificationPresenter.notificationId);
    expect(start.title, 'Molia');
    expect(start.subtitle, '1.2.3');
    expect(start.progress, 0);
    expect(start.channel, DownloadNotificationChannel.update);
    expect(notifications.events[1].progress, 5);
    expect(notifications.events[2].progress, 10);
    expect(
      notifications.events.last.id,
      UpdateNotificationPresenter.notificationId,
    );
  });

  test('dispose：收尾已起的更新通知', () {
    final presenter = UpdateNotificationPresenter(
      notifications: notifications,
      clock: () => now.millisecondsSinceEpoch,
    );
    final provider = UpdateProvider(
      service: service,
      preferences: preferences,
      notificationPresenter: presenter,
      now: () => now,
    );
    // 模拟下载已开始、通知已起时页面销毁：Provider 负责收尾，不能让通知
    // 残留；不通过暴露私有状态来断言，只看端口事件。
    presenter.start(version: '1.2.3');
    expect(notifications.methods, ['start']);

    provider.dispose();

    expect(notifications.methods, ['start', 'stop']);
    expect(
      notifications.events.last.id,
      UpdateNotificationPresenter.notificationId,
    );
  });

  test('下载失败：更新通知同样收尾（不残留「正在下载」）', () async {
    service.downloadError = const UpdateFailureException(
      UpdateFailureKind.network,
      'boom',
    );
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(provider.status, UpdateStatus.error);
    expect(notifications.methods, ['start', 'stop']);
  });

  test('取消下载：更新通知收尾', () async {
    service.downloadError = DioException(
      requestOptions: RequestOptions(path: 'https://example.com'),
      type: DioExceptionType.cancel,
    );
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(provider.status, UpdateStatus.available);
    expect(notifications.methods, ['start', 'stop']);
  });

  test('Windows 便携版：安装使用下载结果里的 zip 类别，不按清单顺序猜', () async {
    final zip = ReleaseAsset(
      platform: 'windows',
      arch: 'x64',
      kind: 'zip',
      url: Uri.parse('https://example.com/molia.zip'),
      file: 'molia-1.2.3-windows-x64.zip',
      sha256: 'abc',
    );
    final setup = ReleaseAsset(
      platform: 'windows',
      arch: 'x64',
      kind: 'exe',
      url: Uri.parse('https://example.com/molia-setup.exe'),
      file: 'molia-1.2.3-windows-x64-setup.exe',
      sha256: 'abc',
    );
    service
      ..platform = const UpdatePlatformInfo(platform: 'windows', arch: 'x64')
      ..manifest = AppRelease(
        channel: UpdateChannel.stable,
        version: '1.2.3',
        build: 42,
        // 真实清单按文件名排序：setup.exe 排在 zip 前。
        assets: [setup, zip],
      )
      ..downloadAsset = zip;
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(service.lastInstallKind, 'zip');
    expect(provider.hasDownloadedPackage, isTrue);
  });

  test('Windows 安装版：preferred exe 行为不变', () async {
    final setup = ReleaseAsset(
      platform: 'windows',
      arch: 'x64',
      kind: 'exe',
      url: Uri.parse('https://example.com/molia-setup.exe'),
      file: 'molia-1.2.3-windows-x64-setup.exe',
      sha256: 'abc',
    );
    service
      ..platform = const UpdatePlatformInfo(platform: 'windows', arch: 'x64')
      ..manifest = AppRelease(
        channel: UpdateChannel.stable,
        version: '1.2.3',
        build: 42,
        assets: [setup],
      )
      ..downloadAsset = setup;
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(service.lastInstallKind, 'exe');
  });

  test('Android 下载前请求通知权限一次；拒绝/异常不阻断下载', () async {
    service.platform = const UpdatePlatformInfo(
      platform: 'android',
      arch: 'arm64',
    );
    permissionRequestFails = true;
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(permissionRequests, 1);
    expect(service.downloadCalls, 1);
    expect(provider.status, UpdateStatus.installing);
    expect(notifications.methods.first, 'start');
  });

  test('非 Android：不请求通知权限', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(permissionRequests, 0);
  });

  test('Android 交给系统安装器：不退出进程', () async {
    service.platform = const UpdatePlatformInfo(
      platform: 'android',
      arch: 'arm64',
    );
    service.installOutcome = InstallOutcome.handedOff;
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(provider.status, UpdateStatus.installing);
    expect(quitCalls, 0);
  });

  test('缺少安装权限：先不下载，提示去授权；授权后可直接下载安装', () async {
    service.platform = const UpdatePlatformInfo(
      platform: 'android',
      arch: 'arm64',
    );
    service.installPermission = false;
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();
    expect(provider.status, UpdateStatus.available);
    expect(provider.failure, UpdateFailureKind.permission);
    expect(provider.hasDownloadedPackage, isFalse);
    expect(service.downloadCalls, 0, reason: '无权限时不应先下载十几 MB');
    expect(service.installCalls, 0);

    await provider.openInstallPermissionSettings();
    expect(service.openPermissionCalls, 1);

    // 用户授权后回到前台：待授权态清除，回到「下载并安装」。
    service.installPermission = true;
    await provider.handleAppResumed();
    expect(provider.failure, isNull);
    expect(provider.status, UpdateStatus.available);

    await provider.downloadAndInstall();
    expect(service.downloadCalls, 1);
    expect(provider.status, UpdateStatus.installing);
  });

  test('系统安装器被取消 / 权限被撤销：回到可重试态', () async {
    service.platform = const UpdatePlatformInfo(
      platform: 'android',
      arch: 'arm64',
    );
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();
    expect(provider.status, UpdateStatus.installing);

    // 用户取消系统安装器后回到前台：回到「安装包已就绪」可重试。
    await provider.handleAppResumed();
    expect(provider.status, UpdateStatus.downloaded);
    expect(provider.hasDownloadedPackage, isTrue);

    // 权限被用户在系统里撤销：停在待授权。
    service.installPermission = false;
    await provider.installDownloaded();
    expect(provider.failure, UpdateFailureKind.permission);
    expect(provider.status, UpdateStatus.downloaded);

    // 重新授权返回 → 切回「立即安装」。
    service.installPermission = true;
    await provider.handleAppResumed();
    expect(provider.failure, isNull);
    await provider.installDownloaded();
    expect(provider.status, UpdateStatus.installing);
  });

  test('安装目录不可写：保留安装包并提示手动更新', () async {
    service.installOutcome = InstallOutcome.notWritable;
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();

    expect(provider.status, UpdateStatus.downloaded);
    expect(provider.failure, UpdateFailureKind.notWritable);
    expect(provider.hasDownloadedPackage, isTrue);
  });

  test('校验失败 / 网络失败：错误态并带上类别', () async {
    service.downloadError = const UpdateFailureException(
      UpdateFailureKind.checksumMismatch,
      'sha mismatch',
    );
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();

    expect(provider.status, UpdateStatus.error);
    expect(provider.failure, UpdateFailureKind.checksumMismatch);
  });

  test('取消下载：回到 available，不进入错误态', () async {
    service.downloadError = DioException(
      requestOptions: RequestOptions(path: 'https://example.com'),
      type: DioExceptionType.cancel,
    );
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();

    expect(provider.status, UpdateStatus.available);
    expect(provider.failure, isNull);
  });

  test('iOS / macOS：不支持应用内安装', () async {
    service.platform = const UpdatePlatformInfo(platform: 'ios', arch: 'arm64');
    final ios = buildProvider();
    await ios.init();
    expect(ios.supportsInAppInstall, isFalse);

    service.platform = const UpdatePlatformInfo(
      platform: 'macos',
      arch: 'arm64',
    );
    final macos = buildProvider();
    await macos.init();
    // macOS 能下载，但安装策略没有对应分支：按不支持处理，不显示安装按钮。
    expect(macos.supportsInAppInstall, isFalse);
  });

  test('切换渠道：旧结果作废回到 idle', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    expect(provider.status, UpdateStatus.available);

    await provider.setChannel(UpdateChannel.beta);
    expect(provider.channel, UpdateChannel.beta);
    expect(provider.status, UpdateStatus.idle);
    expect(provider.release, isNull);
  });

  test('检查到与已下载包同一发布：保持 downloaded 态，不回到「下载并安装」', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();
    expect(provider.status, UpdateStatus.installing);

    // 从系统安装器回到应用后才会离开 installing（安装中 check 现在被 guard
    // 拦住），再重进设置页检查：同一发布的包仍在，应回到「安装包已就绪」。
    await provider.handleAppResumed();
    expect(provider.status, UpdateStatus.downloaded);
    await provider.check();
    expect(provider.status, UpdateStatus.downloaded);
    expect(provider.hasDownloadedPackage, isTrue);
  });

  test('检查到新发布：旧安装包状态作废（不显示上一个版本）', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();
    await provider.handleAppResumed();

    service.manifest = service.release('1.2.4', 43);
    await provider.check();
    expect(provider.status, UpdateStatus.available);
    expect(provider.release?.version, '1.2.4');
    expect(provider.hasDownloadedPackage, isFalse);
  });

  test('切换渠道作废已下载包（避免跨渠道安装旧包）', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();
    await provider.handleAppResumed();
    expect(provider.hasDownloadedPackage, isTrue);

    await provider.setChannel(UpdateChannel.beta);
    expect(provider.hasDownloadedPackage, isFalse);
    expect(provider.status, UpdateStatus.idle);
  });

  test('handleAppResumed：未下载时授权返回 → 回到「下载并安装」', () async {
    service.platform = const UpdatePlatformInfo(
      platform: 'android',
      arch: 'arm64',
    );
    service.installPermission = false;
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();
    expect(provider.failure, UpdateFailureKind.permission);
    expect(provider.status, UpdateStatus.available);

    // 仍未授权：不动状态。
    await provider.handleAppResumed();
    expect(provider.failure, UpdateFailureKind.permission);

    service.installPermission = true;
    await provider.handleAppResumed();
    expect(provider.failure, isNull);
    expect(provider.status, UpdateStatus.available);
  });
}
