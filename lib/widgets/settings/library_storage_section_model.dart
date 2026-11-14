import 'package:flutter/foundation.dart';

import '../../services/library/library_add_settings.dart';

/// 「曲库与存储」卡的一行。
///
/// 卡片按 [LibraryStorageSectionModel.visibleRows] 的声明顺序渲染，行序与
/// 显隐不再写在 widget 的 if 链里。
enum LibraryStorageRow {
  /// 新歌加入收藏 / 列表的位置（跟人走）。
  addPosition,

  /// 本地音乐文件夹入口（iOS 不出现）。
  musicFolders,

  /// 下载设置入口。
  downloadSettings,

  /// 下载管理入口。
  downloadsManage,

  /// 缓存管理入口。
  cacheManagement,
}

/// 「曲库与存储」卡的绑定：行集合、值、写入、重载与可用性只在这里声明。
///
/// **为什么需要它**：这张卡混了三种来源——加入位置是服务内存状态，文件夹 /
/// 下载 / 缓存是设备本地入口，显隐还多一个 iOS 判据。散在 build 里时，要验证
/// 「iOS 隐藏文件夹行」「服务缺省隐藏加入位置行」「写入落到哪个键」都得搭
/// widget 树。收成模型后，卡片只做「按行渲染」，测试直接构造模型断言。
///
/// **不搬持久化**：加入位置仍归 [LibraryAddSettings]（它背后的
/// `SettingsRegistry` 作用域负责读写与同步），本类只包一层值 / 写 / 重载，
/// 不复制存储，也不把注册表下放给 widget。其余三行是纯入口，没有值。
@immutable
class LibraryStorageSectionModel {
  LibraryStorageSectionModel({
    required this.addSettings,
    TargetPlatform? platform,
  }) : platform = platform ?? defaultTargetPlatform;

  /// 加入位置偏好；缺省（测试 / 精简挂载）时该行隐藏。
  final LibraryAddSettings? addSettings;

  /// 平台判据；测试可显式传入，避免依赖运行测试的宿主平台。
  final TargetPlatform platform;

  bool get addPositionAvailable => addSettings != null;

  /// 当前加入位置；服务缺省时给默认值（与持久化解析同口径）。
  LibraryAddPosition get addPosition =>
      addSettings?.position ?? LibraryAddPosition.parse(null);

  /// 写入加入位置；服务缺省时是空操作（行本来就不显示）。
  Future<void> setAddPosition(LibraryAddPosition position) async {
    await addSettings?.setPosition(position);
  }

  /// 应用远端值后的重读；服务缺省时是空操作。
  Future<void> reload() async {
    await addSettings?.init();
  }

  bool get musicFoldersAvailable => platform != TargetPlatform.iOS;

  /// 本卡当前应渲染的行（顺序即卡片行序，见 ADR-0027 的卡内排序约定）。
  List<LibraryStorageRow> get visibleRows => List.unmodifiable([
    if (addPositionAvailable) LibraryStorageRow.addPosition,
    if (musicFoldersAvailable) LibraryStorageRow.musicFolders,
    LibraryStorageRow.downloadSettings,
    LibraryStorageRow.downloadsManage,
    LibraryStorageRow.cacheManagement,
  ]);
}
