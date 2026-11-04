/// AI 推歌组件测试的存储支撑。
library;

import 'package:molia/services/ai/ai_recommendation_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 组件测试用推荐历史存储：批次写进已 mock 的 SharedPreferences。
///
/// 默认实现在 `testWidgets` 的假时钟里调用 path_provider：平台通道的回复要走
/// 真实事件循环，测试体 awaits 它永远等不到，`setEnabled` / 删除历史会卡死
/// （表现为「did not complete」或整个套件挂住）。显式声明没有文件目录，让
/// store 走 prefs 回退分支。
AiRecommendationStore testAiRecommendationStore({
  SharedPreferences? preferences,
}) => AiRecommendationStore(
  preferences: preferences,
  directoryProvider: () async => null,
);
