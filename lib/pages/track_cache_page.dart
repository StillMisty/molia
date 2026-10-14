/// 单曲缓存子页：当前曲目的四项缓存占用与逐项清理。
///
/// 为什么独立成页（而不是歌曲信息页上的四个一点即清的行）：
/// - 清理是低频且不可撤销的操作，页面本身是一道「刻意进入」的闸门，
///   避免信息页误触；页内逐项清理再各带一次确认；
/// - 音频分项在桌面 / Web 平台不可用（[platformSupportsAudioCaching]），
///   如实说明而不是显示「无缓存」。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../services/audio_cache_platform.dart';
import '../services/cache_service.dart';
import '../services/track_cache_service.dart';
import '../utils/responsive.dart';
import '../utils/track_cache_label.dart';
import '../widgets/settings/settings_tiles.dart';

/// 打开单曲缓存子页（歌曲信息页「缓存」行唯一入口）。
Future<void> showTrackCachePage(
  BuildContext context, {
  required Track track,
}) {
  return ResponsiveNavigation.showSecondaryPage<void>(
    context: context,
    child: TrackCachePage(track: track),
    preferredMode: SecondaryPageMode.sideSheet,
    maxWidth: 520,
    showCloseButton: false,
  );
}

@visibleForTesting
class TrackCachePage extends StatefulWidget {
  const TrackCachePage({super.key, required this.track});

  final Track track;

  @override
  State<TrackCachePage> createState() => _TrackCachePageState();
}

class _TrackCachePageState extends State<TrackCachePage> {
  static const List<TrackCachePart> _parts = TrackCachePart.values;

  TrackCacheService? _service;
  CacheService? _cacheService;
  TrackCacheUsage? _usage;
  bool _busy = false;

  /// 音频缓存开关（关闭时音频行给出状态说明）。
  bool _audioEnabled = true;

  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _service = context.read<TrackCacheService?>();
    _cacheService = context.read<CacheService?>() ?? CacheService.instance;
    if (!_listening) {
      _listening = true;
      _cacheService?.revision.addListener(_onCacheChanged);
      unawaited(_reload());
    }
  }

  @override
  void dispose() {
    if (_listening) {
      _cacheService?.revision.removeListener(_onCacheChanged);
    }
    super.dispose();
  }

  void _onCacheChanged() {
    if (!mounted) return;
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final service = _service;
    if (service == null) return;
    try {
      final results = await Future.wait([
        service.usage(widget.track),
        _cacheService?.audioEnabled() ?? Future.value(true),
      ]);
      if (!mounted) return;
      setState(() {
        _usage = results[0] as TrackCacheUsage;
        _audioEnabled = results[1] as bool;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _usage = const TrackCacheUsage());
    }
  }

  Future<void> _clear(TrackCachePart part) async {
    final service = _service;
    if (service == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.trackCacheClearConfirm(trackCachePartLabel(l10n, part)),
        content: Text(l10n.trackCacheClearHint),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      final result = await service.clear(widget.track, part);
      if (!mounted) return;
      _showMessage(trackCacheClearResultLabel(l10n, result));
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll() async {
    final service = _service;
    if (service == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await M3EDialog.show<bool>(
      context,
      dialog: M3EDialog(
        title: l10n.trackCacheClearAll,
        content: Text(l10n.trackCacheClearAllConfirm),
        actions: [
          M3EButton.text(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          M3EButton.filled(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    HapticFeedback.lightImpact();
    setState(() => _busy = true);
    try {
      for (final part in _parts) {
        await service.clear(widget.track, part);
      }
      if (!mounted) return;
      _showMessage(l10n.trackCacheClearAll);
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    final notifications = context.read<NotificationService?>();
    if (notifications != null) {
      notifications.showSnackBar(message);
    } else {
      M3ESnackbar.show(context, message: message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final usage = _usage;
    return Scaffold(
      appBar: M3EAppBar.top(
        title: Text(l10n.trackCachePageTitle),
        automaticallyImplyLeading: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(kSettingsPadding),
        children: [
          SettingsSectionCard(
            children: [
              SettingsInfoTile(
                icon: Icons.music_note_rounded,
                title: widget.track.title,
                subtitle: widget.track.artists
                    .map((artist) => artist.name)
                    .where((name) => name.isNotEmpty)
                    .join(', '),
              ),
            ],
          ),
          const SizedBox(height: kSettingsSectionSpacing),
          SettingsSectionCard(
            children: [
              for (final part in _parts)
                M3EListItem(
                  key: Key('trackCachePart_${part.name}'),
                  leading: Icon(_partIcon(part)),
                  headline: trackCachePartLabel(l10n, part),
                  supportingText: _partSubtitle(l10n, part, usage),
                  trailing: M3EButton.text(
                    onPressed: usage == null || _busy || !_partHasCache(part, usage)
                        ? null
                        : () => unawaited(_clear(part)),
                    child: Text(l10n.downloadPartRemove),
                  ),
                ),
            ],
          ),
          if (usage != null && !usage.hasAny)
            Padding(
              padding: const EdgeInsets.only(top: kSettingsSectionSpacing),
              child: Text(
                l10n.trackCacheEmpty,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          const SizedBox(height: kSettingsSectionSpacing),
          M3EButton.tonal(
            onPressed:
                usage == null || _busy || !usage.hasAny ? null : _clearAll,
            child: Text(l10n.trackCacheClearAll),
          ),
        ],
      ),
    );
  }

  bool _partHasCache(TrackCachePart part, TrackCacheUsage usage) =>
      switch (part) {
        TrackCachePart.audio => usage.audio.count > 0,
        TrackCachePart.lyrics => usage.lyrics.count > 0,
        TrackCachePart.artwork => usage.artwork.count > 0,
        TrackCachePart.resolveUrl => usage.resolveEntries > 0,
      };

  /// 单项副标题：未就绪「统计中」；音频分项按平台 / 开关如实说明。
  String _partSubtitle(
    AppLocalizations l10n,
    TrackCachePart part,
    TrackCacheUsage? usage,
  ) {
    if (usage == null) return l10n.cacheUsageComputing;
    final label = trackCacheUsageLabel(l10n, part, usage);
    if (part != TrackCachePart.audio) return label;
    if (!platformSupportsAudioCaching()) {
      return l10n.cacheAudioPlatformUnsupported;
    }
    if (!_audioEnabled) return l10n.cacheAudioDisabled;
    return label;
  }

  static IconData _partIcon(TrackCachePart part) => switch (part) {
        TrackCachePart.audio => Icons.audiotrack_rounded,
        TrackCachePart.lyrics => Icons.lyrics_rounded,
        TrackCachePart.artwork => Icons.image_rounded,
        TrackCachePart.resolveUrl => Icons.link_rounded,
      };
}
