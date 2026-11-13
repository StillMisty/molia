/// Android Auto 浏览树（纯 Dart 合同）：队列 / 收藏 / 最近播放 / 歌单。
///
/// 原生媒体库服务只负责渲染这棵树并把点击回传；节点 id、可播叶子与队列
/// 下标映射都在这里测试，不依赖 Media3 / 平台通道。
library;

/// 浏览树里的一首曲目（最小信息；不带 payload）。
class CarTrack {
  const CarTrack({required this.stableId, required this.title, this.artist});

  final String stableId;
  final String title;
  final String? artist;
}

class CarPlaylist {
  const CarPlaylist({
    required this.id,
    required this.name,
    required this.tracks,
  });

  final int id;
  final String name;
  final List<CarTrack> tracks;
}

/// 树节点：四个根固定存在；`isPlayable` 为 true 的叶子可被选中播放。
class CarBrowseNode {
  const CarBrowseNode({
    required this.id,
    required this.title,
    this.subtitle,
    this.isPlayable = false,
    this.queueIndex,
    this.children = const [],
  });

  final String id;
  final String title;
  final String? subtitle;
  final bool isPlayable;

  /// 队列叶子对应的真实队列下标（重复曲目 / 随机顺序时不能按 id 反查）。
  final int? queueIndex;
  final List<CarBrowseNode> children;
}

/// 选中节点后要执行的播放动作（由原生转发给播放命令端口）。
class CarPlayAction {
  const CarPlayAction._(
    this.kind, {
    this.queueIndex,
    this.trackId,
    this.playlistId,
  });

  const CarPlayAction.queueIndex(int index)
    : this._(CarPlayActionKind.queueIndex, queueIndex: index);

  const CarPlayAction.track(String trackId)
    : this._(CarPlayActionKind.track, trackId: trackId);

  const CarPlayAction.playlistTrack(int playlistId, int index)
    : this._(
        CarPlayActionKind.playlistTrack,
        playlistId: playlistId,
        queueIndex: index,
      );

  final CarPlayActionKind kind;
  final int? queueIndex;
  final String? trackId;
  final int? playlistId;
}

enum CarPlayActionKind { queueIndex, track, playlistTrack }

/// 根分组文案由调用方注入（Dart l10n / 原生车机共用同一份字符串）。
class CarBrowseLabels {
  const CarBrowseLabels({
    required this.queue,
    required this.favorites,
    required this.recent,
    required this.playlists,
  });

  final String queue;
  final String favorites;
  final String recent;
  final String playlists;
}

abstract final class CarBrowseTreeBuilder {
  static const String queueRootId = 'queue';
  static const String favoritesRootId = 'favorites';
  static const String recentRootId = 'recent';
  static const String playlistsRootId = 'playlists';

  /// 构建四个根；空集合也保留根节点（车机显示空分组而不是丢分类）。
  static List<CarBrowseNode> build({
    required CarBrowseLabels labels,
    required List<CarTrack> queue,
    required List<CarTrack> favorites,
    required List<CarTrack> recent,
    required List<CarPlaylist> playlists,
  }) => [
    CarBrowseNode(
      id: queueRootId,
      title: labels.queue,
      children: [
        for (var index = 0; index < queue.length; index++)
          CarBrowseNode(
            id: 'queue:$index',
            title: queue[index].title,
            subtitle: queue[index].artist,
            isPlayable: true,
            queueIndex: index,
          ),
      ],
    ),
    CarBrowseNode(
      id: favoritesRootId,
      title: labels.favorites,
      children: [
        for (final track in favorites)
          CarBrowseNode(
            id: 'favorite:${track.stableId}',
            title: track.title,
            subtitle: track.artist,
            isPlayable: true,
          ),
      ],
    ),
    CarBrowseNode(
      id: recentRootId,
      title: labels.recent,
      children: [
        for (final track in recent)
          CarBrowseNode(
            id: 'recent:${track.stableId}',
            title: track.title,
            subtitle: track.artist,
            isPlayable: true,
          ),
      ],
    ),
    CarBrowseNode(
      id: playlistsRootId,
      title: labels.playlists,
      children: [
        for (final playlist in playlists)
          CarBrowseNode(
            id: 'playlist:${playlist.id}',
            title: playlist.name,
            children: [
              for (var index = 0; index < playlist.tracks.length; index++)
                CarBrowseNode(
                  id: 'playlist:${playlist.id}:$index',
                  title: playlist.tracks[index].title,
                  subtitle: playlist.tracks[index].artist,
                  isPlayable: true,
                ),
            ],
          ),
      ],
    ),
  ];

  /// 叶子 → 播放命令；分组 / 空节点返回 null。
  static CarPlayAction? actionFor(CarBrowseNode node) {
    if (!node.isPlayable) return null;
    final id = node.id;
    if (id.startsWith('queue:')) {
      final index = node.queueIndex;
      return index == null ? null : CarPlayAction.queueIndex(index);
    }
    if (id.startsWith('favorite:')) {
      return CarPlayAction.track(id.substring('favorite:'.length));
    }
    if (id.startsWith('recent:')) {
      return CarPlayAction.track(id.substring('recent:'.length));
    }
    if (id.startsWith('playlist:')) {
      final parts = id.split(':');
      if (parts.length != 3) return null;
      final playlistId = int.tryParse(parts[1]);
      final index = int.tryParse(parts[2]);
      if (playlistId == null || index == null) return null;
      return CarPlayAction.playlistTrack(playlistId, index);
    }
    return null;
  }
}
