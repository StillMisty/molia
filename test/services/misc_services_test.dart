import 'package:flutter_test/flutter_test.dart';

import 'ai_settings_store_cases.dart' as services_ai_settings_store;
import 'annual_poster_service_cases.dart' as services_annual_poster_service;
import 'auto_source_swap_service_cases.dart'
    as services_auto_source_swap_service;
import 'cache_service_cases.dart' as services_cache_service;
import 'cast_cases.dart' as services_cast;
import 'cover_image_codec_cases.dart' as services_cover_image_codec;
import 'device_local_store_cases.dart' as services_device_local_store;
import 'diagnostics_cases.dart' as services_diagnostics;
import 'diagnostics_core_cases.dart' as services_diagnostics_core;
import 'escape_claims_cases.dart' as services_escape_claims;
import 'global_hotkeys_cases.dart' as services_global_hotkeys;
import 'key_claims_cases.dart' as services_key_claims;
import 'notification_cases.dart' as services_notification;
import 'playback_observer_cases.dart' as services_playback_observer;
import 'scrobble_cases.dart' as services_scrobble;
import 'shortcut_bindings_cases.dart' as services_shortcut_bindings;
import 'update_check_coordinator_cases.dart'
    as services_update_check_coordinator;
import 'swap_query_planner_cases.dart' as services_swap_query_planner;
import 'window_bounds_cases.dart' as services_window_bounds;
import 'window_bounds_store_cases.dart' as services_window_bounds_store;
import 'artwork_cases.dart' as services_artwork;
import 'ai_services_cases.dart' as services_ai_services;
import 'library_services_cases.dart' as services_library_services;
import 'system_services_cases.dart' as services_system_services;

void main() {
  group('ai settings store', services_ai_settings_store.main);
  group('annual poster service', services_annual_poster_service.main);
  group('auto source swap service', services_auto_source_swap_service.main);
  group('cache service', services_cache_service.main);
  group('cast', services_cast.main);
  group('cover image codec', services_cover_image_codec.main);
  group('device local store', services_device_local_store.main);
  group('diagnostics', services_diagnostics.main);
  group('diagnostics core', services_diagnostics_core.main);
  group('escape claims', services_escape_claims.main);
  group('global hotkeys', services_global_hotkeys.main);
  group('key claims', services_key_claims.main);
  group('notification', services_notification.main);
  group('playback observer', services_playback_observer.main);
  group('scrobble', services_scrobble.main);
  group('shortcut bindings', services_shortcut_bindings.main);
  group('update check coordinator', services_update_check_coordinator.main);
  group('swap query planner', services_swap_query_planner.main);
  group('window bounds', services_window_bounds.main);
  group('window bounds store', services_window_bounds_store.main);
  group('artwork', services_artwork.main);
  group('ai services', services_ai_services.main);
  group('library services', services_library_services.main);
  group('system services', services_system_services.main);
}
