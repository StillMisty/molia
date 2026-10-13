/// 更新安装策略的共享类型（原生与 Web 两份实现共用，见
/// `update_installer.dart` 的条件导入）。
library;

/// 安装结果：调用方据此决定提示文案与退出时机。
enum InstallOutcome {
  /// 已交给系统安装器（Android），应用继续运行。
  handedOff,

  /// 替换脚本已启动：桌面端需要立刻退出进程，脚本完成后会自动重启。
  restartPending,

  /// 需要用户先授予「安装未知应用」权限（Android）。
  needPermission,

  /// 安装目录不可写（系统包管理器安装 / 权限不足），只能手动下载覆盖。
  notWritable,

  /// 当前平台不支持应用内安装（iOS / Web）。
  unsupported,

  /// 安装或替换失败。
  failed,
}

/// 当前平台信息：清单里 platform / arch 字段的取值来源。
class UpdatePlatformInfo {
  const UpdatePlatformInfo({required this.platform, required this.arch});

  /// android / windows / linux / web / ios / macos。
  final String platform;

  /// arm64 / armv7 / x86_64 / x64 / any。
  final String arch;

  @override
  bool operator ==(Object other) =>
      other is UpdatePlatformInfo &&
      other.platform == platform &&
      other.arch == arch;

  @override
  int get hashCode => Object.hash(platform, arch);

  @override
  String toString() => 'UpdatePlatformInfo($platform/$arch)';
}
