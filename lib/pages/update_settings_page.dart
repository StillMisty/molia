import 'dart:async';

import 'package:intl/intl.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/models/app_release.dart';
import '../l10n/app_localizations.dart';
import '../providers/update_provider.dart';
import '../widgets/settings/settings_tiles.dart';

/// 「关于与更新」子页：渠道 / 自动检查 / 检查更新 / 新版本下载安装 / 高级 / 关于。
///
/// 从设置首屏「通用与数据」进入（入口副标题显示当前版本或可更新版本）。
/// 平台差异（Android 系统安装器 / 桌面替换重启 / Web 刷新 / iOS 不支持）
/// 全部由 [UpdateProvider] 与安装策略层消化，这里只按状态渲染。
class UpdateSettingsPage extends StatelessWidget {
  const UpdateSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // 测试等场景可能不提供 provider：显示空页而不是崩溃（入口行同样隐藏）。
    final provider = context.watch<UpdateProvider?>();

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.settingsUpdateTitle),
        automaticallyImplyLeading: true,
      ),
      body: provider == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.all(kSettingsPadding),
              children: [
                _UpdateSection(provider: provider, l10n: l10n),
                // 检查中不展示上一次的结果：否则会把上一次下载过的版本
                // 当成当前可安装版本显示（状态未对齐的观感 bug）。
                if (provider.release != null &&
                    provider.status != UpdateStatus.upToDate &&
                    provider.status != UpdateStatus.checking) ...[
                  const SizedBox(height: kSettingsSectionSpacing),
                  _ReleaseSection(provider: provider, l10n: l10n),
                ],
                const SizedBox(height: kSettingsSectionSpacing),
                _AdvancedSection(provider: provider, l10n: l10n),
                const SizedBox(height: kSettingsSectionSpacing),
                _AboutSection(provider: provider, l10n: l10n),
              ],
            ),
    );
  }
}

/// 更新：渠道 / 自动检查 / 检查更新入口。
class _UpdateSection extends StatelessWidget {
  const _UpdateSection({required this.provider, required this.l10n});

  final UpdateProvider provider;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final busy = provider.status == UpdateStatus.checking ||
        provider.status == UpdateStatus.downloading;
    return SettingsSectionCard(
      title: l10n.updateSettingsSection,
      children: [
        // Web 的 Pages 只部署稳定版清单，渠道选择只对原生端有意义。
        if (provider.channelSelectable)
          SettingsChoiceRow<UpdateChannel>(
            key: const Key('settingsUpdateChannelItem'),
            icon: Icons.alt_route_rounded,
            title: l10n.updateChannelTitle,
            subtitle: l10n.updateChannelSubtitle,
            value: provider.channel,
            options: [
              (UpdateChannel.stable, l10n.updateChannelStable),
              (UpdateChannel.beta, l10n.updateChannelBeta),
            ],
            onChanged: (channel) => unawaited(provider.setChannel(channel)),
          ),
        SettingsSwitchTile(
          switchKey: const Key('settingsUpdateAutoCheckSwitch'),
          icon: Icons.schedule_rounded,
          title: l10n.updateAutoCheckTitle,
          subtitle: l10n.updateAutoCheckSubtitle,
          value: provider.autoCheckEnabled,
          onChanged: (value) => unawaited(provider.setAutoCheckEnabled(value)),
        ),
        SettingsNavTile(
          key: const Key('settingsUpdateCheckItem'),
          icon: Icons.system_update_alt_rounded,
          title: l10n.updateCheckTitle,
          subtitle: updateStatusText(l10n, provider),
          // 检查中 / 下载中不允许重复触发；下载中应走发布卡片的取消按钮。
          onTap: busy ? null : () => unawaited(provider.check()),
        ),
      ],
    );
  }
}

/// 新版本：版本信息 + 发布说明 + 进度 + 操作按钮。
class _ReleaseSection extends StatelessWidget {
  const _ReleaseSection({required this.provider, required this.l10n});

  final UpdateProvider provider;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final release = provider.release!;
    final theme = Theme.of(context);
    final m3e = M3ETheme.of(context);
    final releasedAt = release.releasedAt;

    return SettingsSectionCard(
      title: l10n.updateReleaseSection,
      children: [
        SettingsInfoTile(
          key: const Key('settingsUpdateReleaseItem'),
          icon: Icons.new_releases_rounded,
          title: l10n.updateReleaseTitle(release.version),
          subtitle: releasedAt == null
              ? l10n.updateReleaseDateUnknown
              : l10n.updateReleaseDate(
                  DateFormat('yyyy-MM-dd').format(releasedAt),
                ),
        ),
        if (release.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 4,
              vertical: kSettingsSmallSpacing,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: Text(
                  release.notes,
                  style: m3e.typeScale.bodySmall.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        if (provider.status == UpdateStatus.downloading)
          _DownloadProgress(provider: provider, l10n: l10n),
        _ReleaseActions(provider: provider, l10n: l10n),
      ],
    );
  }
}

/// 下载进度（高频值走 ValueListenable，不重建整页）。
class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({required this.provider, required this.l10n});

  final UpdateProvider provider;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3e = M3ETheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 4,
        vertical: kSettingsSmallSpacing,
      ),
      child: ValueListenableBuilder<UpdateProgress>(
        valueListenable: provider.progress,
        builder: (context, progress, _) {
          final fraction = progress.fraction;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              M3EProgressIndicator.linear(
                value: fraction,
                linearSize: M3EProgressIndicatorSize.m,
                color: theme.colorScheme.primary,
                trackColor: theme.colorScheme.surfaceContainerHighest,
              ),
              const SizedBox(height: kSettingsSmallSpacing),
              Text(
                updateProgressText(l10n, progress),
                style: m3e.typeScale.bodySmall.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 操作按钮：按状态与平台给出唯一主操作 + 兜底出口。
class _ReleaseActions extends StatelessWidget {
  const _ReleaseActions({required this.provider, required this.l10n});

  final UpdateProvider provider;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final status = provider.status;
    final platform = provider.platform?.platform;
    final canOpenPage = provider.release?.notesUrl != null;
    final permissionMissing =
        provider.failure == UpdateFailureKind.permission;

    final actions = <Widget>[];

    if (status == UpdateStatus.downloading) {
      actions.add(
        M3EButton.text(
          key: const Key('settingsUpdateCancelButton'),
          onPressed: provider.cancelDownload,
          child: Text(l10n.updateCancelDownload),
        ),
      );
    } else if (status == UpdateStatus.installing) {
      actions.add(
        Row(
          children: [
            const M3EProgressIndicator.circular(size: 16, strokeWidth: 2),
            const SizedBox(width: kSettingsSmallSpacing),
            Expanded(
              child: Text(l10n.updateInstallingHint),
            ),
          ],
        ),
      );
    } else if (platform == 'ios') {
      actions.add(Text(l10n.updateIosHint));
    } else if (platform == 'web') {
      actions.add(
        M3EButton.filled(
          key: const Key('settingsUpdateReloadButton'),
          onPressed: () => unawaited(provider.reloadPage()),
          child: Text(l10n.updateReloadNow),
        ),
      );
    } else if (permissionMissing) {
      actions.add(
        M3EButton.filled(
          key: const Key('settingsUpdatePermissionButton'),
          onPressed: () =>
              unawaited(provider.openInstallPermissionSettings()),
          child: Text(l10n.updateGrantInstallPermission),
        ),
      );
    } else if (provider.hasDownloadedPackage && status != UpdateStatus.available) {
      actions.add(
        M3EButton.filled(
          key: const Key('settingsUpdateInstallButton'),
          onPressed: () => unawaited(provider.installDownloaded()),
          child: Text(l10n.updateInstallNow),
        ),
      );
    } else {
      actions.add(
        M3EButton.filled(
          key: const Key('settingsUpdateDownloadButton'),
          onPressed: () => unawaited(provider.downloadAndInstall()),
          child: Text(l10n.updateDownloadAndInstall),
        ),
      );
    }

    if (canOpenPage && status != UpdateStatus.downloading) {
      actions.add(
        M3EButton.text(
          key: const Key('settingsUpdateOpenPageButton'),
          onPressed: () => unawaited(_openReleasePage(context)),
          child: Text(l10n.updateOpenDownloadPage),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: kSettingsSmallSpacing),
      child: Wrap(
        spacing: kSettingsSmallSpacing,
        runSpacing: kSettingsSmallSpacing,
        children: actions,
      ),
    );
  }

  Future<void> _openReleasePage(BuildContext context) async {
    final url = provider.release?.notesUrl;
    if (url == null) return;
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }
}

/// 高级：清单地址覆盖与下载镜像前缀（都可留空走默认）。
class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({required this.provider, required this.l10n});

  final UpdateProvider provider;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(
      title: l10n.updateAdvancedSection,
      children: [
        SettingsNavTile(
          key: const Key('settingsUpdateManifestItem'),
          icon: Icons.link_rounded,
          title: l10n.updateManifestOverrideTitle,
          subtitle: provider.manifestUrlOverride.isEmpty
              ? l10n.updateManifestOverrideDefault
              : provider.manifestUrlOverride,
          onTap: () => _editText(
            context,
            title: l10n.updateManifestOverrideTitle,
            hint: l10n.updateManifestOverrideHint,
            initial: provider.manifestUrlOverride,
            onSave: provider.setManifestUrlOverride,
          ),
        ),
        SettingsNavTile(
          key: const Key('settingsUpdateMirrorItem'),
          icon: Icons.cloud_download_rounded,
          title: l10n.updateDownloadPrefixTitle,
          subtitle: provider.downloadPrefix.isEmpty
              ? l10n.updateDownloadPrefixDefault
              : provider.downloadPrefix,
          onTap: () => _editText(
            context,
            title: l10n.updateDownloadPrefixTitle,
            hint: l10n.updateDownloadPrefixHint,
            initial: provider.downloadPrefix,
            onSave: provider.setDownloadPrefix,
          ),
        ),
      ],
    );
  }

  Future<void> _editText(
    BuildContext context, {
    required String title,
    required String hint,
    required String initial,
    required Future<void> Function(String value) onSave,
  }) async {
    final controller = TextEditingController(text: initial);
    final navigator = Navigator.of(context, rootNavigator: true);
    await M3EDialog.show<void>(
      context,
      dialog: M3EDialog(
        title: title,
        content: SizedBox(
          width: settingsDialogWidth(context),
          child: M3ETextField(
            controller: controller,
            placeholder: hint,
            leading: const Icon(Icons.link_rounded),
            autofocus: true,
          ),
        ),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () async {
              await onSave(controller.text);
              navigator.pop();
            },
            child: Text(l10n.saveChanges),
          ),
        ],
      ),
    );
    controller.dispose();
  }
}

/// 关于：当前版本与平台。
class _AboutSection extends StatelessWidget {
  const _AboutSection({required this.provider, required this.l10n});

  final UpdateProvider provider;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final platform = provider.platform;
    return SettingsSectionCard(
      title: l10n.updateAboutSection,
      children: [
        SettingsInfoTile(
          key: const Key('settingsUpdateVersionItem'),
          icon: Icons.info_outline_rounded,
          title: l10n.updateCurrentVersion,
          subtitle: provider.currentVersionLabel,
        ),
        if (platform != null)
          SettingsInfoTile(
            key: const Key('settingsUpdatePlatformItem'),
            icon: Icons.devices_rounded,
            title: l10n.updatePlatformTitle,
            subtitle: '${platform.platform} · ${platform.arch}',
          ),
      ],
    );
  }
}

/// 检查更新行的状态文案（供页面与设置入口共用）。
String updateStatusText(AppLocalizations l10n, UpdateProvider provider) {
  switch (provider.status) {
    case UpdateStatus.idle:
      final last = provider.lastCheckedAt;
      return last == null
          ? l10n.updateStatusIdle
          : l10n.updateLastChecked(
              DateFormat('yyyy-MM-dd HH:mm').format(last),
            );
    case UpdateStatus.checking:
      return l10n.updateStatusChecking;
    case UpdateStatus.upToDate:
      return l10n.updateStatusUpToDate;
    case UpdateStatus.available:
      return l10n.updateStatusAvailable(provider.release?.version ?? '');
    case UpdateStatus.downloading:
      return l10n.updateStatusDownloading;
    case UpdateStatus.downloaded:
      return l10n.updateStatusDownloaded;
    case UpdateStatus.installing:
      return l10n.updateStatusInstalling;
    case UpdateStatus.error:
      return updateFailureText(l10n, provider.failure);
  }
}

/// 失败类别 → 本机化文案。
String updateFailureText(AppLocalizations l10n, UpdateFailureKind? kind) {
  switch (kind) {
    case null:
    case UpdateFailureKind.network:
      return l10n.updateErrorNetwork;
    case UpdateFailureKind.manifestInvalid:
      return l10n.updateErrorManifest;
    case UpdateFailureKind.unsupported:
      return l10n.updateErrorUnsupported;
    case UpdateFailureKind.checksumMismatch:
      return l10n.updateErrorChecksum;
    case UpdateFailureKind.permission:
      return l10n.updateErrorPermission;
    case UpdateFailureKind.notWritable:
      return l10n.updateErrorNotWritable;
    case UpdateFailureKind.installFailed:
      return l10n.updateErrorInstall;
  }
}

/// 下载进度文案（百分比 + 已下载 MB + 速度）。
String updateProgressText(AppLocalizations l10n, UpdateProgress progress) {
  final receivedMb = progress.received / (1024 * 1024);
  final fraction = progress.fraction;
  final percent = fraction == null ? null : (fraction * 100).round();
  final speedMb = progress.bytesPerSecond / (1024 * 1024);
  return l10n.updateDownloadProgress(
    percent == null ? '--' : '$percent',
    receivedMb.toStringAsFixed(1),
    speedMb.toStringAsFixed(1),
  );
}
