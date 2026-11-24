/// 下载与缓存子页：保存位置 / 下载任务入口 / 缓存策略与清理。
///
/// 原先「下载设置 / 下载管理 / 缓存管理」三个首屏入口合成一页：下载是
/// 「文件存到哪」，缓存是「临时占用怎么治理」，两者都属于存储，分三个入口
/// 只会让首屏多两行。任务队列仍由 [DownloadsManagePage] 承担，本页只留入口。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../l10n/app_localizations.dart';
import '../providers/app_providers.dart';
import '../services/cache_service.dart';
import '../services/download/download_manager.dart';
import '../services/download/download_settings.dart';
import '../services/notification_permission.dart';
import '../services/notification_service.dart';
import '../services/save_as.dart';
import '../theme/m3e_context.dart';
import '../widgets/responsive.dart';
import '../widgets/settings/cache_policy_dialog.dart';
import '../widgets/settings/settings_subpage.dart';
import '../widgets/settings/settings_tiles.dart';
import 'downloads_manage_page.dart';

/// 桌面平台支持自选保存目录（dart:io 路径语义；移动端固定平台目录）。
bool get _supportsCustomSaveDir => isDesktopPlatform();

bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

bool get _isIos => defaultTargetPlatform == TargetPlatform.iOS;

class DownloadsAndCachePage extends ConsumerStatefulWidget {
  const DownloadsAndCachePage({super.key});

  @override
  ConsumerState<DownloadsAndCachePage> createState() =>
      _DownloadsAndCachePageState();
}

class _DownloadsAndCachePageState extends ConsumerState<DownloadsAndCachePage> {
  // 自定义输入范围：0 恒表示「不限制 / 永不过期」（CacheService 语义），
  // 其余值限制在合理区间，防止误输入导致缓存失控。
  static const int _audioMaxMinMb = 16;
  static const int _audioMaxMaxMb = 102400; // 100 GB

  // 保留策略范围：0 表示「不限制 / 永不过期」（CacheService 语义）。
  static const int _retentionDaysMin = 1;
  static const int _retentionDaysMax = 3650; // 10 年
  static const int _artworkMaxMin = 10;
  static const int _artworkMaxMax = 100000;

  final Map<CachePartition, CacheUsage?> _usage = {};

  bool _audioEnabled = CacheService.defaultAudioEnabled;
  int _audioMaxMb = CacheService.defaultAudioMaxMb;
  int _lyricsTtlDays = CacheService.defaultLyricsTtlDays;
  int _artworkMaxObjects = CacheService.defaultArtworkMaxObjects;
  int _artworkStaleDays = CacheService.defaultArtworkStaleDays;
  bool _busy = false;

  CacheService? get _service => ref.read(cacheServiceProvider);

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
      service.lyricsTtlDays(),
      service.artworkMaxObjects(),
      service.artworkStaleDays(),
      for (final partition in CachePartition.values) service.usage(partition),
    ]);
    if (!mounted) return;
    setState(() {
      _audioEnabled = results[0] as bool;
      _audioMaxMb = results[1] as int;
      _lyricsTtlDays = results[2] as int;
      _artworkMaxObjects = results[3] as int;
      _artworkStaleDays = results[4] as int;
      for (var i = 0; i < CachePartition.values.length; i++) {
        _usage[CachePartition.values[i]] = results[5 + i] as CacheUsage;
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
    final NotificationService? notifications = ref.read(
      notificationServiceProvider,
    );
    if (notifications != null) {
      notifications.showSuccessSnackBar(l10n.cacheCleared);
    } else {
      M3ESnackbar.show(context, message: l10n.cacheCleared);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final DownloadSettingsState? settings = ref.watch(downloadSettingsProvider);
    final DownloadManagerState? downloads = ref.watch(downloadManagerProvider);
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
    DownloadSettingsState settings,
    DownloadManagerState? downloads,
  ) {
    final DownloadSettings? controller = ref.read(
      downloadSettingsControllerProvider,
    );
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
              ? () => unawaited(_pickDirectory(context))
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
            onChanged: (value) => unawaited(
              controller?.setPublishToPublicDir(value) ?? Future<void>.value(),
            ),
          ),
        // 文件名模板 / 标签写入 / 下载通知：与保存位置同属「下载」域，低频
        // 但改的时候一定是在这张卡里找，不再拆去高级设置。
        SettingsValueTile(
          key: const Key('downloadFilenameTemplateItem'),
          icon: Icons.edit_note_rounded,
          title: l10n.downloadFilenameTemplate,
          subtitle: l10n.downloadFilenameTemplateHint,
          value: settings.filenameTemplate,
          onTap: () => unawaited(_editTemplate(context, settings)),
        ),
        SettingsSwitchTile(
          switchKey: const Key('downloadEmbedTagsSwitch'),
          icon: Icons.music_note_rounded,
          title: l10n.downloadEmbedTags,
          subtitle: l10n.downloadEmbedTagsSubtitle,
          value: settings.embedTags,
          onChanged: (value) => unawaited(
            controller?.setEmbedTags(value) ?? Future<void>.value(),
          ),
        ),
        // 下载通知只在 Android 有语义（前台服务 + 通知栏进度）。
        if (downloads?.notificationsSupported ?? false)
          SettingsSwitchTile(
            switchKey: const Key('downloadNotificationsSwitch'),
            icon: Icons.notifications_active_rounded,
            title: l10n.downloadNotifications,
            subtitle: l10n.downloadNotificationsSubtitle,
            value: settings.notifications,
            onChanged: (value) {
              unawaited(
                controller?.setNotifications(value) ?? Future<void>.value(),
              );
              if (value) unawaited(NotificationPermission.ensureRequested());
            },
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
        // 歌词 / 封面保留策略：与音频容量同属缓存治理，不再拆去高级设置。
        SettingsValueTile(
          icon: Icons.schedule_rounded,
          title: l10n.cachePolicyLyricsTtl,
          value: _lyricsTtlDays <= 0
              ? l10n.cacheNeverExpire
              : l10n.cacheValueDays(_lyricsTtlDays),
          onTap: () => _editCachePolicy(
            context,
            title: l10n.cachePolicyLyricsTtl,
            current: _lyricsTtlDays,
            min: _retentionDaysMin,
            max: _retentionDaysMax,
            unitLabel: l10n.cacheUnitDays,
            zeroLabel: l10n.cacheNeverExpire,
            labelOf: (value) =>
                value <= 0 ? l10n.cacheNeverExpire : l10n.cacheValueDays(value),
            onSelected: (value) async {
              setState(() => _lyricsTtlDays = value);
              await _service?.setLyricsTtlDays(value);
            },
          ),
        ),
        SettingsValueTile(
          icon: Icons.image_rounded,
          title: l10n.cachePolicyArtworkMax,
          value: _artworkMaxObjects <= 0
              ? l10n.cacheUnlimited
              : l10n.cacheValueItems(_artworkMaxObjects),
          onTap: () => _editCachePolicy(
            context,
            title: l10n.cachePolicyArtworkMax,
            current: _artworkMaxObjects,
            min: _artworkMaxMin,
            max: _artworkMaxMax,
            unitLabel: l10n.cacheUnitItems,
            zeroLabel: l10n.cacheUnlimited,
            labelOf: (value) =>
                value <= 0 ? l10n.cacheUnlimited : l10n.cacheValueItems(value),
            onSelected: (value) async {
              setState(() => _artworkMaxObjects = value);
              await _service?.setArtworkMaxObjects(value);
            },
          ),
        ),
        SettingsValueTile(
          icon: Icons.update_rounded,
          title: l10n.cachePolicyArtworkStale,
          value: _artworkStaleDays <= 0
              ? l10n.cacheNeverExpire
              : l10n.cacheValueDays(_artworkStaleDays),
          onTap: () => _editCachePolicy(
            context,
            title: l10n.cachePolicyArtworkStale,
            current: _artworkStaleDays,
            min: _retentionDaysMin,
            max: _retentionDaysMax,
            unitLabel: l10n.cacheUnitDays,
            zeroLabel: l10n.cacheNeverExpire,
            labelOf: (value) =>
                value <= 0 ? l10n.cacheNeverExpire : l10n.cacheValueDays(value),
            onSelected: (value) async {
              setState(() => _artworkStaleDays = value);
              await _service?.setArtworkStaleDays(value);
            },
          ),
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
  String _saveLocationLabel(
    AppLocalizations l10n,
    DownloadSettingsState settings,
  ) {
    if (_isAndroid) return l10n.downloadSaveLocationAndroid;
    if (_isIos) return l10n.downloadSaveLocationIos;
    return settings.saveDir.isEmpty
        ? l10n.downloadSaveLocationDefault
        : settings.saveDir;
  }

  String _fixedLocationHint(
    AppLocalizations l10n,
    DownloadSettingsState settings,
  ) {
    if (_isAndroid) {
      return settings.publishToPublicDir
          ? l10n.downloadSaveLocationFixedHintAndroid
          : l10n.downloadSaveLocationFixedHintAndroidOff;
    }
    if (_isIos) return l10n.downloadSaveLocationFixedHintIos;
    return l10n.downloadSaveLocationDefault;
  }

  /// 选择保存目录（桌面）；选择器默认打开另存目录。
  Future<void> _pickDirectory(BuildContext context) async {
    final l10n = AppLocalizations.of(context)!;
    final NotificationService? notifications = ref.read(
      notificationServiceProvider,
    );
    final SaveAs? saveAs = ref.read(saveAsProvider);
    String? picked;
    try {
      // 保存目录只在桌面可改，pickDirectory() 给的是 file:// URI，
      // 转回路径即可（Android 的 content:// 分支到不了这里）。
      final uri = await FilePicker.pickDirectory(
        dialogTitle: l10n.downloadPickDirectory,
        initialDirectory: await saveAs?.rootPath(),
      );
      picked = uri?.toFilePath();
    } catch (_) {
      picked = null;
    }
    if (picked == null || picked.isEmpty) return;
    await ref.read(downloadSettingsControllerProvider)?.setSaveDir(picked);
    notifications?.showSnackBar(l10n.save);
  }

  /// 保留策略编辑：数值弹层确认后写回服务（0 = 不限制 / 永不过期）。
  Future<void> _editCachePolicy(
    BuildContext context, {
    required String title,
    required int current,
    required int min,
    required int max,
    required String unitLabel,
    required String zeroLabel,
    required String Function(int value) labelOf,
    required ValueChanged<int> onSelected,
  }) async {
    final value = await showCachePolicyValueDialog(
      context,
      title: title,
      current: current,
      min: min,
      max: max,
      unitLabel: unitLabel,
      zeroLabel: zeroLabel,
      labelOf: labelOf,
    );
    if (value == null || !mounted) return;
    onSelected(value);
  }

  /// 编辑文件名模板：实时预览 + 恢复默认。
  Future<void> _editTemplate(
    BuildContext context,
    DownloadSettingsState settings,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: settings.filenameTemplate);
    final navigator = Navigator.of(context, rootNavigator: true);
    final result = await M3EDialog.show<String>(
      context,
      dialog: StatefulBuilder(
        builder: (context, setDialogState) {
          final preview = DownloadSettings.applyTemplate(
            controller.text,
            const {'artist': '歌手', 'title': '歌名', 'album': '专辑'},
          );
          return M3EDialog(
            title: l10n.downloadFilenameTemplate,
            content: SizedBox(
              width: settingsDialogWidth(context),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  M3ETextField(
                    controller: controller,
                    autofocus: true,
                    placeholder: l10n.downloadFilenameTemplate,
                    onChanged: (_) => setDialogState(() {}),
                    onSubmitted: (_) => navigator.pop(controller.text),
                  ),
                  const SizedBox(height: kSettingsSmallSpacing),
                  Text(
                    l10n.downloadFilenameTemplateHint,
                    style: context.typeScale.bodySmall.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.downloadFilenamePreview}: $preview',
                    style: context.typeScale.bodySmall.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              M3EButton.text(
                onPressed: () {
                  controller.text = kDefaultFilenameTemplate;
                  setDialogState(() {});
                },
                child: Text(l10n.downloadReset),
              ),
              M3EButton.text(
                onPressed: () => navigator.pop(),
                child: Text(l10n.cancel),
              ),
              M3EButton.filled(
                onPressed: () => navigator.pop(controller.text),
                child: Text(l10n.save),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (result == null) return;
    await ref
        .read(downloadSettingsControllerProvider)
        ?.setFilenameTemplate(result);
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
