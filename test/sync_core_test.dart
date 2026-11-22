import 'package:flutter_test/flutter_test.dart';

import 'sync_change_set_cases.dart' as sync_change_set;
import 'sync_clock_skew_cases.dart' as sync_clock_skew;
import 'sync_delta_cursor_cases.dart' as sync_delta_cursor;
import 'sync_delta_protocol_cases.dart' as sync_delta_protocol;
import 'sync_journal_cases.dart' as sync_journal;
import 'sync_merge_cases.dart' as sync_merge;
import 'sync_payload_binary_cases.dart' as sync_payload_binary;
import 'sync_protocol_cases.dart' as sync_protocol;
import 'sync_stamp_cases.dart' as sync_stamp;
import 'sync_stamp_book_cases.dart' as sync_stamp_book;
import 'sync_state_codec_cases.dart' as sync_state_codec;
import 'sync_adapters_cases.dart' as sync_adapters;

void main() {
  group('sync change set', sync_change_set.main);
  group('sync clock skew', sync_clock_skew.main);
  group('sync delta cursor', sync_delta_cursor.main);
  group('sync delta protocol', sync_delta_protocol.main);
  group('sync journal', sync_journal.main);
  group('sync merge', sync_merge.main);
  group('sync payload binary', sync_payload_binary.main);
  group('sync protocol', sync_protocol.main);
  group('sync stamp', sync_stamp.main);
  group('sync stamp book', sync_stamp_book.main);
  group('sync state codec', sync_state_codec.main);
  group('sync adapters', sync_adapters.main);
}
