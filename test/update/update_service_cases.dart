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
  int? lastExpectedSize;

  @override
  Future<String> download({
    required Uri url,
    required String targetFileName,
    String? sha256,
    int? expectedSize,
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    lastUrl = url;
    lastFileName = targetFileName;
    lastSha256 = sha256;
    lastExpectedSize = expectedSize;
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

  @override
  Future<UpdatePlatformInfo> platformInfo() async =>
      const UpdatePlatformInfo(platform: 'windows', arch: 'x64');

  @override
  Future<bool> canInstallPackages() async => true;

  @override
  Future<void> openInstallPermissionSettings() async => permissionOpens++;

  @override
  Future<String?> preferredArchiveKind() async => preferredKind;

  @override
  Future<InstallOutcome> installAndRestart({
    required String archivePath,
    required String archiveKind,
  }) async => InstallOutcome.restartPending;
}

void main() {
  ReleaseAsset asset(String kind, String file, {required int size}) =>
      ReleaseAsset(
        platform: 'windows',
        arch: 'x64',
        kind: kind,
        url: Uri.parse('https://example.com/$file'),
        file: file,
        size: size,
        sha256: 'abc',
      );

  AppRelease windowsRelease({bool setupFirst = false}) {
    final zip = asset(
      'zip',
      'molia-0.1.0-beta.2-windows-x64.zip',
      size: 12 * 1024 * 1024,
    );
    final setup = asset(
      'exe',
      'molia-0.1.0-beta.2-windows-x64-setup.exe',
      size: 8 * 1024 * 1024,
    );
    return AppRelease(
      channel: UpdateChannel.beta,
      version: '0.1.0-beta.2',
      build: 2,
      // 真实清单按文件名排序：`-setup.exe` 会排在 `.zip` 前。
      assets: setupFirst ? [setup, zip] : [zip, setup],
    );
  }

  UpdateService buildService(
    _FakeClient client,
    _FakeDownloader downloader,
    _FakeInstaller installer,
  ) => UpdateService(
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

    final result = await service.download(
      release: windowsRelease(),
      platform: const UpdatePlatformInfo(platform: 'windows', arch: 'x64'),
      onProgress: (_, _) {},
    );

    expect(downloader.lastFileName, 'molia-0.1.0-beta.2-windows-x64-setup.exe');
    expect(downloader.lastUrl?.path, contains('-setup.exe'));
    expect(downloader.lastSha256, 'abc');
    expect(downloader.lastExpectedSize, 8 * 1024 * 1024);
    expect(result.path, endsWith('-setup.exe'));
    expect(result.asset.kind, 'exe');
  });

  test('便携版 Windows：优先下载 zip', () async {
    final downloader = _FakeDownloader();
    final service = buildService(
      _FakeClient(),
      downloader,
      _FakeInstaller(preferredKind: 'zip'),
    );

    final result = await service.download(
      release: windowsRelease(),
      platform: const UpdatePlatformInfo(platform: 'windows', arch: 'x64'),
      onProgress: (_, _) {},
    );

    expect(downloader.lastFileName, 'molia-0.1.0-beta.2-windows-x64.zip');
    expect(downloader.lastExpectedSize, 12 * 1024 * 1024);
    expect(result.path, endsWith('.zip'));
    expect(result.asset.kind, 'zip');
  });

  test('selectAsset：与下载同一套类别选择（setupFirst + preferred zip → zip）', () async {
    final service = buildService(
      _FakeClient(),
      _FakeDownloader(),
      _FakeInstaller(preferredKind: 'zip'),
    );

    final selected = await service.selectAsset(
      release: windowsRelease(setupFirst: true),
      platform: const UpdatePlatformInfo(platform: 'windows', arch: 'x64'),
    );

    expect(selected?.kind, 'zip');
    expect(selected?.size, 12 * 1024 * 1024);
  });

  test('便携版 Windows：setup.exe 排在 zip 前也返回 zip 产物的真实类别', () async {
    final downloader = _FakeDownloader();
    final service = buildService(
      _FakeClient(),
      downloader,
      _FakeInstaller(preferredKind: 'zip'),
    );

    final result = await service.download(
      release: windowsRelease(setupFirst: true),
      platform: const UpdatePlatformInfo(platform: 'windows', arch: 'x64'),
      onProgress: (_, _) {},
    );

    // 选择逻辑只保留服务内这一份：返回值必须与下载的文件一致，
    // 调用方不能按清单顺序（assetFor）再猜一次。
    expect(downloader.lastFileName, 'molia-0.1.0-beta.2-windows-x64.zip');
    expect(result.asset.file, downloader.lastFileName);
    expect(result.asset.kind, 'zip');
  });

  test('偏好类别缺失时回退该平台任意产物（不失败）', () async {
    final downloader = _FakeDownloader();
    final service = buildService(
      _FakeClient(),
      downloader,
      _FakeInstaller(preferredKind: 'tar.gz'),
    );

    final result = await service.download(
      release: windowsRelease(),
      platform: const UpdatePlatformInfo(platform: 'windows', arch: 'x64'),
      onProgress: (_, _) {},
    );

    expect(downloader.lastFileName, isNotNull);
    // 偏好类别（tar.gz）不存在：回退第一个适配产物（zip），返回值同类。
    expect(result.asset.kind, 'zip');
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
        onProgress: (_, _) {},
      ),
      throwsA(
        isA<UpdateFailureException>().having(
          (e) => e.kind,
          'kind',
          UpdateFailureKind.unsupported,
        ),
      ),
    );
  });

  test('平台转发：安装 / 权限都落到安装策略层', () async {
    final installer = _FakeInstaller();
    final service = buildService(_FakeClient(), _FakeDownloader(), installer);

    expect(await service.canInstallPackages(), isTrue);
    await service.openInstallPermissionSettings();
    expect(
      await service.install(
        archivePath: '/tmp/molia-setup.exe',
        archiveKind: 'exe',
      ),
      InstallOutcome.restartPending,
    );
    expect(installer.permissionOpens, 1);
  });
}
