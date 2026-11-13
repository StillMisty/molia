/// 设置快照：显式允许列表 + 凭证只报“已配置 / 未配置”。
///
/// 新增设置默认不会进入这里；只有明确列出的键才会被读取。凭证值（AI Key、
/// B 站 Cookie、any-listen token、同步口令）从不写入快照对象，只比较是否
/// 为空。同步口令本身也不经过设置注册表读取，由调用方传入“是否已配置”。
library;

import '../../data/settings/settings_key.dart';
import '../../data/settings/settings_keys.dart';
import '../../data/settings/settings_registry.dart';
import '../../services/diagnostics/diagnostics_bundle.dart';

/// 同步状态中允许进入快照的部分（不含口令 / 密码值）。
class DiagnosticsSyncInfo {
  const DiagnosticsSyncInfo({
    this.enabled = false,
    this.categories = const {},
    this.transports = const [],
    this.pairedDevices = 0,
    this.webdavConfigured = false,
    this.webdavHost,
  });

  final bool enabled;
  final Map<String, bool> categories;
  final List<String> transports;
  final int pairedDevices;
  final bool webdavConfigured;
  final String? webdavHost;
}

/// 读取允许导出的设置；[extraValues] 是设备本地 / 非注册表项（省流、更新
/// 频道等）的显式补充，同样由调用方逐项挑选。
Future<DiagnosticsSettingsSnapshot> gatherDiagnosticsSettings({
  required SettingsRegistry registry,
  DiagnosticsSyncInfo sync = const DiagnosticsSyncInfo(),
  Map<String, Object?> extraValues = const {},
}) async {
  final values = <String, Object?>{};
  final notes = <String>[];
  Future<Object?> read(SettingsKey<Object?> key) async {
    try {
      return await registry.read<Object?>(key);
    } catch (_) {
      notes.add('One or more settings could not be read.');
      return null;
    }
  }

  values[kThemeMode.name] = await read(kThemeMode);
  values[kColorBase.name] = await read(kColorBase);
  values[kPureBlackEnabled.name] = await read(kPureBlackEnabled);
  values[kFollowArtworkEnabled.name] = await read(kFollowArtworkEnabled);
  values[kSelectedLanguage.name] = await read(kSelectedLanguage);
  values[kShellHomeDestination.name] = await read(kShellHomeDestination);
  values[kDefaultPlayMode.name] = await read(kDefaultPlayMode);
  values[kRestoreSessionEnabled.name] = await read(kRestoreSessionEnabled);
  values[kPlayStatisticsEnabled.name] = await read(kPlayStatisticsEnabled);
  values[kLxDefaultQuality.name] = await read(kLxDefaultQuality);
  values[kSourceSwapAutoEnabled.name] = await read(kSourceSwapAutoEnabled);
  values[kLibraryAddPosition.name] = await read(kLibraryAddPosition);
  values[kAiDjEnabled.name] = await read(kAiDjEnabled);
  values[kAiDjModel.name] = await read(kAiDjModel);
  values.addAll(extraValues);

  final credentials = <String, bool>{
    'ai_api_key': await _configured(registry, kAiDjApiKey),
    'bilibili_sign_in': await _configured(registry, kBiliAccountCookie),
    'any_listen_access': await _configured(registry, kAnyListenToken),
  };
  // any-listen 服务器只报已配置 + 主机名；token 走上面的布尔值。
  final anyListenUrl = await read(kAnyListenServerUrl);
  final anyListenHost = _hostOf(anyListenUrl is String ? anyListenUrl : null);
  values['any_listen_server'] = anyListenHost == null
      ? 'not configured'
      : 'configured ($anyListenHost)';

  values['sync_enabled'] = sync.enabled;
  values['sync_transports'] = sync.transports;
  for (final entry in sync.categories.entries) {
    values['sync_category_${entry.key}'] = entry.value;
  }
  values['sync_paired_devices'] = sync.pairedDevices;
  values['sync_webdav'] = sync.webdavConfigured
      ? 'configured${sync.webdavHost == null ? '' : ' (${sync.webdavHost})'}'
      : 'not configured';

  return DiagnosticsSettingsSnapshot(
    values: values,
    credentials: credentials,
    notes: notes,
  );
}

Future<bool> _configured(
  SettingsRegistry registry,
  SettingsKey<String> key,
) async {
  try {
    final raw = await registry.readRaw(key);
    return raw is String && raw.trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

String? _hostOf(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
  final host = uri?.host ?? '';
  return host.isEmpty ? null : host;
}
