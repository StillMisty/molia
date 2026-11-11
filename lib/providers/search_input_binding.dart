import 'package:flutter/widgets.dart';

import 'search_session.dart';

/// 把 [SearchSession] 的关键词绑定到宿主的 [TextEditingController]。
///
/// 双向同步都只在值真正不同时写回：输入框监听只在用户改动时把文本送进
/// 会话，会话监听只在会话换了关键词时更新输入框，因此两个宿主（资料库
/// 搜索 tab / Ctrl+F 遮罩）可以同时挂同一个会话而不会形成回环。
///
/// 宿主只负责创建与 [dispose]；不需要再维护文本镜像，也不需要在 build 后
/// 补一帧清空输入框。
class SearchInputBinding {
  SearchInputBinding({required this.session, required this.controller}) {
    _syncController();
    controller.addListener(_onControllerChanged);
    session.addListener(_onSessionChanged);
  }

  final SearchSession session;
  final TextEditingController controller;

  bool _writing = false;

  void _onControllerChanged() {
    if (_writing) return;
    final text = controller.text;
    if (text == session.query) return;
    session.updateQuery(text);
  }

  void _onSessionChanged() {
    if (controller.text == session.query) return;
    _syncController();
  }

  void _syncController() {
    final query = session.query;
    _writing = true;
    try {
      controller.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    } finally {
      _writing = false;
    }
  }

  void dispose() {
    controller.removeListener(_onControllerChanged);
    session.removeListener(_onSessionChanged);
  }
}
