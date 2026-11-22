import 'package:flutter_test/flutter_test.dart';

import 'collection_actions_cases.dart' as collection_actions;
import 'collection_io_commands_cases.dart' as collection_io_commands;
import 'collection_presenter_cases.dart' as collection_presenter;
import 'collection_projection_cases.dart' as collection_projection;
import 'collection_scroll_bookkeeping_cases.dart'
    as collection_scroll_bookkeeping;
import 'collection_session_cases.dart' as collection_session;
import 'playlist_cases.dart' as playlist;
import 'search_discover_cases.dart' as search_discover;

void main() {
  group('collection actions', collection_actions.main);
  group('collection io commands', collection_io_commands.main);
  group('collection presenter', collection_presenter.main);
  group('collection projection', collection_projection.main);
  group('collection scroll bookkeeping', collection_scroll_bookkeeping.main);
  group('collection session', collection_session.main);
  group('playlist', playlist.main);
  group('search discover', search_discover.main);
}
