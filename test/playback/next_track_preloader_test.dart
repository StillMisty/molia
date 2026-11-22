import 'package:flutter_test/flutter_test.dart';

import 'next_track_preloader_cases.dart' as playback_next_track_preloader;

/// 下一首预取：直链预热、字节预下载与缓存写入所有权。
///
/// 单独成文件：IO 用例走真实 HTTP，不能被同一进程里 widget binding 的
/// HttpOverrides 拦截。
void main() {
  group('next track preloader', playback_next_track_preloader.main);
}
