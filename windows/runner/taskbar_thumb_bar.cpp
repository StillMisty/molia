#include "taskbar_thumb_bar.h"

#include <combaseapi.h>

#include <cwchar>
#include <utility>

#include "resource.h"

namespace {

// 按钮 ID：只在本窗口内唯一，点击时 WM_COMMAND 的低字带回来。
constexpr UINT kIdPrevious = 1;
constexpr UINT kIdPlayPause = 2;
constexpr UINT kIdNext = 3;
constexpr UINT kIdFavorite = 4;

// 重试定时器 id（WM_TIMER 的 wParam）：只在本窗口内唯一。
constexpr UINT_PTR kRetryTimerId = 0x4D01;

// 字形 → 图标资源：深色任务栏用亮字形，浅色任务栏用暗字形。
struct GlyphResources {
  int dark;
  int light;
};

constexpr GlyphResources kGlyphResources[] = {
    {IDI_TB_PREVIOUS_DARK, IDI_TB_PREVIOUS_LIGHT},
    {IDI_TB_PLAY_DARK, IDI_TB_PLAY_LIGHT},
    {IDI_TB_PAUSE_DARK, IDI_TB_PAUSE_LIGHT},
    {IDI_TB_NEXT_DARK, IDI_TB_NEXT_LIGHT},
    {IDI_TB_FAVORITE_DARK, IDI_TB_FAVORITE_LIGHT},
    {IDI_TB_FAVORITE_ON_DARK, IDI_TB_FAVORITE_ON_LIGHT},
};

// 任务栏浮层背景跟随系统主题（不是应用的 AppsUseLightTheme）。
bool ReadSystemUsesLightTheme() {
  DWORD value = 0;
  DWORD size = sizeof(value);
  const LONG result = RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"SystemUsesLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
  // 读不到时按深色处理：Windows 11 默认任务栏是深色，亮字形在两种背景下
  // 都不会完全看不见。
  return result == ERROR_SUCCESS && value != 0;
}

}  // namespace

TaskbarThumbBar::TaskbarThumbBar() = default;

TaskbarThumbBar::~TaskbarThumbBar() {
  CancelRetryTimer();
  DestroyIcons();
  if (taskbar_ != nullptr) {
    taskbar_->Release();
    taskbar_ = nullptr;
  }
}

UINT TaskbarThumbBar::TaskbarButtonCreatedMessage() {
  static const UINT message = RegisterWindowMessageW(L"TaskbarButtonCreated");
  return message;
}

UINT TaskbarThumbBar::TaskbarCreatedMessage() {
  static const UINT message = RegisterWindowMessageW(L"TaskbarCreated");
  return message;
}

void TaskbarThumbBar::Attach(HWND window, ActionCallback on_action,
                             DiagnosticCallback on_diagnostic) {
  window_ = window;
  on_action_ = std::move(on_action);
  on_diagnostic_ = std::move(on_diagnostic);
}

void TaskbarThumbBar::OnTaskbarButtonCreated() {
  Report("taskbar_button_created", S_OK);
  // 刚建出来的按钮一定没有工具栏：复位后走一次真正的 Add。
  button_created_ = true;
  buttons_added_ = false;
  ResetRetries();
  EnsureButtons();
}

void TaskbarThumbBar::OnShow() {
  // 隐藏期间任务栏按钮会消失（工具栏随之一并失效），恢复显示后按需重挂：
  // 已挂上先走 Update，失败自动回落 Add（见 EnsureButtons）。
  ResetRetries();
  EnsureButtons();
}

void TaskbarThumbBar::OnTaskbarRestarted() {
  Report("taskbar_restarted", S_OK);
  // 旧任务栏连同工具栏一起没了；新任务栏会再发 TaskbarButtonCreated。
  button_created_ = false;
  buttons_added_ = false;
  ResetRetries();
}

void TaskbarThumbBar::UpdateState(const State& state) {
  if (has_state_ && Equals(state_, state)) {
    return;
  }
  state_ = state;
  has_state_ = true;
  // 这里同时是一条重试路径：按钮还没挂上时（首发失败 / 等 TaskbarButtonCreated）
  // 每次状态变化都再试一次——Dart 侧播放、收藏、语言变化都会走到这里。
  EnsureButtons();
}

void TaskbarThumbBar::RefreshThemeIcons() {
  const bool light = ReadSystemUsesLightTheme();
  if (light == light_taskbar_) {
    return;
  }
  light_taskbar_ = light;
  DestroyIcons();
  EnsureButtons();
}

bool TaskbarThumbBar::HandleCommand(WPARAM wparam) {
  if (HIWORD(wparam) != THBN_CLICKED || on_action_ == nullptr) {
    return false;
  }
  switch (LOWORD(wparam)) {
    case kIdPrevious:
      on_action_(Action::kPrevious);
      return true;
    case kIdPlayPause:
      on_action_(Action::kPlayPause);
      return true;
    case kIdNext:
      on_action_(Action::kNext);
      return true;
    case kIdFavorite:
      on_action_(Action::kFavorite);
      return true;
    default:
      return false;
  }
}

bool TaskbarThumbBar::HandleTimer(WPARAM wparam) {
  if (wparam != kRetryTimerId) {
    return false;
  }
  // 不在这里复位重试预算：连续失败时预算只会减少，耗尽后等下一次触发点
  // （新按钮 / 重新显示 / 状态变化），不会变成死循环打定时器。
  CancelRetryTimer();
  EnsureButtons();
  return true;
}

void TaskbarThumbBar::EnsureButtons() {
  if (!button_created_ || window_ == nullptr) {
    // 规范门：还没收到 TaskbarButtonCreated 时调用任务栏接口无效（见类注释）。
    return;
  }
  InitializeTaskbar();
  if (taskbar_ == nullptr) {
    ScheduleRetry();
    return;
  }
  const bool light = ReadSystemUsesLightTheme();
  if (light != light_taskbar_) {
    // 上一次挂按钮之后主题变过：缓存里是上一套字形，必须重载。
    light_taskbar_ = light;
    DestroyIcons();
  }
  const bool add = !buttons_added_;
  HRESULT result = ApplyState(add);
  Report(add ? "thumbar_add" : "thumbar_update", result);
  if (SUCCEEDED(result)) {
    buttons_added_ = true;
    CancelRetryTimer();
    return;
  }
  if (!add) {
    // 已挂上的工具栏可能已经随任务栏按钮一起没了（隐藏后再显示）：回落重挂。
    buttons_added_ = false;
    result = ApplyState(/*add=*/true);
    Report("thumbar_readd", result);
    if (SUCCEEDED(result)) {
      buttons_added_ = true;
      CancelRetryTimer();
      return;
    }
  }
  ScheduleRetry();
}

HRESULT TaskbarThumbBar::ApplyState(bool add) {
  if (taskbar_ == nullptr || window_ == nullptr) {
    return E_UNEXPECTED;
  }
  const bool enabled = state_.has_track;
  THUMBBUTTON buttons[kButtonCount] = {};
  auto setup = [&](int index, UINT id, Glyph glyph, bool usable,
                   const std::wstring& tooltip) {
    buttons[index].dwMask = static_cast<THUMBBUTTONMASK>(
        THB_ICON | THB_TOOLTIP | THB_FLAGS);
    buttons[index].iId = id;
    buttons[index].iBitmap = 0;
    buttons[index].hIcon = IconFor(glyph);
    // 任务栏自己画禁用/按下/悬浮态，这里只给「可用」与图标。
    buttons[index].dwFlags = usable ? THBF_ENABLED : THBF_DISABLED;
    wcsncpy_s(buttons[index].szTip, tooltip.c_str(), _TRUNCATE);
  };
  // 顺序即浮层里的左右顺序：收藏 / 上一首 / 播放暂停 / 下一首。
  setup(0, kIdFavorite, state_.is_favorite ? Glyph::kFavoriteOn
                                           : Glyph::kFavorite,
        enabled, state_.tooltip_favorite);
  setup(1, kIdPrevious, Glyph::kPrevious, enabled, state_.tooltip_previous);
  setup(2, kIdPlayPause, state_.is_playing ? Glyph::kPause : Glyph::kPlay,
        enabled, state_.tooltip_play_pause);
  setup(3, kIdNext, Glyph::kNext, enabled, state_.tooltip_next);

  return add ? taskbar_->ThumbBarAddButtons(window_, kButtonCount, buttons)
             : taskbar_->ThumbBarUpdateButtons(window_, kButtonCount, buttons);
}

void TaskbarThumbBar::InitializeTaskbar() {
  if (taskbar_ != nullptr) {
    return;
  }
  ITaskbarList3* taskbar = nullptr;
  HRESULT result = CoCreateInstance(CLSID_TaskbarList, nullptr,
                                    CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar));
  if (FAILED(result) || taskbar == nullptr) {
    Report("taskbar_create_failed", result);
    return;
  }
  result = taskbar->HrInit();
  if (FAILED(result)) {
    Report("taskbar_init_failed", result);
    taskbar->Release();
    return;
  }
  taskbar_ = taskbar;
}

void TaskbarThumbBar::ScheduleRetry() {
  if (window_ == nullptr || retries_left_ <= 0) {
    return;
  }
  retries_left_--;
  SetTimer(window_, kRetryTimerId, kRetryDelayMs, nullptr);
}

void TaskbarThumbBar::CancelRetryTimer() {
  if (window_ != nullptr) {
    KillTimer(window_, kRetryTimerId);
  }
}

void TaskbarThumbBar::ResetRetries() {
  retries_left_ = kMaxRetries;
  CancelRetryTimer();
}

void TaskbarThumbBar::Report(const char* event, HRESULT hr) {
  if (on_diagnostic_ != nullptr) {
    on_diagnostic_(event, hr);
  }
}

HICON TaskbarThumbBar::IconFor(Glyph glyph) {
  const int index = static_cast<int>(glyph);
  if (icons_[index] != nullptr) {
    return icons_[index];
  }
  const GlyphResources& resources = kGlyphResources[index];
  const int resource_id = light_taskbar_ ? resources.light : resources.dark;
  // Windows 要求按钮图标为 32 位且尺寸为 SM_CXICON × SM_CYICON（100% 缩放下
  // 32×32，150% 下 48）：按系统度量取，让系统直接命中 .ico 里的对应档位。
  icons_[index] = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(resource_id), IMAGE_ICON,
      GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0));
  return icons_[index];
}

void TaskbarThumbBar::DestroyIcons() {
  for (HICON& icon : icons_) {
    if (icon != nullptr) {
      DestroyIcon(icon);
      icon = nullptr;
    }
  }
}

bool TaskbarThumbBar::Equals(const State& left, const State& right) const {
  return left.has_track == right.has_track &&
         left.is_playing == right.is_playing &&
         left.is_favorite == right.is_favorite &&
         left.tooltip_previous == right.tooltip_previous &&
         left.tooltip_play_pause == right.tooltip_play_pause &&
         left.tooltip_next == right.tooltip_next &&
         left.tooltip_favorite == right.tooltip_favorite;
}
