import '../l10n/app_localizations.dart';

/// 省流状态副标题：开启时附当前网络状态（移动数据已生效 / Wi-Fi 未生效 /
/// 无法检测），让「仅移动数据生效」的行为对用户透明。
///
/// 设置首屏入口行与省流子页开关共用同一口径，避免两处文案漂移。
String dataSaverSubtitle(
  AppLocalizations l10n, {
  required bool enabled,
  required bool detectionAvailable,
  required bool onCellular,
}) {
  final status = !detectionAvailable
      ? l10n.settingsDataSaverNetworkUnknown
      : (onCellular
          ? l10n.settingsDataSaverNetworkCellular
          : l10n.settingsDataSaverNetworkWifi);
  return enabled
      ? '${l10n.settingsDataSaverSubtitle} · $status'
      : l10n.settingsDataSaverSubtitle;
}
