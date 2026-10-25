import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/app_release.dart';
import 'package:molia/providers/update_provider.dart';
import 'package:molia/services/update/update_installer_types.dart';

import '../support/update_test_support.dart';

void main() {
  late FakeUpdateService service;
  late FakeUpdatePreferences preferences;
  late int quitCalls;
  late DateTime now;

  UpdateProvider buildProvider({
    String currentVersion = '1.2.2',
    int currentBuild = 41,
  }) {
    final provider = UpdateProvider(
      service: service,
      preferences: preferences,
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
    quitCalls = 0;
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

  test('check：有更新 → available，并记录检查时间', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    expect(provider.status, UpdateStatus.available);
    expect(provider.release?.version, '1.2.3');
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

  test('Android 交给系统安装器：不退出进程', () async {
    service.platform = const UpdatePlatformInfo(platform: 'android', arch: 'arm64');
    service.installOutcome = InstallOutcome.handedOff;
    final provider = buildProvider();
    await provider.init();
    await provider.check();

    await provider.downloadAndInstall();

    expect(provider.status, UpdateStatus.installing);
    expect(quitCalls, 0);
  });

  test('缺少安装权限：先不下载，提示去授权；授权后可直接下载安装', () async {
    service.platform =
        const UpdatePlatformInfo(platform: 'android', arch: 'arm64');
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
    service.platform =
        const UpdatePlatformInfo(platform: 'android', arch: 'arm64');
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

  test('iOS：不支持应用内安装', () async {
    service.platform = const UpdatePlatformInfo(platform: 'ios', arch: 'arm64');
    final provider = buildProvider();
    await provider.init();
    expect(provider.supportsInAppInstall, isFalse);
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

    // 重进设置页再检查一次：同一发布的包仍在，应回到「安装包已就绪」。
    await provider.check();
    expect(provider.status, UpdateStatus.downloaded);
    expect(provider.hasDownloadedPackage, isTrue);
  });

  test('检查到新发布：旧安装包状态作废（不显示上一个版本）', () async {
    final provider = buildProvider();
    await provider.init();
    await provider.check();
    await provider.downloadAndInstall();

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
    expect(provider.hasDownloadedPackage, isTrue);

    await provider.setChannel(UpdateChannel.beta);
    expect(provider.hasDownloadedPackage, isFalse);
    expect(provider.status, UpdateStatus.idle);
  });

  test('handleAppResumed：未下载时授权返回 → 回到「下载并安装」', () async {
    service.platform =
        const UpdatePlatformInfo(platform: 'android', arch: 'arm64');
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
