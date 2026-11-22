import 'package:flutter_test/flutter_test.dart';

import 'listening_statistics_cases.dart' as services_listening_statistics;
import 'listening_stats_poster_service_cases.dart'
    as services_listening_stats_poster_service;
import 'play_statistics_service_cases.dart' as services_play_statistics_service;

void main() {
  group('listening statistics', services_listening_statistics.main);
  group(
    'listening stats poster service',
    services_listening_stats_poster_service.main,
  );
  group('play statistics service', services_play_statistics_service.main);
}
