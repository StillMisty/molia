/// 附近设备一键配对的发起方 / 接收方弹层。
///
/// 与 `sync_peer_dialogs.dart` 分开：那边是设备详情 / 地址清单 / 手动地址，
/// 这里只服务 `MSP/1` 发现 + `/pair/*` 请求 + 6 位确认码。旧配对码（复制 /
/// 粘贴 / 二维码）路径已整体删除，不在这里保留任何兼容入口。
library;

import 'dart:async';

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';

import '../domain/models/sync_nearby_pairing.dart';
import '../l10n/app_localizations.dart';
import '../providers/sync_provider.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/device_id.dart';
import '../widgets/settings/settings_tiles.dart';
import 'sync_notices.dart';

/// 确认码展示格式：`482193` → `482 193`（分两组便于口述核对）。
String formatSyncPairingCode(String code) {
  final digits = code.replaceAll(RegExp(r'\s+'), '');
  if (digits.length != 6) return digits;
  return '${digits.substring(0, 3)} ${digits.substring(3)}';
}

String _nearbyDisplayName(String name, String deviceId) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? shortDeviceId(deviceId) : trimmed;
}

/// 发起方弹层：点附近设备后立即打开，等待期间显示确认码。
///
/// 结果在弹层内直接用底栏提示收口：成功 = 已加入 / 已在同一组并跑一轮；
/// 失败 = 一句原因 + 下一步（不展示协议细节，也不指向已删除的配对码入口）。
Future<void> showSyncNearbyPairingDialog(
  BuildContext context, {
  required SyncProvider provider,
  required SyncNearbyDevice device,
}) {
  final key = GlobalKey<_NearbyPairingDialogState>();
  return M3EDialog.show<void>(
    context,
    // 关闭只走「取消」：点空白误关会让后台配对请求继续占着唯一的发起方槽位。
    barrierDismissible: false,
    // 返回键 / Esc 同样不能静默关窗：等待期间必须由用户显式取消，流程收口
    // （成功 / 失败已提示）后才允许关闭。
    onDismissRequest: () async => key.currentState?.dismissible ?? false,
    dialog: _NearbyPairingDialog(
      key: key,
      provider: provider,
      device: device,
    ),
  );
}

class _NearbyPairingDialog extends StatefulWidget {
  const _NearbyPairingDialog({
    super.key,
    required this.provider,
    required this.device,
  });

  final SyncProvider provider;
  final SyncNearbyDevice device;

  @override
  State<_NearbyPairingDialog> createState() => _NearbyPairingDialogState();
}

class _NearbyPairingDialogState extends State<_NearbyPairingDialog> {
  StreamSubscription<SyncPairingAttempt>? _attempts;

  /// 用户在确认码到达前取消：弹层已关，但请求 id 还没从 attempts 里拿到。
  /// 这条独立订阅等 id 到达后替用户取消，避免后台继续占用唯一的发起方槽位。
  StreamSubscription<SyncPairingAttempt>? _pendingCancel;

  /// `_pendingCancel` 已移交给关闭后的流收口：dispose 不能再取消它，否则
  /// 用户取消前没拿到 id 的请求会一直挂在后台。
  bool _pendingCancelHandedOff = false;

  String? _requestId;
  String _code = '';
  bool _finished = false;
  bool _disposed = false;

  String get _peerName =>
      _nearbyDisplayName(widget.device.name, widget.device.deviceId);

  /// 返回键 / Esc 是否允许关窗：只有流程已经收口（即将自动关闭）时才允许。
  bool get dismissible => _finished;

  @override
  void initState() {
    super.initState();
    _attempts = widget.provider.pairingAttempts.listen(_onAttempt);
    unawaited(_start());
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_attempts?.cancel());
    _attempts = null;
    // 一般路径下取消订阅；只有「关窗后等 requestId 再取消」的移交订阅
    // 例外——它必须活到 id 到达（回调自己取消），否则后台请求会继续占用
    // 发起方槽位。
    if (!_pendingCancelHandedOff) {
      unawaited(_pendingCancel?.cancel());
      _pendingCancel = null;
    }
    super.dispose();
  }

  Future<void> _start() async {
    SyncPairingResult result;
    try {
      result = await widget.provider.requestPairing(widget.device);
    } catch (_) {
      // 配对是可选子系统：请求抛异常也要给用户一个结论并收口弹层，
      // 不能停在「正在联系对方」让后台请求悬着。
      result = const SyncPairingResult(outcome: SyncPairingOutcome.unavailable);
    }
    unawaited(_pendingCancel?.cancel());
    _pendingCancel = null;
    _pendingCancelHandedOff = false;
    if (_finished || _disposed || !mounted) return;
    _finished = true;
    final l10n = AppLocalizations.of(context)!;
    final message = _resultMessage(l10n, result.outcome);
    showSyncNoticeAndClose(context, message);
    if (result.isSuccess) {
      unawaited(widget.provider.syncNow(manual: true));
    }
  }

  void _onAttempt(SyncPairingAttempt attempt) {
    if (attempt.peerDeviceId != widget.device.deviceId) return;
    if (attempt.status != SyncPairingStatus.pending) return;
    if (_requestId != null && attempt.requestId != _requestId) return;
    if (_finished || _disposed || !mounted) return;
    setState(() {
      _requestId = attempt.requestId;
      _code = attempt.code;
    });
  }

  Future<void> _cancel() async {
    if (_finished) return;
    _finished = true;
    final id = _requestId;
    if (id != null) {
      await widget.provider.cancelPairing(id);
    } else {
      _pendingCancel =
          widget.provider.pairingAttempts.listen(_cancelWhenIdArrives);
      // 弹层马上关闭；把这条订阅移交给流收口，dispose 不再取消它。
      _pendingCancelHandedOff = true;
    }
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showSyncNoticeAndClose(context, l10n.syncNearbyResultCancelled);
  }

  void _cancelWhenIdArrives(SyncPairingAttempt attempt) {
    if (attempt.peerDeviceId != widget.device.deviceId) return;
    if (attempt.status != SyncPairingStatus.pending) return;
    unawaited(widget.provider.cancelPairing(attempt.requestId));
    unawaited(_pendingCancel?.cancel());
    _pendingCancel = null;
    _pendingCancelHandedOff = false;
  }

  static String _resultMessage(
    AppLocalizations l10n,
    SyncPairingOutcome outcome,
  ) =>
      switch (outcome) {
        SyncPairingOutcome.accepted => l10n.syncNearbyJoined,
        SyncPairingOutcome.sameGroup => l10n.syncNearbySameGroup,
        SyncPairingOutcome.rejected => l10n.syncNearbyResultRejected,
        SyncPairingOutcome.expired => l10n.syncNearbyResultExpired,
        SyncPairingOutcome.conflict => l10n.syncNearbyResultConflict,
        SyncPairingOutcome.unreachable => l10n.syncNearbyResultUnreachable,
        SyncPairingOutcome.busy => l10n.syncNearbyResultBusy,
        SyncPairingOutcome.unsupported => l10n.syncNearbyResultUnsupported,
        SyncPairingOutcome.unavailable => l10n.syncNearbyResultUnavailable,
        SyncPairingOutcome.cancelled => l10n.syncNearbyResultCancelled,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final groupedCode = formatSyncPairingCode(_code);
    return M3EDialog(
      title: l10n.syncNearbyPairTitle(_peerName),
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_code.isEmpty) ...[
              const Center(child: M3EProgressIndicator.circular()),
              const SizedBox(height: kSettingsElementSpacing),
              Text(
                l10n.syncNearbyContacting,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ] else ...[
              Text(
                l10n.syncNearbyCodeLabel,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: kSettingsSmallSpacing),
              Text(
                groupedCode,
                textAlign: TextAlign.center,
                semanticsLabel: groupedCode,
                style: theme.textTheme.displaySmall?.copyWith(
                  letterSpacing: 4,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: kSettingsElementSpacing),
              Text(
                l10n.syncNearbyWaiting,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: kSettingsSmallSpacing),
              Text(
                l10n.syncNearbyCheckCode,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: _finished ? null : () => unawaited(_cancel()),
          child: Text(l10n.cancelButton),
        ),
      ],
    );
  }
}

/// 接收方弹层：应用壳在任意页面收到请求时弹出。
///
/// 同一时间只展示服务推送的一条请求；拒绝 / 接受都会 await
/// [SyncProvider.respondPairing]（invite 接受要等发起方完成，约 5 秒），
/// 等待期间按钮禁用，避免重复提交或提前关窗。
Future<void> showSyncIncomingPairingDialog(
  BuildContext hostContext, {
  required SyncProvider provider,
  required SyncPairingRequest request,
}) async {
  final l10n = AppLocalizations.of(hostContext);
  if (l10n == null) {
    // 没有本地化 / 宿主 context 也必须给发起方一个结论，不能悬着。
    await provider.respondPairing(request.requestId, accept: false);
    return;
  }
  await M3EDialog.show<void>(
    hostContext,
    // 这是一次授权决定：点空白 / 返回键都不应静默忽略，必须明确拒绝或接受。
    barrierDismissible: false,
    onDismissRequest: () async => false,
    dialog: _IncomingPairingDialog(
      provider: provider,
      request: request,
      l10n: l10n,
    ),
  );
}

class _IncomingPairingDialog extends StatefulWidget {
  const _IncomingPairingDialog({
    required this.provider,
    required this.request,
    required this.l10n,
  });

  final SyncProvider provider;
  final SyncPairingRequest request;
  final AppLocalizations l10n;

  @override
  State<_IncomingPairingDialog> createState() => _IncomingPairingDialogState();
}

class _IncomingPairingDialogState extends State<_IncomingPairingDialog> {
  Timer? _expiry;
  bool _busy = false;
  bool _accepting = false;
  bool _finished = false;

  SyncPairingRequest get _request => widget.request;

  String get _peerName =>
      _nearbyDisplayName(_request.peerName, _request.peerDeviceId);

  @override
  void initState() {
    super.initState();
    final remaining = _request.expiresAt - widget.provider.nowMs;
    _expiry = Timer(
      Duration(milliseconds: remaining > 0 ? remaining : 0),
      () => unawaited(_onExpired()),
    );
  }

  @override
  void dispose() {
    _expiry?.cancel();
    super.dispose();
  }

  Future<void> _onExpired() async {
    if (_finished || _busy || !mounted) return;
    _finished = true;
    // 本地计时器与服务 sweep 有毫秒级偏差：本地先到也要主动拒绝一次，
    // 释放服务里的 active prompt（对已过期条目是幂等的），否则服务端可能
    // 仍占着唯一的待确认槽位，后续请求要等它自己的定时器才推进。
    try {
      await widget.provider.respondPairing(_request.requestId, accept: false);
    } catch (_) {
      // 过期收口不因服务异常卡住弹层。
    }
    if (!mounted) return;
    showSyncNoticeAndClose(context, widget.l10n.syncNearbyIncomingExpired);
  }

  Future<void> _respond({required bool accept}) async {
    if (_busy || _finished) return;
    setState(() {
      _busy = true;
      _accepting = accept;
    });
    SyncPairingOutcome outcome;
    try {
      outcome = await widget.provider.respondPairing(
        _request.requestId,
        accept: accept,
      );
    } catch (_) {
      // 配对是可选子系统：失败只给一句结论，不让异常穿到应用壳。
      outcome = SyncPairingOutcome.unavailable;
    }
    if (!mounted || _finished) return;
    _finished = true;
    _expiry?.cancel();
    final l10n = widget.l10n;
    final message = switch (outcome) {
      SyncPairingOutcome.accepted => l10n.syncNearbyJoined,
      SyncPairingOutcome.sameGroup => l10n.syncNearbySameGroup,
      SyncPairingOutcome.rejected => l10n.syncNearbyIncomingRejected,
      SyncPairingOutcome.expired => l10n.syncNearbyIncomingExpired,
      SyncPairingOutcome.unavailable
          when accept && _request.intent == SyncPairingIntent.invite =>
        l10n.syncNearbyIncomingNotCompleted,
      _ => l10n.syncNearbyIncomingFailed,
    };
    showSyncNoticeAndClose(context, message);
    if (outcome == SyncPairingOutcome.accepted ||
        outcome == SyncPairingOutcome.sameGroup) {
      unawaited(widget.provider.syncNow(manual: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    final theme = Theme.of(context);
    final groupedCode = formatSyncPairingCode(_request.code);
    final invitation = _request.intent == SyncPairingIntent.invite;
    return M3EDialog(
      title: invitation
          ? l10n.syncNearbyIncomingInviteTitle(_peerName)
          : l10n.syncNearbyIncomingJoinTitle(_peerName),
      content: SizedBox(
        width: settingsDialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.syncNearbyCodeLabel,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: kSettingsSmallSpacing),
            Text(
              groupedCode,
              textAlign: TextAlign.center,
              semanticsLabel: groupedCode,
              style: theme.textTheme.displaySmall?.copyWith(
                letterSpacing: 4,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: kSettingsElementSpacing),
            Text(
              invitation
                  ? l10n.syncNearbyIncomingInviteWarning
                  : l10n.syncNearbyIncomingJoinWarning,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppSemanticColors.of(context).warning,
              ),
            ),
          ],
        ),
      ),
      actions: [
        M3EButton.text(
          onPressed: _busy ? null : () => unawaited(_respond(accept: false)),
          child: Text(l10n.syncNearbyReject),
        ),
        M3EButton.filled(
          onPressed: _busy ? null : () => unawaited(_respond(accept: true)),
          child: _busy && _accepting
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const M3EProgressIndicator.circular(
                      size: 16,
                      strokeWidth: 2,
                    ),
                    const SizedBox(width: 8),
                    Text(l10n.syncNearbyAccept),
                  ],
                )
              : Text(l10n.syncNearbyAccept),
        ),
      ],
    );
  }
}
