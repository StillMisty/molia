import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/cache_service.dart';
import '../services/notification_service.dart';
import '../widgets/settings/settings_tiles.dart';

/// 缓存管理页：音频 / 歌词 / 封面三分区的占用、策略与清理。
///
/// 行一律走设置页共享行组件（[SettingsSectionCard] / [SettingsValueTile] /
/// [SettingsSwitchTile]）：M3E 列表卡片形状 + 排版走 typeScale。
class CacheManagementPage extends StatefulWidget {
  const CacheManagementPage({super.key});

  @override
  State<CacheManagementPage> createState() => _CacheManagementPageState();
}

class _CacheManagementPageState extends State<CacheManagementPage> {
  // 自定义输入范围：0 恒表示「不限制 / 永不过期」（CacheService 语义），
  // 其余值限制在合理区间，防止误输入导致缓存失控。
  static const int _audioMaxMinMb = 16;
  static const int _audioMaxMaxMb = 102400; // 100 GB
  static const int _daysMin = 1;
  static const int _daysMax = 3650; // 10 年
  static const int _artworkMaxMin = 10;
  static const int _artworkMaxMax = 100000;

  final Map<CachePartition, CacheUsage?> _usage = {};

  bool _audioEnabled = CacheService.defaultAudioEnabled;
  int _audioMaxMb = CacheService.defaultAudioMaxMb;
  int _lyricsTtlDays = CacheService.defaultLyricsTtlDays;
  int _artworkMaxObjects = CacheService.defaultArtworkMaxObjects;
  int _artworkStaleDays = CacheService.defaultArtworkStaleDays;
  bool _busy = false;

  CacheService get _service => context.read<CacheService>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final service = _service;
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
      await _service.clear(partition);
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
      await _service.clearAll();
      await _refreshUsage();
      if (!mounted) return;
      _notifyCleared();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 分区显示名（确认弹窗标题用）。
  static String _partitionLabel(AppLocalizations l10n, CachePartition partition) {
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
    final m3e = M3ETheme.of(context);

    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.settingsCacheTitle),
        automaticallyImplyLeading: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(kSettingsPadding),
          children: [
            Text(
              l10n.settingsCacheSubtitle,
              style: m3e.typeScale.bodySmall.copyWith(
                color: m3e.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: kSettingsSectionSpacing),
            _buildAudioSection(l10n),
            const SizedBox(height: kSettingsSectionSpacing),
            _buildLyricsSection(l10n),
            const SizedBox(height: kSettingsSectionSpacing),
            _buildArtworkSection(l10n),
            const SizedBox(height: 24),
            M3EButton.icon(
              style: M3EButtonStyle.tonal,
              onPressed: _busy ? null : _clearAll,
              icon: const Icon(Icons.delete_sweep_rounded),
              label: Text(l10n.cacheClearAll),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioSection(AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.cachePartitionAudio,
      children: [
        SettingsSwitchTile(
          icon: Icons.audiotrack_rounded,
          title: l10n.cachePolicyAudioEnabled,
          subtitle: '',
          value: _audioEnabled,
          onChanged: (value) async {
            setState(() => _audioEnabled = value);
            await _service.setAudioEnabled(value);
          },
        ),
        SettingsValueTile(
          icon: Icons.storage_rounded,
          title: l10n.cachePolicyAudioMax,
          value: _policyValueLabel(l10n, _audioMaxMb),
          onTap: () async {
            // 建议值来自设备容量（不可知时为 null，不展示建议行）。
            final suggested = await _service.suggestedAudioMaxMb();
            if (!mounted) return;
            await _promptPolicyValue(
              title: l10n.cachePolicyAudioMax,
              current: _audioMaxMb,
              min: _audioMaxMinMb,
              max: _audioMaxMaxMb,
              unitLabel: l10n.cacheUnitMb,
              zeroLabel: l10n.cacheUnlimited,
              presets: const [256, 512, 1024, 2048, 0],
              suggestedMb: suggested,
              onSelected: (value) async {
                setState(() => _audioMaxMb = value);
                await _service.setAudioMaxMb(value);
              },
            );
          },
        ),
        SettingsInfoTile(
          icon: Icons.offline_pin_rounded,
          title: l10n.cachePolicyAudioScope,
          subtitle: l10n.cachePolicyAudioHint,
        ),
        // 用量 + 单清：危险操作行放分区末行（error 容器成对色）。
        SettingsNavTile(
          key: const Key('cacheClearAudioItem'),
          icon: Icons.delete_outline_rounded,
          title: l10n.cacheClearPartition,
          subtitle: _usageText(l10n, CachePartition.audio),
          isDestructive: true,
          onTap: _busy ? null : () => _clear(CachePartition.audio),
        ),
      ],
    );
  }

  Widget _buildLyricsSection(AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.cachePartitionLyrics,
      children: [
        SettingsValueTile(
          icon: Icons.schedule_rounded,
          title: l10n.cachePolicyLyricsTtl,
          value: _lyricsTtlDays <= 0
              ? l10n.cacheNeverExpire
              : l10n.cacheValueDays(_lyricsTtlDays),
          onTap: () => _promptPolicyValue(
            title: l10n.cachePolicyLyricsTtl,
            current: _lyricsTtlDays,
            min: _daysMin,
            max: _daysMax,
            unitLabel: l10n.cacheUnitDays,
            zeroLabel: l10n.cacheNeverExpire,
            onSelected: (value) async {
              setState(() => _lyricsTtlDays = value);
              await _service.setLyricsTtlDays(value);
            },
          ),
        ),
        SettingsNavTile(
          key: const Key('cacheClearLyricsItem'),
          icon: Icons.delete_outline_rounded,
          title: l10n.cacheClearPartition,
          subtitle: _usageText(l10n, CachePartition.lyrics),
          isDestructive: true,
          onTap: _busy ? null : () => _clear(CachePartition.lyrics),
        ),
      ],
    );
  }

  Widget _buildArtworkSection(AppLocalizations l10n) {
    return SettingsSectionCard(
      title: l10n.cachePartitionArtwork,
      children: [
        SettingsValueTile(
          icon: Icons.image_rounded,
          title: l10n.cachePolicyArtworkMax,
          value: _artworkMaxObjects <= 0
              ? l10n.cacheUnlimited
              : l10n.cacheValueItems(_artworkMaxObjects),
          onTap: () => _promptPolicyValue(
            title: l10n.cachePolicyArtworkMax,
            current: _artworkMaxObjects,
            min: _artworkMaxMin,
            max: _artworkMaxMax,
            unitLabel: l10n.cacheUnitItems,
            zeroLabel: l10n.cacheUnlimited,
            onSelected: (value) async {
              setState(() => _artworkMaxObjects = value);
              await _service.setArtworkMaxObjects(value);
            },
          ),
        ),
        SettingsValueTile(
          icon: Icons.update_rounded,
          title: l10n.cachePolicyArtworkStale,
          value: _artworkStaleDays <= 0
              ? l10n.cacheNeverExpire
              : l10n.cacheValueDays(_artworkStaleDays),
          onTap: () => _promptPolicyValue(
            title: l10n.cachePolicyArtworkStale,
            current: _artworkStaleDays,
            min: _daysMin,
            max: _daysMax,
            unitLabel: l10n.cacheUnitDays,
            zeroLabel: l10n.cacheNeverExpire,
            onSelected: (value) async {
              setState(() => _artworkStaleDays = value);
              await _service.setArtworkStaleDays(value);
            },
          ),
        ),
        SettingsNavTile(
          key: const Key('cacheClearArtworkItem'),
          icon: Icons.delete_outline_rounded,
          title: l10n.cacheClearPartition,
          subtitle: _usageText(l10n, CachePartition.artwork),
          isDestructive: true,
          onTap: _busy ? null : () => _clear(CachePartition.artwork),
        ),
      ],
    );
  }

  /// 分区用量文案（未就绪时显示计算中）。
  String _usageText(AppLocalizations l10n, CachePartition partition) {
    final usage = _usage[partition];
    if (usage == null) return l10n.cacheUsageComputing;
    return l10n.cacheUsage(_formatSize(usage.bytes), usage.count);
  }

  /// 策略数值显示：0 = 不限制 / 永不过期；整 GB 显示为 GB（1024 → 1 GB）。
  String _policyValueLabel(AppLocalizations l10n, int value) {
    if (value <= 0) return l10n.cacheUnlimited;
    if (value % 1024 == 0) return l10n.cacheValueGb(value ~/ 1024);
    return l10n.cacheValueMb(value);
  }

  /// 自定义数值弹层：仅数字输入，0 或 [min, max] 内的整数才可保存。
  ///
  /// 0 沿用 [CacheService] 语义（不限制 / 永不过期）；越界时显示范围
  /// 错误并置灰保存。确认后由调用方写回策略并触发即时生效。
  /// [presets] / [suggestedMb] 用于大范围绝对量（音频上限）的快捷选择与
  /// 设备容量建议提示。
  Future<void> _promptPolicyValue({
    required String title,
    required int current,
    required int min,
    required int max,
    required String unitLabel,
    required String zeroLabel,
    List<int>? presets,
    int? suggestedMb,
    required ValueChanged<int> onSelected,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final initialText = '$current';
    final controller = TextEditingController(text: initialText)
      // 全选当前值：直接输入即替换，省去先删再填。
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: initialText.length,
      );
    final result = await M3EDialog.show<int>(
      context,
      dialog: StatefulBuilder(
        builder: (context, setState) {
          final parsed = int.tryParse(controller.text.trim());
          final valid = parsed != null &&
              (parsed == 0 || (parsed >= min && parsed <= max));
          return M3EDialog(
            title: title,
            content: SizedBox(
              width: 320,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (suggestedMb != null) ...[
                    Text(
                      l10n.cacheAudioMaxSuggested(
                        _policyValueLabel(l10n, suggestedMb),
                      ),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (presets != null) ...[
                    Wrap(
                      spacing: 8,
                      // 换行后行距不能为 0：chips 贴边会被看成叠在一起。
                      runSpacing: 8,
                      children: [
                        for (final preset in presets)
                          M3EChip(
                            type: M3EChipType.filter,
                            label: _policyValueLabel(l10n, preset),
                            selected: parsed == preset,
                            onPressed: () {
                              controller.text = '$preset';
                              controller.selection = TextSelection.collapsed(
                                offset: controller.text.length,
                              );
                              setState(() {});
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  M3ETextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    suffixText: unitLabel,
                    supportingText: l10n.cacheCustomHint(zeroLabel, min, max),
                    errorText: controller.text.isNotEmpty && !valid
                        ? l10n.cacheCustomRangeError(min, max)
                        : null,
                    onChanged: (_) => setState(() {}),
                    onSubmitted:
                        valid ? (_) => Navigator.pop(context, parsed) : null,
                  ),
                ],
              ),
            ),
            actions: [
              M3EButton.text(
                onPressed: () => Navigator.pop(context),
                child: Text(l10n.cancel),
              ),
              M3EButton.filled(
                onPressed:
                    valid ? () => Navigator.pop(context, parsed) : null,
                child: Text(l10n.saveChanges),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (result == null || !mounted) return;
    onSelected(result);
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}
