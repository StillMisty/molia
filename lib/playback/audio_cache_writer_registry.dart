/// 音频缓存单写者登记：同一缓存文件在任一时刻只允许一个写入者。
///
/// `LockCachingAudioSource` 的半成品名固定是 `<cacheFile>.part`，两个 writer
/// 会各自截断同一个文件、完成时各自 rename：轻则留下「完整文件 + `.part`」
/// 并存白占磁盘，重则覆盖已经落位、正在被播放的缓存（issue #60）。重播、
/// 播放失败原地重取、换队列后重播同一首都可能在同一路径再建一个缓存源，
/// 这里按缓存文件路径收口。
///
/// 只登记、不取消：完成监听由 `AudioCacheCompletionRecorder` 持有（切歌也
/// 不能打断在途下载）；登记项在 handle 的 `completed` 落定后自动释放。
library;

import 'dart:async';

import 'audio_cache_completion.dart';

class AudioCacheWriterRegistry {
  /// 路径 → 当前写入者。登记顺序无关，同一路径最多一项。
  final Map<String, CachingAudioSourceHandle> _writers = {};

  /// 当前写入者数量（诊断 / 测试用）。
  int get count => _writers.length;

  /// [cacheFilePath] 是否已有本进程 writer 在写。
  bool isWriting(String cacheFilePath) => _writers.containsKey(cacheFilePath);

  /// 把 [handle] 登记为 [cacheFilePath] 的唯一写入者。
  ///
  /// 返回 false 表示已有写入者：调用方**不得**创建第二个 writer，应改用
  /// 不写缓存的播放方式，等在途 writer 把文件落位后重播即命中 `file://`。
  bool acquire(String cacheFilePath, CachingAudioSourceHandle handle) {
    if (_writers.containsKey(cacheFilePath)) return false;
    _writers[cacheFilePath] = handle;
    // 完成 / 失败 / 超时取消都算所有权结束；错误不外抛（等待方已有各自的
    // 收口，登记表只关心释放）。
    unawaited(
      handle.completed.then(
        (_) => release(cacheFilePath, handle),
        onError: (Object _) => release(cacheFilePath, handle),
      ),
    );
    return true;
  }

  /// 释放 [cacheFilePath] 的写入者；只释放登记过的那一个（迟到的旧 handle
  /// 不能把新写入者的登记顶掉）。
  void release(String cacheFilePath, CachingAudioSourceHandle handle) {
    if (identical(_writers[cacheFilePath], handle)) {
      _writers.remove(cacheFilePath);
    }
  }

  /// 清空登记（服务销毁）。不取消在途下载：那是完成记录器的职责。
  void clear() => _writers.clear();
}
