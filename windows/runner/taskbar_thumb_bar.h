#ifndef RUNNER_TASKBAR_THUMB_BAR_H_
#define RUNNER_TASKBAR_THUMB_BAR_H_

#include <windows.h>
#include <shobjidl.h>

#include <functional>
#include <string>

// Windows 任务栏缩略图工具栏（ITaskbarList3::ThumbBarAddButtons）：鼠标悬浮
// 任务栏按钮时弹出的预览浮层里显示 4 个播放控制按钮（收藏 / 上一首 /
// 播放暂停 / 下一首）。
//
// 只在「窗口在任务栏上有按钮」时出现（隐藏到托盘期间没有浮层，也没有按钮）；
// Explorer 重启会重置工具栏，靠 TaskbarCreated 注册消息重新挂上（见
// flutter_window.cc）。按钮图标是原样绘制的，不随主题反色，因此按任务栏
// 亮暗准备了两套（见 tool/gen_taskbar_icons.py）。
class TaskbarThumbBar {
 public:
  enum class Action { kFavorite, kPrevious, kPlayPause, kNext };

  // 按钮状态：Dart 侧在播放 / 收藏 / 语言变化时同步；tooltip 已按界面语言
  // 解析好，原生不做文案。
  //
  // 字段顺序：标量放最后（只在结构体尾部留对齐填充）——/W4 /WX 下成员之间的
  // 填充会触发 C4820，尾部填充不会。
  struct State {
    std::wstring tooltip_previous;
    std::wstring tooltip_play_pause;
    std::wstring tooltip_next;
    std::wstring tooltip_favorite;
    bool has_track = false;
    bool is_playing = false;
    bool is_favorite = false;
  };

  using ActionCallback = std::function<void(Action)>;

  TaskbarThumbBar();
  ~TaskbarThumbBar();

  TaskbarThumbBar(const TaskbarThumbBar&) = delete;
  TaskbarThumbBar& operator=(const TaskbarThumbBar&) = delete;

  // 绑定窗口与点击回调（窗口创建后调用一次）。
  void Attach(HWND window, ActionCallback on_action);
  // 在任务栏上挂按钮：窗口首次显示、Explorer 重启后调用（失败留给下一次）。
  void AddButtons();
  // 同步按钮可用性 / 图标 / tooltip（值没变不下发原生调用）。
  void UpdateState(const State& state);
  // 处理 WM_COMMAND：命中本工具栏按钮时返回 true（调用方直接吃掉消息）。
  bool HandleCommand(WPARAM wparam);
  // 系统亮暗（SystemUsesLightTheme）变化后换一套按钮图标。
  void RefreshThemeIcons();

  // 「TaskbarCreated」注册消息（Explorer 重启、任务栏重建时广播）。
  static UINT TaskbarCreatedMessage();

 private:
  // 按钮图标字形；同一字形两套颜色（深色任务栏用亮字形 / 浅色任务栏用暗字形）。
  enum class Glyph {
    kPrevious,
    kPlay,
    kPause,
    kNext,
    kFavorite,
    kFavoriteOn,
  };
  static constexpr int kGlyphCount = 6;
  static constexpr int kButtonCount = 4;

  // 把当前状态下发给任务栏：add=true 首次挂按钮，false 只更新字段。
  void ApplyState(bool add);
  HICON IconFor(Glyph glyph);
  void DestroyIcons();
  bool Equals(const State& left, const State& right) const;

  HWND window_ = nullptr;
  ActionCallback on_action_;
  ITaskbarList3* taskbar_ = nullptr;
  HICON icons_[kGlyphCount] = {};
  State state_;
  // 标志位放成员末尾（同上：只留尾部对齐填充）。
  /// 任务栏当前是否浅色（决定用哪一套字形）。
  bool light_taskbar_ = false;
  /// 按钮是否已成功挂上；失败（窗口还没进任务栏）时留待下一次重试。
  bool buttons_added_ = false;
  /// 是否已收到过 Dart 的状态（没收到时按钮先按默认态挂上）。
  bool has_state_ = false;
};

#endif  // RUNNER_TASKBAR_THUMB_BAR_H_
