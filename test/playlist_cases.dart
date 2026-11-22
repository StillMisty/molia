import 'package:flutter_test/flutter_test.dart';

import 'audio_title_editor_cases.dart' as audio_title_editor;
import 'modal_page_navigator_cases.dart' as modal_page_navigator;
import 'paged_list_controller_cases.dart' as paged_list_controller;
import 'playlist_experience_cases.dart' as playlist_experience;
import 'queue_edit_policy_cases.dart' as queue_edit_policy;

void main() {
  group('audio title editor', audio_title_editor.main);
  group('modal page navigator', modal_page_navigator.main);
  group('paged list controller', paged_list_controller.main);
  group('playlist experience', playlist_experience.main);
  group('queue edit policy', queue_edit_policy.main);
}
