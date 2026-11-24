/// 歌曲信息页的 ViewModel：本地数据、省流开关与当前曲目订阅的唯一持有者。
library;

import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/data_saver_service.dart';
import '../services/track_local_data_controller.dart';
import '../services/track_local_data_service.dart';
import 'app_providers.dart';
import 'playback_provider.dart';

part 'track_info_controller.g.dart';

/// 信息页的不可变只读状态（低频；本地数据另有 [TrackInfoController.localData]
/// 高频通道，避免整页跟着目录扫描重建）。
@immutable
class TrackInfoState {
  const TrackInfoState({
    required this.localDataAvailable,
    required this.dataSaverActive,
  });

  final bool localDataAvailable;
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
@Riverpod(keepAlive: true, name: 'trackInfoControllerProvider')
class TrackInfoController extends _$TrackInfoController {
  late final PlaybackProvider _playback;
  TrackLocalDataService? _localDataService;
  DataSaverService? _dataSaver;
  late final TrackLocalDataController _localData;

  @override
  TrackInfoState build() {
    _playback = ref.read(playbackControllerProvider);
    _localDataService = ref.read(trackLocalDataServiceProvider);
    _dataSaver = ref.read(dataSaverServiceControllerProvider);
    _localData = TrackLocalDataController(
      service: _localDataService,
      cacheService: ref.read(cacheServiceProvider),
      downloadRecords: ref.read(downloadRecordsControllerProvider),
    );
    _dataSaver?.changes.addListener(_syncAvailability);
    _playback.changes.addListener(_syncTrack);
    ref.onDispose(() {
      _playback.changes.removeListener(_syncTrack);
      _dataSaver?.changes.removeListener(_syncAvailability);
      _localData.dispose();
    });
    _syncTrack();
    return _snapshot();
  }

  /// 本地数据高频通道：只有本地数据行订阅，不重建信息区其它行。
  ValueListenable<TrackLocalDataState> get localData => _localData;

  Future<void> refreshLocalData() => _localData.refreshNow();

  void _syncTrack() {
    _localData.setTrack(_playback.snapshot.current);
  }

  void _syncAvailability() {
    state = _snapshot();
  }

  TrackInfoState _snapshot() => TrackInfoState(
    localDataAvailable: _localDataService != null,
    dataSaverActive: _dataSaver?.active ?? false,
  );
}
