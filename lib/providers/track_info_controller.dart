/// 歌曲信息页的 ViewModel：本地数据、省流开关与当前曲目订阅的唯一持有者。
///
/// 为什么单独一层：信息页是播放页的第三个 tab，切歌 / 下载记录 / 缓存修订 /
/// 省流网络变化都会触发局部刷新；把这些订阅和「何时重算」留在 widget 里会让
/// 页面直接依赖多个数据服务。这里组合现有服务，只向 UI 发布不可变状态与
/// 窄命令。
library;

import 'package:flutter/foundation.dart';

import '../services/cache_service.dart';
import '../services/data_saver_service.dart';
import '../services/download/download_records.dart';
import '../services/track_local_data_controller.dart';
import '../services/track_local_data_service.dart';
import 'playback_provider.dart';

/// 信息页的不可变只读状态（低频；本地数据另有 [TrackInfoController.localData]
/// 高频通道，避免整页跟着目录扫描重建）。
@immutable
class TrackInfoState {
  const TrackInfoState({
    required this.localDataAvailable,
    required this.dataSaverActive,
  });

  /// 单曲本地数据服务是否已装配（未装配时入口不可点）。
  final bool localDataAvailable;

  /// 省流模式当前是否实际生效（已开启且在移动数据）。
  final bool dataSaverActive;

  @override
  bool operator ==(Object other) =>
      other is TrackInfoState &&
      other.localDataAvailable == localDataAvailable &&
      other.dataSaverActive == dataSaverActive;

  @override
  int get hashCode => Object.hash(localDataAvailable, dataSaverActive);
}

/// 信息页控制器：跟随播放器切歌，转发本地数据 ValueListenable。
class TrackInfoController extends ChangeNotifier {
  TrackInfoController({
    required this._playback,
    required CacheService cacheService,
    TrackLocalDataService? localDataService,
    DownloadRecords? downloadRecords,
    this._dataSaver,
    TrackLocalDataTimerFactory? timerFactory,
  }) : _localDataService = localDataService {
    _localData = TrackLocalDataController(
      service: localDataService,
      cacheService: cacheService,
      downloadRecords: downloadRecords,
      timerFactory: timerFactory,
    );
    _state = _snapshot();
    _dataSaver?.addListener(_syncAvailability);
    _playback.addListener(_syncTrack);
    _syncTrack();
  }

  final PlaybackProvider _playback;
  final TrackLocalDataService? _localDataService;
  final DataSaverService? _dataSaver;

  late final TrackLocalDataController _localData;
  late TrackInfoState _state;

  /// 低频状态（本地数据能力 + 省流生效）。
  TrackInfoState get state => _state;

  /// 本地数据高频通道：只有本地数据行订阅，不重建信息区其它行。
  ValueListenable<TrackLocalDataState> get localData => _localData;

  /// 立即重载当前曲目的本地数据（清理 / 删除动作后的显式刷新）。
  Future<void> refreshLocalData() => _localData.refreshNow();

  void _syncTrack() {
    _localData.setTrack(_playback.snapshot.current);
  }

  void _syncAvailability() {
    final next = _snapshot();
    if (next == _state) return;
    _state = next;
    notifyListeners();
  }

  TrackInfoState _snapshot() => TrackInfoState(
    localDataAvailable: _localDataService != null,
    dataSaverActive: _dataSaver?.active ?? false,
  );

  @override
  void dispose() {
    _playback.removeListener(_syncTrack);
    _dataSaver?.removeListener(_syncAvailability);
    _localData.dispose();
    super.dispose();
  }
}
