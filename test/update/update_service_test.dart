import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:molia/data/update/update_downloader.dart';
import 'package:molia/data/update/update_manifest_client.dart';
import 'package:molia/domain/models/app_release.dart';
import 'package:molia/services/update/update_installer.dart';
import 'package:molia/services/update/update_service.dart';

/// 更新编排：产物选择（安装形态优先 + 回退）与平台转发。
///
/// 三个协作者都用接口替身（`implements`），不触碰 HTTP / 文件系统 / 平台。
class _FakeClient implements UpdateManifestClient {
  final List<Uri> resolved = [];

  @override
  Future<AppRelease> fetch(UpdateChannel channel) async =>
      throw UnimplementedError('本测试不取清单');

  @override
  Uri resolveAssetUri(Uri url) {
    resolved.add(url);
    return url;
  }
}

class _FakeDownloader implements UpdateDownloader {
  Uri? lastUrl;
  String? lastFileName;
  String? lastSha256;

  @override
  Future<String> download({
    required Uri url,
    required String targetFileName,
    String? sha256,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    lastUrl = url;
    lastFileName = targetFileName;
    lastSha256 = sha256;
    onProgress(1, 1);
    return '/tmp/$targetFileName';
  }

  @override
  Future<void> clearStaleFiles() async {}
}

class _FakeInstaller implements UpdateInstaller {
  _FakeInstaller({this.preferredKind});

  final String? preferredKind;
  int permissionOpens = 0;
  int reloads = 0;

  @override
  Future<UpdatePlatformInfo> platformInfo() async =>
      const UpdatePlatformInfo(platform: 'windows', arch: 'x64');

  @override
  Future<bool> canInstallPackages() async => true;

  @override
  Future<void> openInstallPermissionSettings() async => permissionOpens++;

  @override
  Future<void> reloadPage() async => reloads++;

  @override
  Future<String?> preferredArchiveKind() async => preferredKind;

  @override
  Future<InstallOutcome> installAndRestart({
    required String archivePath,
    required String archiveKind,
  }) async =>
      InstallOutcome.restartPending;
}

void main() {
  ReleaseAsset asset(String kind, String file) => ReleaseAsset(
        platform: 'windows',
        arch: 'x64',
        kind: kind,
        url: Uri.parse('https://example.com/$file'),
        file: file,
        sha256: 'abc',
      );

  AppRelease windowsRelease() => AppRelease(
        channel: UpdateChannel.beta,
        version: '0.1.0-beta.2',
        build: 2,
        assets: [
          asset('zip', 'molia-0.1.0-beta.2-windows-x64.zip'),
          asset('exe', 'molia-0.1.0-beta.2-windows-x64-setup.exe'),
        ],
      );

  UpdateService buildService(
    _FakeClient client,
    _FakeDownloader downloader,
    _FakeInstaller installer,
  ) =>
      UpdateService(
        client: client,
        downloader: downloader,
        installer: installer,
      );

  test('安装版 Windows：优先下载 setup.exe（带 sha256 校验）', () async {
    final client = _FakeClient();
    final downloader = _FakeDownloader();
    final service = buildService(
      client,
      downloader,
      _FakeInstaller(preferredKind: 'exe'),
    );

    final path = await service.download(
      release: windowsRelease(),
      platform: const UpdatePlatformInfo(platform: 'windows', arch: 'x64'),
      onProgress: (_, __) {},
    );

    expect(downloader.lastFileName, 'molia-0.1.0-beta.2-windows-x64-setup.exe');
    expect(downloader.lastUrl?.path, contains('-setup.exe'));
    expect(downloader.lastSha256, 'abc');
    expect(path, endsWith('-setup.exe'));
  });

  test('便携版 Windows：优先下载 zip', () async {
    final downloader = _FakeDownloader();
    final service = buildService(
      _FakeClient(),
      downloader,
      _FakeInstaller(preferredKind: 'zip'),
    );

    await service.download(
      release: windowsRelease(),
      platform: const UpdatePlatformInfo(platform: 'windows', arch: 'x64'),
      onProgress: (_, __) {},
    );

    expect(downloader.lastFileName, 'molia-0.1.0-beta.2-windows-x64.zip');
  });

  test('偏好类别缺失时回退该平台任意产物（不失败）', () async {
    final downloader = _FakeDownloader();
    final service = buildService(
      _FakeClient(),
      downloader,
      _FakeInstaller(preferredKind: 'tar.gz'),
    );

    await service.download(
      release: windowsRelease(),
      platform: const UpdatePlatformInfo(platform: 'windows', arch: 'x64'),
      onProgress: (_, __) {},
    );

    expect(downloader.lastFileName, isNotNull);
  });

  test('没有适配产物：抛 unsupported', () async {
    final service = buildService(
      _FakeClient(),
      _FakeDownloader(),
      _FakeInstaller(preferredKind: 'exe'),
    );

    await expectLater(
      service.download(
        release: windowsRelease(),
        platform: const UpdatePlatformInfo(platform: 'linux', arch: 'x64'),
        onProgress: (_, __) {},
      ),
      throwsA(isA<UpdateFailureException>().having(
        (e) => e.kind,
        'kind',
        UpdateFailureKind.unsupported,
      )),
    );
  });

  test('平台转发：安装 / 权限 / 刷新都落到安装策略层', () async {
    final installer = _FakeInstaller();
    final service = buildService(_FakeClient(), _FakeDownloader(), installer);

    expect(await service.canInstallPackages(), isTrue);
    await service.openInstallPermissionSettings();
    await service.reloadPage();
    expect(
      await service.install(
        archivePath: '/tmp/molia-setup.exe',
        archiveKind: 'exe',
      ),
      InstallOutcome.restartPending,
    );
    expect(installer.permissionOpens, 1);
    expect(installer.reloads, 1);
  });
}
