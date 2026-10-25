import 'package:flutter_test/flutter_test.dart';

import 'comment_row_cases.dart' as comment_row;
import 'favorite_action_cases.dart' as favorite_action;
import 'font_picker_sheet_cases.dart' as font_picker_sheet;
import 'lyrics_poster_preview_page_cases.dart' as lyrics_poster_preview_page;
import 'lyrics_selection_page_cases.dart' as lyrics_selection_page;

void main() {
  group('comment row', comment_row.main);
  group('favorite action', favorite_action.main);
  group('font picker sheet', font_picker_sheet.main);
  group('lyrics poster preview page', lyrics_poster_preview_page.main);
  group('lyrics selection page', lyrics_selection_page.main);
}
