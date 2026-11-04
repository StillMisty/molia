import 'package:flutter_test/flutter_test.dart';

import 'app_presence_cases.dart' as app_presence;
import 'audio_cache_platform_cases.dart' as audio_cache_platform;
import 'audio_route_monitor_cases.dart' as audio_route_monitor;
import 'audio_tag_writer_cases.dart' as audio_tag_writer;
import 'cover_image_codec_cases.dart' as cover_image_codec;
import 'cover_resolution_cases.dart' as cover_resolution;
import 'data_saver_service_cases.dart' as data_saver_service;
import 'haptics_service_cases.dart' as haptics_service;

void main() {
  group('app presence', app_presence.main);
  group('audio cache platform', audio_cache_platform.main);
  group('audio route monitor', audio_route_monitor.main);
  group('audio tag writer', audio_tag_writer.main);
  group('cover image codec', cover_image_codec.main);
  group('cover resolution', cover_resolution.main);
  group('data saver service', data_saver_service.main);
  group('haptics service', haptics_service.main);
}
