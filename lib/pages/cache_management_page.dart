import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/cache_service.dart';
import '../services/notification_service.dart';

/// 缓存管理页：音频 / 歌词 / 封面三分区的占用、策略与清理。
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

  Future<void> _clear(CachePartition partition) async {
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
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.cacheClearAll,
        content: Text(l10n.cacheClearAllConfirm),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
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
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settingsCacheTitle),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(
              l10n.settingsCacheSubtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            _buildAudioCard(l10n),
            const SizedBox(height: 16),
            _buildLyricsCard(l10n),
            const SizedBox(height: 16),
            _buildArtworkCard(l10n),
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

  Widget _buildAudioCard(AppLocalizations l10n) {
    return _partitionCard(
      partition: CachePartition.audio,
      icon: Icons.audiotrack_rounded,
      title: l10n.cachePartitionAudio,
      l10n: l10n,
      children: [
        _switchRow(
          title: l10n.cachePolicyAudioEnabled,
          value: _audioEnabled,
          onChanged: (value) async {
            setState(() => _audioEnabled = value);
            await _service.setAudioEnabled(value);
          },
        ),
        _policyRow(
          title: l10n.cachePolicyAudioMax,
          value: _audioMaxMb <= 0
              ? l10n.cacheUnlimited
              : l10n.cacheValueMb(_audioMaxMb),
          current: _audioMaxMb,
          min: _audioMaxMinMb,
          max: _audioMaxMaxMb,
          unitLabel: l10n.cacheUnitMb,
          zeroLabel: l10n.cacheUnlimited,
          onSelected: (value) async {
            setState(() => _audioMaxMb = value);
            await _service.setAudioMaxMb(value);
          },
        ),
      ],
    );
  }

  Widget _buildLyricsCard(AppLocalizations l10n) {
    return _partitionCard(
      partition: CachePartition.lyrics,
      icon: Icons.lyrics_rounded,
      title: l10n.cachePartitionLyrics,
      l10n: l10n,
      children: [
        _policyRow(
          title: l10n.cachePolicyLyricsTtl,
          value: _lyricsTtlDays <= 0
              ? l10n.cacheNeverExpire
              : l10n.cacheValueDays(_lyricsTtlDays),
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
      ],
    );
  }

  Widget _buildArtworkCard(AppLocalizations l10n) {
    return _partitionCard(
      partition: CachePartition.artwork,
      icon: Icons.image_rounded,
      title: l10n.cachePartitionArtwork,
      l10n: l10n,
      children: [
        _policyRow(
          title: l10n.cachePolicyArtworkMax,
          value: _artworkMaxObjects <= 0
              ? l10n.cacheUnlimited
              : l10n.cacheValueItems(_artworkMaxObjects),
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
        _policyRow(
          title: l10n.cachePolicyArtworkStale,
          value: _artworkStaleDays <= 0
              ? l10n.cacheNeverExpire
              : l10n.cacheValueDays(_artworkStaleDays),
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
      ],
    );
  }

  /// 分区卡片：标题 + 用量 + 单清按钮 + 策略行。
  Widget _partitionCard({
    required CachePartition partition,
    required IconData icon,
    required String title,
    required AppLocalizations l10n,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final usage = _usage[partition];
    return M3ECard(
      variant: M3ECardVariant.filled,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: scheme.onSecondaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        usage == null
                            ? l10n.cacheUsageComputing
                            : l10n.cacheUsage(
                                _formatSize(usage.bytes), usage.count),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                M3EIconButton(
                  variant: M3EIconButtonVariant.standard,
                  tooltip: l10n.cacheClearPartition,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: _busy ? null : () => _clear(partition),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _switchRow({
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(title)),
          M3ESwitch(value: value, onChanged: onChanged),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// 数值策略行：整行可点，点击弹出数字输入弹层（0 = 不限制 / 永不过期）。
  Widget _policyRow({
    required String title,
    required String value,
    required int current,
    required int min,
    required int max,
    required String unitLabel,
    required String zeroLabel,
    required ValueChanged<int> onSelected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _promptPolicyValue(
        title: title,
        current: current,
        min: min,
        max: max,
        unitLabel: unitLabel,
        zeroLabel: zeroLabel,
        onSelected: onSelected,
      ),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Expanded(child: Text(title)),
            Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    // 当前值是信息文本，不用强调色。
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.edit_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  /// 自定义数值弹层：仅数字输入，0 或 [min, max] 内的整数才可保存。
  ///
  /// 0 沿用 [CacheService] 语义（不限制 / 永不过期）；越界时显示范围
  /// 错误并置灰保存。确认后由调用方写回策略并触发即时生效。
  Future<void> _promptPolicyValue({
    required String title,
    required int current,
    required int min,
    required int max,
    required String unitLabel,
    required String zeroLabel,
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
              child: M3ETextField(
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
