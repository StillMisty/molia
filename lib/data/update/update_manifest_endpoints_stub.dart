import '../../domain/models/app_release.dart';

/// Web 端清单与站点同源（发布流水线把稳定版 latest.json 部署到 Pages 根目录）。
///
/// 测试渠道在 Web 不可用（Pages 只部署稳定版），
/// `UpdateProvider.channelSelectable` 会据此隐藏渠道选择。
Uri defaultUpdateManifestUri(UpdateChannel channel) => Uri.base.resolve('latest.json');
