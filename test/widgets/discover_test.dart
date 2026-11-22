import 'package:flutter_test/flutter_test.dart';

import 'discover_playlists_tab_cases.dart' as widgets_discover_playlists_tab;
import 'discover_cover_handoff_cases.dart' as widgets_discover_cover_handoff;
import 'global_search_overlay_cases.dart' as widgets_global_search_overlay;
import 'search_assist_panel_cases.dart' as widgets_search_assist_panel;
import 'playlist_experience_cases.dart' as widgets_playlist_experience;
import 'misc_pages_cases.dart' as widgets_misc_pages;
import 'library_cases.dart' as widgets_library;

void main() {
  group('discover playlists tab', widgets_discover_playlists_tab.main);
  group('discover cover handoff', widgets_discover_cover_handoff.main);
  group('global search overlay', widgets_global_search_overlay.main);
  group('search assist panel', widgets_search_assist_panel.main);
  group('playlist experience', widgets_playlist_experience.main);
  group('misc pages', widgets_misc_pages.main);
  group('library', widgets_library.main);
}
