import 'package:flutter_test/flutter_test.dart';

import 'lyrics_quick_actions_cases.dart' as widgets_lyrics_quick_actions;
import 'wavy_scope_cases.dart' as widgets_wavy_scope;
import 'poster_share_sheet_cases.dart' as widgets_poster_share_sheet;
import 'poster_style_sheet_cases.dart' as widgets_poster_style_sheet;
import 'lyrics_poster_preview_page_cases.dart'
    as widgets_lyrics_poster_preview_page;
import 'lyrics_selection_page_cases.dart' as widgets_lyrics_selection_page;
import 'lyrics_view_session_cases.dart' as widgets_lyrics_view_session;

void main() {
  group('lyrics quick actions', widgets_lyrics_quick_actions.main);
  group('wavy scope', widgets_wavy_scope.main);
  group('poster share sheet', widgets_poster_share_sheet.main);
  group('poster style sheet', widgets_poster_style_sheet.main);
  group('lyrics poster preview page', widgets_lyrics_poster_preview_page.main);
  group('lyrics selection page', widgets_lyrics_selection_page.main);
  group('lyrics view session', widgets_lyrics_view_session.main);
}
