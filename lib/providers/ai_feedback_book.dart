/// AI 反馈账本：本轮反馈 + 跨重启长期记忆 + 「不感兴趣」撤销栈。
///
/// 本轮（跳过 / 喜欢）随电台会话重置，长期记忆持久化在 [AiFeedbackMemory]；
/// 提示词与预览共用 [mergedForPrompt] 的合并顺序，避免两处各拼一份标签。
/// 本类不持有 UI 通知：偏好版本号由注入的 [onRevision] 递增，聚合通知仍由
/// `AiDjProvider` 在命令落定后统一发出。
library;

import 'dart:async';

import '../domain/models/ai_dj.dart';
import '../services/ai/ai_generation_request.dart';

/// 反馈记忆落盘；失败由调用方决定是否吞掉（与现有 store 语义一致）。
typedef AiFeedbackPersist = Future<void> Function(AiFeedbackMemory memory);

/// 「不感兴趣」撤销项：记录原下标以支持原位插回。
class AiFeedbackUndo {
  const AiFeedbackUndo({required this.index, required this.item});

  final int index;
  final ResolvedRecommendation item;
}

class AiFeedbackBook {
  AiFeedbackBook({
    required this._persist,
    required this._onRevision,
    this._memory = AiFeedbackMemory.empty,
  });

  final AiFeedbackPersist _persist;
  final void Function() _onRevision;

  AiFeedbackMemory _memory;

  /// 本轮反馈（不持久化；电台会话重置时清空）。
  final List<String> _skipped = [];
  final List<String> _liked = [];

  /// 本轮手动「不感兴趣」的撤销栈（新项在前）。
  final List<AiFeedbackUndo> _undo = [];

  AiFeedbackMemory get memory => _memory;

  List<String> get seeds => List.unmodifiable(_memory.seeds);

  List<String> get skippedLabels => List.unmodifiable(_skipped);
  List<String> get likedLabels => List.unmodifiable(_liked);

  /// 跨重启记忆（UI 反馈区展示用）。
  List<String> get rememberedSkippedLabels =>
      List.unmodifiable(_memory.skipped);
  List<String> get rememberedLikedLabels => List.unmodifiable(_memory.liked);

  /// 合并后的本轮反馈（自动跳过 + 长期记忆 + 本轮喜欢）。
  List<String> get mergedSkippedLabels =>
      _unique([..._skipped, ..._memory.skipped]);
  List<String> get mergedLikedLabels => _unique([..._liked, ..._memory.liked]);

  /// 手动「不感兴趣」项（UI 撤销芯片）。
  List<ResolvedRecommendation> get notInterestedItems =>
      List.unmodifiable([for (final entry in _undo) entry.item]);

  /// 同步启动/跨设备重载后的记忆（版本号由调用方递增）。
  void replaceMemory(AiFeedbackMemory memory) => _memory = memory;

  /// 新一轮电台会话：只清本轮，长期记忆保持。
  void resetRound() {
    _skipped.clear();
    _liked.clear();
  }

  /// active 换批 / 删除后旧批的撤销项已无意义。
  void clearUndo() => _undo.clear();

  /// 记录一条本轮跳过（自动判定或手动「不感兴趣」）；重复标签只留一份。
  void recordSkip(String label) {
    if (_skipped.contains(label)) return;
    _skipped.add(label);
  }

  /// 提交一条喜欢回流：本轮 + 长期记忆，并异步落盘。
  void recordLike(String label) {
    _addLiked(label);
    _onRevision();
    unawaited(_persist(_memory));
  }

  /// 生成用的合并反馈。
  ///
  /// [pendingLikes] 是本轮新收藏、尚未回流的标签；[commit] 为假时只模拟
  /// 合并顺序（预览），为真时写本轮 + 长期记忆并落盘（实际发送）。
  AiGenerationFeedback mergedForPrompt({
    required bool commit,
    List<String> pendingLikes = const [],
  }) {
    if (pendingLikes.isEmpty) {
      return AiGenerationFeedback(
        skipped: mergedSkippedLabels,
        liked: mergedLikedLabels,
      );
    }
    if (commit) {
      for (final label in pendingLikes) {
        _addLiked(label);
      }
      _onRevision();
      unawaited(_persist(_memory));
      return AiGenerationFeedback(
        skipped: mergedSkippedLabels,
        liked: mergedLikedLabels,
      );
    }
    // 预览只模拟回流：本轮喜欢在前、待回流在后、长期记忆垫底，提交后
    // `addLiked` 会前插新标签，因此预览也要用同一变换。
    var simulated = _memory;
    final pendingLabels = <String>[];
    for (final label in pendingLikes) {
      pendingLabels.add(label);
      simulated = simulated.addLiked(label);
    }
    return AiGenerationFeedback(
      skipped: mergedSkippedLabels,
      liked: _unique([..._liked, ...pendingLabels, ...simulated.liked]),
    );
  }

  /// 记录手动「不感兴趣」：本轮跳过 + 长期记忆 + 撤销栈。
  ///
  /// 列表移除与历史写回由调用方完成，本类只维护反馈账本。
  void rememberNotInterested(int index, ResolvedRecommendation item) {
    final label = item.source.label;
    recordSkip(label);
    _memory = _memory.addSkipped(label);
    _undo.insert(0, AiFeedbackUndo(index: index, item: item));
    _onRevision();
  }

  /// 取回一条撤销项并解除排除；列表原位插回由调用方完成。
  AiFeedbackUndo? undo(String uri) {
    final position = _undo.indexWhere(
      (entry) => entry.item.track.id.uri == uri,
    );
    if (position < 0) return null;
    final entry = _undo.removeAt(position);
    final label = entry.item.source.label;
    _skipped.remove(label);
    _memory = _memory.removeSkipped(label);
    _onRevision();
    return entry;
  }

  /// 持久化当前记忆（撤销 / 不感兴趣等需要在通知前落盘的路径）。
  Future<void> persist() => _persist(_memory);

  /// 加入「多来点这种」种子，下一批成功生成后由 [consumeSeeds] 消费。
  Future<void> addSeed(String label) async {
    final value = label.trim();
    if (value.isEmpty) return;
    _memory = _memory.addSeed(value);
    _onRevision();
    await _persist(_memory);
  }

  Future<void> removeSeed(String label) async {
    _memory = _memory.removeSeed(label);
    _onRevision();
    await _persist(_memory);
  }

  /// 清空长期记忆与本轮反馈（撤销栈保留：已移出列表不回插）。
  Future<void> clearMemory() async {
    _memory = AiFeedbackMemory.empty;
    _skipped.clear();
    _liked.clear();
    _onRevision();
    await _persist(_memory);
  }

  /// 成功生成后消费种子；不改偏好版本。
  Future<void> consumeSeeds() async {
    if (_memory.seeds.isEmpty) return;
    _memory = _memory.withSeeds(const []);
    await _persist(_memory);
  }

  void _addLiked(String label) {
    // 保留重复标签（同一首歌来自不同会话项）：合并输出会去重，但本轮列表
    // 保留原始顺序。
    _liked.add(label);
    _memory = _memory.addLiked(label);
  }

  static List<String> _unique(List<String> labels) {
    final seen = <String>{};
    return [
      for (final label in labels)
        if (label.trim().isNotEmpty && seen.add(label)) label,
    ];
  }
}
