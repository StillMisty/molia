import 'package:flutter_test/flutter_test.dart';
import 'package:molia/domain/models/app_release.dart';

/// 更新领域模型：semver 比较、新旧判定、产物挑选。
void main() {
  AppRelease release({
    String version = '1.2.3',
    int build = 10,
    UpdateChannel channel = UpdateChannel.stable,
    List<ReleaseAsset> assets = const [],
  }) =>
      AppRelease(
        channel: channel,
        version: version,
        build: build,
        assets: assets,
      );

  ReleaseAsset asset(String platform, String arch, {String kind = 'zip'}) =>
      ReleaseAsset(
        platform: platform,
        arch: arch,
        kind: kind,
        url: Uri.parse('https://example.com/$platform-$arch.$kind'),
      );

  group('compareAppVersions', () {
    test('核心段逐位比较（含 v 前缀与构建元数据归一）', () {
      expect(compareAppVersions('1.2.3', '1.2.4'), lessThan(0));
      expect(compareAppVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareAppVersions('1.0.0', '1.0.0'), 0);
      expect(compareAppVersions('v1.0.0', '1.0.0'), 0);
      // 构建元数据不参与比较：构建号由 AppRelease.build 单独承载。
      expect(compareAppVersions('1.0.0+12', '1.0.0+3'), 0);
    });

    test('预发布按 semver 规则：数字段按数值、字母段字典序、短前缀更小', () {
      expect(compareAppVersions('1.0.0-beta.2', '1.0.0'), lessThan(0));
      expect(compareAppVersions('1.0.0', '1.0.0-beta.2'), greaterThan(0));
      expect(
        compareAppVersions('1.0.0-beta.2', '1.0.0-beta.10'),
        lessThan(0),
      );
      expect(compareAppVersions('1.0.0-beta', '1.0.0-beta.1'), lessThan(0));
      expect(compareAppVersions('1.0.0-alpha', '1.0.0-beta'), lessThan(0));
    });

    test('容错：缺段按 0 处理', () {
      expect(compareAppVersions('1', '1.0.0'), 0);
      expect(compareAppVersions('', '0.0.0'), 0);
      expect(compareAppVersions('2.0', '1.9.9'), greaterThan(0));
    });
  });

  group('AppRelease.isNewerThan', () {
    test('版本号更高即更新', () {
      expect(
        release(version: '1.2.4', build: 1)
            .isNewerThan(currentVersion: '1.2.3', currentBuild: 99),
        isTrue,
      );
    });

    test('版本相同比构建号（测试渠道重发同版本）', () {
      expect(
        release(version: '1.2.3', build: 11)
            .isNewerThan(currentVersion: '1.2.3', currentBuild: 10),
        isTrue,
      );
      expect(
        release(version: '1.2.3', build: 10)
            .isNewerThan(currentVersion: '1.2.3', currentBuild: 10),
        isFalse,
      );
    });

    test('beta 清单相对稳定版安装仍按 semver 判定', () {
      expect(
        release(version: '1.2.3-beta.1', build: 1)
            .isNewerThan(currentVersion: '1.2.2', currentBuild: 99),
        isTrue,
      );
      expect(
        release(version: '1.2.2', build: 100)
            .isNewerThan(currentVersion: '1.2.3-beta.1', currentBuild: 1),
        isFalse,
      );
    });
  });

  group('assetFor', () {
    final assets = [
      asset('android', 'arm64', kind: 'apk'),
      asset('android', 'x86_64', kind: 'apk'),
      asset('windows', 'x64'),
      asset('linux', 'x64', kind: 'tar.gz'),
    ];

    test('精确匹配优先', () {
      expect(release(assets: assets).assetFor(
        platform: 'android',
        arch: 'x86_64',
      ), assets[1]);
    });

    test('没有精确架构时回退同平台任意架构', () {
      expect(release(assets: assets).assetFor(
        platform: 'android',
        arch: 'armv7',
      ), assets[0]);
    });

    test('没有该平台产物时为 null', () {
      expect(release(assets: assets).assetFor(
        platform: 'ios',
        arch: 'arm64',
      ), isNull);
    });
  });
}
