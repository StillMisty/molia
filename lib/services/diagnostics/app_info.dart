/// 应用 / 运行环境信息（不读取设备名、账号、广告 ID 等唯一标识）。
library;

import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kDebugMode, kProfileMode;
import 'package:package_info_plus/package_info_plus.dart';

import 'diagnostics_bundle.dart';

/// 包信息 / 平台 / OS / ABI / 语言 / 构建模式 / 更新渠道。
class DiagnosticsAppInfoGatherer {
  DiagnosticsAppInfoGatherer({this._updateChannel, this._updateAutoCheck});

  final String Function()? _updateChannel;
  final bool Function()? _updateAutoCheck;
  Future<DiagnosticsAppInfo>? _cached;

  /// 读取一次并缓存；平台包信息不可用时回退 unknown，不抛异常。
  Future<DiagnosticsAppInfo> load() => _cached ??= _load();

  Future<DiagnosticsAppInfo> _load() async {
    var version = 'unknown';
    var buildNumber = 'unknown';
    var packageName = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version;
      buildNumber = info.buildNumber;
      packageName = info.packageName;
    } catch (_) {
      // 测试 / 受限宿主没有平台包信息：用 unknown 继续导出。
    }
    String abi;
    try {
      abi = Abi.current().toString();
    } catch (_) {
      abi = 'unknown';
    }
    return DiagnosticsAppInfo(
      version: version,
      buildNumber: buildNumber,
      packageName: packageName,
      platform: _platformName(defaultTargetPlatform),
      osVersion: Platform.operatingSystemVersion,
      abi: abi,
      locale: Platform.localeName,
      buildMode: kDebugMode ? 'debug' : (kProfileMode ? 'profile' : 'release'),
      updateChannel: _updateChannel?.call() ?? 'unknown',
      updateAutoCheck: _updateAutoCheck?.call() ?? false,
    );
  }

  static String _platformName(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.linux => 'linux',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}
