import 'package:flutter_test/flutter_test.dart';

import 'ai_dj_history_controller_cases.dart'
    as providers_ai_dj_history_controller;
import 'album_artist_view_model_cases.dart'
    as providers_album_artist_view_model;
import 'annual_report_provider_cases.dart' as providers_annual_report_provider;
import 'favorites_view_model_cases.dart' as providers_favorites_view_model;
import 'library_read_projection_cases.dart'
    as providers_library_read_projection;
import 'nav_provider_cases.dart' as providers_nav_provider;
import 'nearby_scan_session_cases.dart' as providers_nearby_scan_session;
import 'play_statistics_provider_all_history_cases.dart'
    as play_statistics_provider_all_history;
import 'playback_feel_cases.dart' as providers_playback_feel;
import 'playback_volume_cases.dart' as providers_playback_volume;
import 'search_assist_controller_cases.dart'
    as providers_search_assist_controller;
import 'ai_dj_provider_cases.dart' as providers_ai_dj_provider;

void main() {
  group('ai dj history controller', providers_ai_dj_history_controller.main);
  group('album artist view model', providers_album_artist_view_model.main);
  group('annual report provider', providers_annual_report_provider.main);
  group('favorites view model', providers_favorites_view_model.main);
  group('library read projection', providers_library_read_projection.main);
  group('nav provider', providers_nav_provider.main);
  group('nearby scan session', providers_nearby_scan_session.main);
  group(
    'play statistics provider all history',
    play_statistics_provider_all_history.main,
  );
  group('playback feel', providers_playback_feel.main);
  group('playback volume', providers_playback_volume.main);
  group('search assist controller', providers_search_assist_controller.main);
  group('ai dj provider', providers_ai_dj_provider.main);
}
