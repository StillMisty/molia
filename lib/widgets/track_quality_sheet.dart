import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../providers/playback_provider.dart';
import '../services/haptics.dart';
import '../utils/responsive.dart';
import '../utils/source_quality_label.dart';
import 'detail_page/detail_page_chrome.dart';
import 'simple_modal_body.dart';

/// 可用音质弹层：列出曲目全部档位（本地化名 + 统一体积），当前档位选中。
///
/// 选择即切换本次播放音质（重新取链、保持进度与播放态）；恢复态没有真实
/// 播放，入口本身不开放，这里再兜底一次。
Future<void> showTrackQualitySheet(
  BuildContext context, {
  required Track track,
  required String currentQuality,
}) {
  final playback = context.read<PlaybackProvider>();
  if (playback.hasRestoredSession) return Future.value();
  final options = sortedQualityOptions(track.qualities);
  if (options.isEmpty) return Future.value();
  final l10n = AppLocalizations.of(context)!;
  return ResponsiveNavigation.showSimpleModal<void>(
    context: context,
    title: l10n.trackInfoQualityAvailable,
    child: _TrackQualitySheet(
      track: track,
      playback: playback,
      options: options,
      currentQuality: currentQuality,
      l10n: l10n,
    ),
  );
}

class _TrackQualitySheet extends StatelessWidget {
  const _TrackQualitySheet({
    required this.track,
    required this.playback,
    required this.options,
    required this.currentQuality,
    required this.l10n,
  });

  final Track track;
  final PlaybackProvider playback;
  final List<AudioQuality> options;
  final String currentQuality;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return SimpleModalBody(
      header: DetailPageTrackHeader(
        track: track,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      ),
      children: [
        for (final option in options)
          M3EListItem(
            key: Key('trackInfoQualityOption_${option.type}'),
            leading: Icon(
              option.type == currentQuality
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
            ),
            headline: sourceQualityLabel(l10n, option.type),
            trailingText: formatQualitySize(option.size),
            selected: option.type == currentQuality,
            onTap: () => _select(context, option.type),
          ),
      ],
    );
  }

  void _select(BuildContext context, String quality) {
    if (quality == currentQuality) {
      Navigator.of(context).pop();
      return;
    }
    HapticsService.lightImpact();
    Navigator.of(context).pop();
    // 切换在后台完成：行内先显示所选档位，取链失败走现有播放错误链路。
    unawaited(playback.setCurrentQuality(quality));
  }
}
