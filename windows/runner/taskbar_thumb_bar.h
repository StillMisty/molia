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
// 挂载时机是这条链路最容易踩的坑。任务栏按钮由 shell 异步创建，建好后 shell
// 会向窗口发 `TaskbarButtonCreated` 注册消息；MSDN 的 ITaskbarList3 页面写明
// **在收到这条消息之前调用任何 ITaskbarList3 方法都是无效的**（ThumbBarAddButtons
// 返回 E_INVALIDARG，按钮永远不会出现）。所以本类内部有一道 [button_created_]
// 门闩：只有宿主把 [OnTaskbarButtonCreated] 送进来之后才真正调用任务栏接口。
//
// 另外两种「按钮消失」的场景，处理方式与参考实现（LX Music 桌面端每次 show
// 与每次播放状态变化都重下发一次按钮）等价：
//   - 隐藏到托盘再显示：任务栏按钮重建、工具栏失效，按「更新失败就回落重挂」
//     恢复（见 [OnShow]）；
//   - Explorer 重启：整个任务栏重建，收到 TaskbarCreated 广播后复位门闩，
//     等新任务栏再发 TaskbarButtonCreated（见 [OnTaskbarRestarted]）。
// 挂载失败（任务栏还没准备好）会退避重试两次，之后等下一次触发点自愈；Dart
// 每次状态变化都会走到 [UpdateState]，它同时是一条重试路径。
//
// 按钮图标是原样绘制的、不随主题反色，因此按任务栏亮暗准备了两套（见
// tool/gen_taskbar_icons.py）。
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
  /// 诊断回调（事件名 + HRESULT）：宿主经方法通道回 Dart 落日志。这条链路只能
  /// 在真机上验证，真出问题时靠它区分「注册消息没来」与「调用失败」。
  using DiagnosticCallback = std::function<void(const char* event, HRESULT hr)>;

  TaskbarThumbBar();
  ~TaskbarThumbBar();

  TaskbarThumbBar(const TaskbarThumbBar&) = delete;
  TaskbarThumbBar& operator=(const TaskbarThumbBar&) = delete;

  // 绑定窗口、点击回调与诊断回调（窗口创建后调用一次）。
  void Attach(HWND window, ActionCallback on_action,
              DiagnosticCallback on_diagnostic = nullptr);

  // 收到「TaskbarButtonCreated」：任务栏按钮（重新）建好了，这是唯一可以安全
  // 调用 ThumbBarAddButtons 的时机。
  void OnTaskbarButtonCreated();
  // 窗口重新显示：任务栏按钮可能已经被重建，按需重挂。
  void OnShow();
  // 收到「TaskbarCreated」广播（Explorer 重启）：旧工具栏随旧任务栏一起没了，
  // 复位门闩等新任务栏发 TaskbarButtonCreated。
  void OnTaskbarRestarted();

  // 同步按钮可用性 / 图标 / tooltip（值没变不下发原生调用）。
  void UpdateState(const State& state);
  // 处理 WM_COMMAND：命中本工具栏按钮时返回 true（调用方直接吃掉消息）。
  bool HandleCommand(WPARAM wparam);
  // 处理 WM_TIMER：挂载失败后的退避重试（命中返回 true）。
  bool HandleTimer(WPARAM wparam);
  // 系统亮暗（SystemUsesLightTheme）变化后换一套按钮图标。
  void RefreshThemeIcons();

  // 「TaskbarButtonCreated」注册消息（shell 建好本窗口的任务栏按钮后发来）。
  static UINT TaskbarButtonCreatedMessage();
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
  // 挂载失败后的重试预算与间隔（毫秒）。
  static constexpr int kMaxRetries = 2;
  static constexpr UINT kRetryDelayMs = 400;

  // 按当前状态挂 / 更新按钮：门闩未开时是空操作，失败会安排退避重试。
  void EnsureButtons();
  // 把当前状态下发给任务栏：add=true 首次挂按钮，false 只更新字段。
  HRESULT ApplyState(bool add);
  void InitializeTaskbar();
  void ScheduleRetry();
  void CancelRetryTimer();
  void ResetRetries();
  void Report(const char* event, HRESULT hr);
  HICON IconFor(Glyph glyph);
  void DestroyIcons();
  bool Equals(const State& left, const State& right) const;

  HWND window_ = nullptr;
  ActionCallback on_action_;
  DiagnosticCallback on_diagnostic_;
  ITaskbarList3* taskbar_ = nullptr;
  HICON icons_[kGlyphCount] = {};
  State state_;
  // 标志位放成员末尾（同上：只留尾部对齐填充）。
  /// 任务栏当前是否浅色（决定用哪一套字形）。
  bool light_taskbar_ = false;
  /// 按钮是否已成功挂上；失败时留待重试。
  bool buttons_added_ = false;
  /// 是否已收到过 Dart 的状态（没收到时按钮先按默认态挂上）。
  bool has_state_ = false;
  /// 是否已经收到过 TaskbarButtonCreated（门闩，见类注释）。
  bool button_created_ = false;
  /// 剩余重试次数（每次新的触发点重置）。
  int retries_left_ = kMaxRetries;
};

#endif  // RUNNER_TASKBAR_THUMB_BAR_H_
