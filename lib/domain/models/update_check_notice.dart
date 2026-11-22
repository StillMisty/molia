/// 自动检查发现更新后的弹窗数据（应用 + 音源合并成一条）。
library;

import 'app_release.dart';
import 'source_script.dart';

class UpdateCheckNotice {
  const UpdateCheckNotice({this.appRelease, this.sourceUpdates = const []});

  /// 有新版本的应用发布；null 表示应用无更新或检查失败。
  final AppRelease? appRelease;

  /// 有更新的音源脚本（可能为空）。
  final List<SourceScriptUpdate> sourceUpdates;

  bool get isEmpty => appRelease == null && sourceUpdates.isEmpty;

  bool get hasAppUpdate => appRelease != null;

  bool get hasSourceUpdates => sourceUpdates.isNotEmpty;
}
