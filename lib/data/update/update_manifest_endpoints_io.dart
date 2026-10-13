import '../../domain/models/app_release.dart';
import 'update_repository.dart';

/// 原生端默认清单地址。
///
/// - 稳定版：`releases/latest/download/...`（GitHub 的 latest 排除 prerelease）；
/// - 测试版：发布流水线维护的滚动标签 `beta`。
///
/// 走 Release 资产而不是 GitHub API：匿名 API 限流 60 次/小时/IP。
Uri defaultUpdateManifestUri(UpdateChannel channel) => Uri.parse(
      channel == UpdateChannel.beta
          ? 'https://github.com/$kUpdateRepository/releases/download/beta/latest.json'
          : 'https://github.com/$kUpdateRepository/releases/latest/download/latest.json',
    );
