/// 来源行弹层：曲目身份相关的复制 / 分享动作。
///
/// 四项动作（按可得性显隐 / 禁用）：
/// - 复制曲目 ID（`{sourceKey}:{id}`）；
/// - 分享平台页面（内置五平台可构造 URL，脚本源 / 本地曲目没有）；
/// - 打开平台页面（系统浏览器 / 外部应用）；
/// - 分享歌曲文件（已下载直接分享；未下载则先下载再分享）。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/models/download.dart';
import '../domain/models/failure.dart';
import '../domain/models/track.dart';
import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import '../services/download/download_service.dart';
import '../utils/download_failure_label.dart';
import '../utils/responsive.dart';
import 'track_actions.dart';

/// 打开来源行弹层（歌曲信息页「来源」行唯一入口）。
Future<void> showTrackShareSheet(
  BuildContext context, {
  required Track track,
}) {
  return ResponsiveNavigation.showAdaptiveModalPage<void>(
    context: context,
    title: AppLocalizations.of(context)!.trackInfoSource,
    child: _TrackShareSheet(track: track),
  );
}

class _TrackShareSheet extends StatelessWidget {
  const _TrackShareSheet({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final notifications = context.read<NotificationService?>();
    final downloads = context.read<DownloadService?>();
    final pageUrl = platformTrackPageUrl(track);
    final record = downloads?.recordForTrack(track);
    final trackIdLabel =
        track.id.uri.isEmpty ? l10n.trackInfoSourceUnknownId : track.id.uri;

    void message(String text) {
      if (notifications != null) {
        notifications.showSnackBar(text);
      } else {
        M3ESnackbar.show(context, message: text);
      }
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
            child: Text(
              trackIdLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          M3EListItem(
            leading: const Icon(Icons.tag_rounded),
            headline: l10n.trackInfoTrackId,
            onTap: () {
              unawaited(Clipboard.setData(ClipboardData(text: track.id.uri)));
              message(l10n.trackInfoIdCopied);
              Navigator.of(context).pop();
            },
          ),
          M3EListItem(
            leading: const Icon(Icons.link_rounded),
            headline: l10n.sharePlatformPage,
            supportingText:
                pageUrl == null ? l10n.platformPageUnavailable : null,
            enabled: pageUrl != null,
            onTap: pageUrl == null
                ? null
                : () {
                    Navigator.of(context).pop();
                    unawaited(_shareText(context, pageUrl, message));
                  },
          ),
          M3EListItem(
            leading: const Icon(Icons.open_in_new_rounded),
            headline: l10n.openPlatformPage,
            enabled: pageUrl != null,
            onTap: pageUrl == null
                ? null
                : () {
                    Navigator.of(context).pop();
                    unawaited(
                      launchUrl(
                        Uri.parse(pageUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                    );
                  },
          ),
          M3EListItem(
            leading: const Icon(Icons.ios_share_rounded),
            headline: record != null ? l10n.shareTrackFile : l10n.downloadAndShare,
            onTap: () {
              Navigator.of(context).pop();
              unawaited(
                _shareTrackFile(
                  context,
                  record: record,
                  downloads: downloads,
                  message: message,
                ),
              );
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Future<void> _shareText(
    BuildContext context,
    String text,
    void Function(String) message,
  ) async {
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (_) {
      if (context.mounted) message(AppLocalizations.of(context)!.exportFailed);
    }
  }

  /// 分享歌曲文件：已有下载记录直接分享；未下载先按偏好音质下载再分享。
  Future<void> _shareTrackFile(
    BuildContext context, {
    required DownloadedTrack? record,
    required DownloadService? downloads,
    required void Function(String) message,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    var target = record;
    if (target == null) {
      if (downloads == null || !downloads.supported) {
        message(l10n.downloadUnsupported);
        return;
      }
      message(l10n.shareDownloading);
      try {
        await downloads.download(track);
      } on SourceFailure catch (failure) {
        if (failure.kind == FailureKind.cancelled) return;
        message(downloadFailureLabel(l10n, failure));
        return;
      } catch (e) {
        message(l10n.downloadFailed(e.toString()));
        return;
      }
      target = downloads.recordForTrack(track);
      if (target == null) {
        message(l10n.downloadFailed(''));
        return;
      }
    }
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(target.filePath)]),
      );
    } catch (_) {
      message(l10n.exportFailed);
    }
  }
}
