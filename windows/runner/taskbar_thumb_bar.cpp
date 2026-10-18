#include "taskbar_thumb_bar.h"

#include <combaseapi.h>

#include <cwchar>

#include "resource.h"

namespace {

// 按钮 ID：只在本窗口内唯一，点击时 WM_COMMAND 的低字带回来。
constexpr UINT kIdPrevious = 1;
constexpr UINT kIdPlayPause = 2;
constexpr UINT kIdNext = 3;
constexpr UINT kIdFavorite = 4;

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
  DestroyIcons();
  if (taskbar_ != nullptr) {
    taskbar_->Release();
    taskbar_ = nullptr;
  }
}

UINT TaskbarThumbBar::TaskbarCreatedMessage() {
  static const UINT message = RegisterWindowMessageW(L"TaskbarCreated");
  return message;
}

void TaskbarThumbBar::Attach(HWND window, ActionCallback on_action) {
  window_ = window;
  on_action_ = std::move(on_action);
}

void TaskbarThumbBar::AddButtons() {
  if (window_ == nullptr || window_ == INVALID_HANDLE_VALUE) {
    return;
  }
  if (taskbar_ == nullptr) {
    ITaskbarList3* taskbar = nullptr;
    if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                               CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar))) ||
        taskbar == nullptr) {
      return;
    }
    if (FAILED(taskbar->HrInit())) {
      taskbar->Release();
      return;
    }
    taskbar_ = taskbar;
  }
  const bool light = ReadSystemUsesLightTheme();
  if (light != light_taskbar_) {
    // 两次挂按钮之间主题变过：缓存里是上一套字形，必须重载。
    light_taskbar_ = light;
    DestroyIcons();
  }
  ApplyState(/*add=*/true);
}

void TaskbarThumbBar::UpdateState(const State& state) {
  if (has_state_ && Equals(state_, state)) {
    return;
  }
  state_ = state;
  has_state_ = true;
  if (buttons_added_) {
    ApplyState(/*add=*/false);
  }
}

void TaskbarThumbBar::RefreshThemeIcons() {
  const bool light = ReadSystemUsesLightTheme();
  if (light == light_taskbar_) {
    return;
  }
  light_taskbar_ = light;
  DestroyIcons();
  if (buttons_added_) {
    ApplyState(/*add=*/false);
  }
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

void TaskbarThumbBar::ApplyState(bool add) {
  if (taskbar_ == nullptr || window_ == nullptr) {
    return;
  }
  const bool enabled = state_.has_track;
  THUMBBUTTON buttons[kButtonCount] = {};
  auto setup = [&](int index, UINT id, Glyph glyph, bool usable,
                   const std::wstring& tooltip) {
    buttons[index].dwMask = static_cast<THUMBBUTTONMASK>(
        THUMBBUTTONMASK_THUMBNAIL | THUMBBUTTONMASK_FLAGS |
        THUMBBUTTONMASK_TOOLTIP);
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

  const HRESULT result =
      add ? taskbar_->ThumbBarAddButtons(window_, kButtonCount, buttons)
          : taskbar_->ThumbBarUpdateButtons(window_, kButtonCount, buttons);
  // 失败（窗口还没进任务栏等）时留 false：下一次 AddButtons（显示 / 任务栏
  // 重建）会重试；工具栏一旦挂上就不再回退，避免中途把按钮清掉。
  buttons_added_ = buttons_added_ || SUCCEEDED(result);
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
