import 'package:flutter_test/flutter_test.dart';

import 'library_page_cases.dart' as widgets_library_page;
import 'library_browse_view_cases.dart' as widgets_library_browse_view;
import 'library_search_tab_cases.dart' as widgets_library_search_tab;
import 'collection_track_list_cases.dart' as widgets_collection_track_list;
import 'discover_tracks_page_cases.dart' as widgets_discover_tracks_page;

void main() {
  group('library page', widgets_library_page.main);
  group('library browse view', widgets_library_browse_view.main);
  group('library search tab', widgets_library_search_tab.main);
  group('collection track list', widgets_collection_track_list.main);
  group('discover tracks page', widgets_discover_tracks_page.main);
}
