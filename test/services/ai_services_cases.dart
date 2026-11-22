import 'package:flutter_test/flutter_test.dart';

import 'ai_prompt_cases.dart' as services_ai_prompt;
import 'ai_recommendation_service_cases.dart'
    as services_ai_recommendation_service;
import 'ai_recommendation_store_cases.dart' as services_ai_recommendation_store;
import 'llm_client_cases.dart' as services_llm_client;

void main() {
  group('ai prompt', services_ai_prompt.main);
  group('ai recommendation service', services_ai_recommendation_service.main);
  group('ai recommendation store', services_ai_recommendation_store.main);
  group('llm client', services_llm_client.main);
}
