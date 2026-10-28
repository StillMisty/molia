/// 省流模式下载确认：本地数据页 / 下载管理批量 / 来源行「下载并分享」共用。
///
/// 为什么独立成 widget 文件：确认弹层要挂 **root navigator**（`M3EDialog.show`
/// 语义）——设置页与本地数据页都在内层 Navigator 里，页面 context 上的 pop
/// 会误退页面而不是关闭弹窗。把「省流是否生效 + 定向关闭」收在一处，三个
/// 入口不再各写一份弹层与 pop 目标。
library;

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../services/data_saver_service.dart';

/// 省流生效时弹确认；继续返回 true，取消 / 未生效返回 false（未生效直接放行）。
Future<bool> confirmDownloadOnDataSaver(BuildContext context) async {
  final dataSaver = context.read<DataSaverService?>();
  if (!(dataSaver?.active ?? false)) return true;
  final l10n = AppLocalizations.of(context)!;
  final navigator = Navigator.of(context, rootNavigator: true);
  final confirmed = await M3EDialog.show<bool>(
    context,
    dialog: M3EDialog(
      title: l10n.downloadDataSaverTitle,
      content: Text(l10n.downloadDataSaverConfirm),
      actions: [
        M3EButton.text(
          onPressed: () => navigator.pop(false),
          child: Text(l10n.cancel),
        ),
        M3EButton.filled(
          onPressed: () => navigator.pop(true),
          child: Text(l10n.downloadContinue),
        ),
      ],
    ),
  );
  return confirmed == true;
}
