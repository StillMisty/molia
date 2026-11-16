/// 下载与缓存子页：保存位置 / 下载任务入口 / 缓存策略与清理。
///
/// 原先「下载设置 / 下载管理 / 缓存管理」三个首屏入口合成一页：下载是
/// 「文件存到哪」，缓存是「临时占用怎么治理」，两者都属于存储，分三个入口
/// 只会让首屏多两行。任务队列仍由 [DownloadsManagePage] 承担，本页只留入口。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/cache_service.dart';
import '../services/download/download_manager.dart';
import '../services/download/download_settings.dart';
import '../services/notification_service.dart';
import '../services/save_as.dart';
import '../utils/responsive.dart';
import '../widgets/settings/cache_policy_dialog.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';
import 'downloads_manage_page.dart';

/// 桌面平台支持自选保存目录（dart:io 路径语义；移动端固定平台目录）。
bool get _supportsCustomSaveDir => isDesktopPlatform();

bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

bool get _isIos => defaultTargetPlatform == TargetPlatform.iOS;

class DownloadsAndCachePage extends StatefulWidget {
  const DownloadsAndCachePage({super.key});

  @override
  State<DownloadsAndCachePage> createState() => _DownloadsAndCachePageState();
}

class _DownloadsAndCachePageState extends State<DownloadsAndCachePage> {
  // 自定义输入范围：0 恒表示「不限制 / 永不过期」（CacheService 语义），
  // 其余值限制在合理区间，防止误输入导致缓存失控。
  static const int _audioMaxMinMb = 16;
  static const int _audioMaxMaxMb = 102400; // 100 GB

  final Map<CachePartition, CacheUsage?> _usage = {};

  bool _audioEnabled = CacheService.defaultAudioEnabled;
  int _audioMaxMb = CacheService.defaultAudioMaxMb;
  bool _busy = false;

  CacheService? get _service => context.read<CacheService?>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = _service;
    if (service == null) return;
    final results = await Future.wait([
      service.audioEnabled(),
      service.audioMaxMb(),
      for (final partition in CachePartition.values) service.usage(partition),
    ]);
    if (!mounted) return;
    setState(() {
      _audioEnabled = results[0] as bool;
      _audioMaxMb = results[1] as int;
      for (var i = 0; i < CachePartition.values.length; i++) {
        _usage[CachePartition.values[i]] = results[2 + i] as CacheUsage;
      }
    });
  }

  Future<void> _refreshUsage() async {
    final service = _service;
    if (service == null) return;
    final results = await Future.wait([
      for (final partition in CachePartition.values) service.usage(partition),
    ]);
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < CachePartition.values.length; i++) {
        _usage[CachePartition.values[i]] = results[i];
      }
    });
  }

  /// 单分区清理：与「全部清理」同一口径，先确认再执行（防误触）。
  Future<void> _clear(CachePartition partition) async {
    final l10n = AppLocalizations.of(context)!;
    // 弹层 dialog 挂 root navigator（M3EDialog.show 语义）；本页位于设置弹层的
    // 嵌套 Navigator 内，页面 context 上的 pop 会误退本页，关闭要显式定向。
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.cacheClearPart(_partitionLabel(l10n, partition)),
        content: Text(l10n.trackCacheClearHint),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
            child: Text(l10n.clear),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _service?.clear(partition);
      await _refreshUsage();
      if (!mounted) return;
      _notifyCleared();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll() async {
    final l10n = AppLocalizations.of(context)!;
    // 弹层 dialog 挂 root navigator（M3EDialog.show 语义）；本页位于设置弹层的
    // 嵌套 Navigator 内，页面 context 上的 pop 会误退本页，关闭要显式定向。
    final navigator = Navigator.of(context, rootNavigator: true);
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.cacheClearAll,
        content: Text(l10n.cacheClearAllConfirm),
        actions: [
          M3EButton.text(
            onPressed: () => navigator.pop(false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => navigator.pop(true),
            child: Text(l10n.cacheClearAll),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await _service?.clearAll();
      await _refreshUsage();
      if (!mounted) return;
      _notifyCleared();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 分区显示名（确认弹窗标题用）。
  static String _partitionLabel(
    AppLocalizations l10n,
    CachePartition partition,
  ) {
    return switch (partition) {
      CachePartition.audio => l10n.cachePartitionAudio,
      CachePartition.lyrics => l10n.cachePartitionLyrics,
      CachePartition.artwork => l10n.cachePartitionArtwork,
    };
  }

  void _notifyCleared() {
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    if (notifications != null) {
      notifications.showSuccessSnackBar(l10n.cacheCleared);
    } else {
      M3ESnackbar.show(context, message: l10n.cacheCleared);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.watch<DownloadSettings?>();
    final downloads = context.watch<DownloadManager?>();
    final cacheAvailable = _service != null;
    return SettingsSubPage(
      title: l10n.settingsDownloadsAndCacheTitle,
      safeArea: true,
      children: [
        if (settings != null) ...[
          _downloadSection(context, l10n, settings, downloads),
          const SizedBox(height: kSettingsSectionSpacing),
        ],
        if (cacheAvailable) ...[
          _cacheSection(l10n),
          const SizedBox(height: 24),
          // 唯一整行主操作：全清仍走确认弹层。
          SizedBox(
            width: double.infinity,
            child: M3EButton.icon(
              style: M3EButtonStyle.tonal,
              onPressed: _busy ? null : _clearAll,
              icon: const Icon(Icons.delete_sweep_rounded),
              label: Text(l10n.cacheClearAll),
            ),
          ),
        ],
      ],
    );
  }

  Widget _downloadSection(
    BuildContext context,
    AppLocalizations l10n,
    DownloadSettings settings,
    DownloadManager? downloads,
  ) {
    return SettingsSectionCard(
      title: l10n.downloadSettingsTitle,
      children: [
        SettingsValueTile(
          key: const Key('downloadSaveLocationItem'),
          icon: Icons.folder_rounded,
          title: l10n.downloadSaveLocation,
          subtitle: switch (defaultTargetPlatform) {
            TargetPlatform.android =>
              settings.publishToPublicDir
                  ? l10n.downloadSaveLocationFixedHintAndroid
                  : l10n.downloadSaveLocationFixedHintAndroidOff,
            TargetPlatform.iOS => l10n.downloadSaveLocationFixedHintIos,
            _ => l10n.downloadSaveLocationSharedHint,
          },
          value: _saveLocationLabel(l10n, settings),
          onTap: _supportsCustomSaveDir
              ? () => unawaited(_pickDirectory(context, settings))
              : () => M3ESnackbar.show(
                  context,
                  message: _fixedLocationHint(l10n, settings),
                ),
        ),
        // 公共目录发布只在 Android 有语义（其余平台的下载根目录本身
        // 就是公共目录）；发布器不支持时整行不显示。
        if (downloads?.publisherSupported ?? false)
          SettingsSwitchTile(
            switchKey: const Key('downloadPublishPublicSwitch'),
            icon: Icons.public_rounded,
            title: l10n.downloadPublishToPublicDir,
            subtitle: l10n.downloadPublishToPublicDirSubtitle,
            value: settings.publishToPublicDir,
            onChanged: (value) =>
                unawaited(settings.setPublishToPublicDir(value)),
          ),
        // 任务队列与批量下载：低频任务页不占首屏，从这里进入。
        SettingsNavTile(
          key: const Key('settingsDownloadsManageItem'),
          icon: Icons.download_for_offline_rounded,
          title: l10n.downloadsManageTitle,
          subtitle: l10n.downloadsManageSubtitle,
          onTap: () =>
              openSettingsSubPage(context, const DownloadsManagePage()),
        ),
      ],
    );
  }

  Widget _cacheSection(AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.settingsCacheTitle,
      children: [
        SettingsSwitchTile(
          icon: Icons.audiotrack_rounded,
          title: l10n.cachePolicyAudioEnabled,
          subtitle: '',
          value: _audioEnabled,
          onChanged: (value) async {
            setState(() => _audioEnabled = value);
            await _service?.setAudioEnabled(value);
          },
        ),
        SettingsValueTile(
          icon: Icons.storage_rounded,
          title: l10n.cachePolicyAudioMax,
          value: cachePolicySizeLabel(l10n, _audioMaxMb),
          onTap: () async {
            // 建议值来自设备容量（不可知时为 null，不展示建议行）。
            final suggested = await _service?.suggestedAudioMaxMb();
            if (!mounted) return;
            final value = await showCachePolicyValueDialog(
              context,
              title: l10n.cachePolicyAudioMax,
              current: _audioMaxMb,
              min: _audioMaxMinMb,
              max: _audioMaxMaxMb,
              unitLabel: l10n.cacheUnitMb,
              zeroLabel: l10n.cacheUnlimited,
              labelOf: (value) => cachePolicySizeLabel(l10n, value),
              presets: const [256, 512, 1024, 2048, 0],
              suggestedMb: suggested,
            );
            if (value == null || !mounted) return;
            setState(() => _audioMaxMb = value);
            await _service?.setAudioMaxMb(value);
          },
        ),
        // 用量行 + 行尾清理按钮：破坏性动作不占整行，也不夹在普通行中间。
        for (final partition in CachePartition.values)
          SettingsInfoTile(
            key: Key('cacheClear${_partitionSuffix(partition)}Item'),
            icon: _partitionIcon(partition),
            title: l10n.cacheUsageTitle,
            subtitle:
                '${_partitionLabel(l10n, partition)} · '
                '${_usageText(l10n, partition)}',
            trailing: _clearButton(l10n, partition),
          ),
      ],
    );
  }

  /// 清理按钮的 key 后缀（沿用旧缓存页的测试 key）。
  static String _partitionSuffix(CachePartition partition) {
    return switch (partition) {
      CachePartition.audio => 'Audio',
      CachePartition.lyrics => 'Lyrics',
      CachePartition.artwork => 'Artwork',
    };
  }

  static IconData _partitionIcon(CachePartition partition) {
    return switch (partition) {
      CachePartition.audio => Icons.audiotrack_rounded,
      CachePartition.lyrics => Icons.lyrics_rounded,
      CachePartition.artwork => Icons.image_rounded,
    };
  }

  /// 行尾清理按钮：图标语义带分区名，点击仍先确认。
  Widget _clearButton(AppLocalizations l10n, CachePartition partition) {
    return M3EIconButton(
      variant: M3EIconButtonVariant.standard,
      icon: Icon(
        Icons.delete_outline_rounded,
        color: Theme.of(context).colorScheme.error,
      ),
      semanticLabel: l10n.cacheClearPartitionNamed(
        _partitionLabel(l10n, partition),
      ),
      onPressed: _busy ? null : () => _clear(partition),
    );
  }

  /// 分区用量文案（未就绪时显示计算中）。
  String _usageText(AppLocalizations l10n, CachePartition partition) {
    final usage = _usage[partition];
    if (usage == null) return l10n.cacheUsageComputing;
    return l10n.cacheUsage(_formatSize(usage.bytes), usage.count);
  }

  /// 保存位置的显示值：桌面显示自定义路径 / 默认；移动端说明实际落点。
  String _saveLocationLabel(AppLocalizations l10n, DownloadSettings settings) {
    if (_isAndroid) return l10n.downloadSaveLocationAndroid;
    if (_isIos) return l10n.downloadSaveLocationIos;
    return settings.saveDir.isEmpty
        ? l10n.downloadSaveLocationDefault
        : settings.saveDir;
  }

  String _fixedLocationHint(AppLocalizations l10n, DownloadSettings settings) {
    if (_isAndroid) {
      return settings.publishToPublicDir
          ? l10n.downloadSaveLocationFixedHintAndroid
          : l10n.downloadSaveLocationFixedHintAndroidOff;
    }
    if (_isIos) return l10n.downloadSaveLocationFixedHintIos;
    return l10n.downloadSaveLocationDefault;
  }

  /// 选择保存目录（桌面）；选择器默认打开另存目录。
  Future<void> _pickDirectory(
    BuildContext context,
    DownloadSettings settings,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    final saveAs = context.read<SaveAs?>();
    String? picked;
    try {
      picked = await FilePicker.getDirectoryPath(
        dialogTitle: l10n.downloadPickDirectory,
        initialDirectory: await saveAs?.rootPath(),
      );
    } catch (_) {
      picked = null;
    }
    if (picked == null || picked.isEmpty) return;
    await settings.setSaveDir(picked);
    notifications?.showSnackBar(l10n.save);
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
