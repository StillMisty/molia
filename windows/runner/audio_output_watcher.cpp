#include "audio_output_watcher.h"

#include <algorithm>
#include <utility>

namespace {

// 设备 id 只用于比较，长度很小；拷贝到窗口线程后再做存活判断。
std::wstring ToWString(LPCWSTR value) {
  return value == nullptr ? std::wstring() : std::wstring(value);
}

}  // namespace

AudioOutputWatcher::AudioOutputWatcher() = default;

AudioOutputWatcher::~AudioOutputWatcher() { Stop(); }

bool AudioOutputWatcher::Start(HWND window,
                               std::function<void()> on_output_lost) {
  if (started_) return true;
  if (window == nullptr || !on_output_lost) return false;

  window_.store(window);
  on_output_lost_ = std::move(on_output_lost);

  IMMDeviceEnumerator* enumerator = nullptr;
  const HRESULT create_result = ::CoCreateInstance(
      __uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
      IID_PPV_ARGS(&enumerator));
  if (FAILED(create_result) || enumerator == nullptr) {
    return false;
  }
  enumerator_ = enumerator;
  default_device_ = CurrentDefaultDevice();

  const HRESULT register_result =
      enumerator_->RegisterEndpointNotificationCallback(this);
  if (FAILED(register_result)) {
    enumerator_->Release();
    enumerator_ = nullptr;
    window_.store(nullptr);
    on_output_lost_ = nullptr;
    return false;
  }
  started_ = true;
  return true;
}

void AudioOutputWatcher::Stop() {
  if (enumerator_ != nullptr) {
    if (started_) {
      enumerator_->UnregisterEndpointNotificationCallback(this);
    }
    enumerator_->Release();
    enumerator_ = nullptr;
  }
  started_ = false;
  window_.store(nullptr);
  on_output_lost_ = nullptr;
  std::lock_guard<std::mutex> lock(pending_mutex_);
  pending_removed_devices_.clear();
  has_pending_default_ = false;
  pending_default_device_.clear();
  platform_message_pending_ = false;
}

std::wstring AudioOutputWatcher::CurrentDefaultDevice() const {
  if (enumerator_ == nullptr) return std::wstring();

  // mpv（just_audio_media_kit 的播放后端）在
  // `audio/out/ao_wasapi_changenotify.c` 里只跟随 eMultimedia：
  // `if (flow == eCapture || role != eMultimedia) return S_OK;`。
  // 第三方音频切换器可能让每个 role 的默认设备不同，因此优先查询
  // eMultimedia；没有该 role 的默认值时才退回 eConsole。
  const auto query_role = [this](ERole role) -> std::wstring {
    IMMDevice* device = nullptr;
    const HRESULT result =
        enumerator_->GetDefaultAudioEndpoint(eRender, role, &device);
    if (FAILED(result) || device == nullptr) return std::wstring();
    LPWSTR id = nullptr;
    std::wstring name;
    if (SUCCEEDED(device->GetId(&id)) && id != nullptr) {
      name = id;
      ::CoTaskMemFree(id);
    }
    device->Release();
    return name;
  };

  std::wstring name = query_role(eMultimedia);
  if (name.empty()) name = query_role(eConsole);
  return name;
}

bool AudioOutputWatcher::IsDeviceActive(const std::wstring& device_id) const {
  if (enumerator_ == nullptr || device_id.empty()) return false;
  IMMDevice* device = nullptr;
  if (FAILED(enumerator_->GetDevice(device_id.c_str(), &device)) ||
      device == nullptr) {
    // 设备已从枚举器消失：按不可用处理。
    return false;
  }
  DWORD state = 0;
  const bool active =
      SUCCEEDED(device->GetState(&state)) && state == DEVICE_STATE_ACTIVE;
  device->Release();
  return active;
}

void AudioOutputWatcher::PostPlatformMessage() {
  const HWND window = window_.load();
  if (window == nullptr) return;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    if (platform_message_pending_) return;
    platform_message_pending_ = true;
  }
  if (::PostMessageW(window, kOutputLostMessage, 0, 0) == FALSE) {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    platform_message_pending_ = false;
  }
}

void AudioOutputWatcher::HandlePlatformMessage() {
  if (enumerator_ == nullptr) return;

  std::wstring new_default;
  bool has_default = false;
  std::vector<std::wstring> removed;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    platform_message_pending_ = false;
    if (has_pending_default_) {
      has_default = true;
      new_default = pending_default_device_;
      has_pending_default_ = false;
      pending_default_device_.clear();
    }
    removed.swap(pending_removed_devices_);
  }

  bool output_lost = false;

  // 被删除 / 变为不活跃的证明设备就是当前跟踪的默认设备。
  if (!default_device_.empty()) {
    output_lost = std::any_of(removed.begin(), removed.end(),
                              [this](const std::wstring& id) {
                                return id == default_device_;
                              });
  }

  if (has_default) {
    if (new_default.empty()) {
      // 新默认为空（唯一输出被禁用 / 拔掉）。
      if (!default_device_.empty()) output_lost = true;
    } else if (!default_device_.empty() && new_default != default_device_ &&
               !IsDeviceActive(default_device_)) {
      // 只有旧设备真的不可用时才算丢失；两个都活着的主动切换继续播放。
      output_lost = true;
    }
  }

  // 事件可能先于设备状态更新到达：以枚举器此刻的默认值为准；为空则保留
  // 空字符串，下一次事件重新建立快照。
  default_device_ = CurrentDefaultDevice();

  if (output_lost && on_output_lost_) {
    on_output_lost_();
  }
}

HRESULT STDMETHODCALLTYPE AudioOutputWatcher::OnDeviceStateChanged(
    LPCWSTR device_id, DWORD new_state) {
  if (new_state != DEVICE_STATE_ACTIVE && device_id != nullptr) {
    {
      std::lock_guard<std::mutex> lock(pending_mutex_);
      pending_removed_devices_.emplace_back(device_id);
    }
    PostPlatformMessage();
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE AudioOutputWatcher::OnDeviceAdded(LPCWSTR) {
  // 新增设备不是输出丢失。
  return S_OK;
}

HRESULT STDMETHODCALLTYPE AudioOutputWatcher::OnDeviceRemoved(
    LPCWSTR device_id) {
  if (device_id != nullptr) {
    {
      std::lock_guard<std::mutex> lock(pending_mutex_);
      pending_removed_devices_.emplace_back(device_id);
    }
    PostPlatformMessage();
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE AudioOutputWatcher::OnDefaultDeviceChanged(
    EDataFlow flow, ERole role, LPCWSTR default_device_id) {
  // 播放后端（mpv/WASAPI）跟随 eMultimedia；部分系统上它与 eConsole 的默认
  // 值不同，所以两个 role 都接受。录音 / 通信设备变化无关。
  if (flow != eRender || (role != eMultimedia && role != eConsole)) return S_OK;
  {
    std::lock_guard<std::mutex> lock(pending_mutex_);
    pending_default_device_ = ToWString(default_device_id);
    has_pending_default_ = true;
  }
  PostPlatformMessage();
  return S_OK;
}

HRESULT STDMETHODCALLTYPE AudioOutputWatcher::OnPropertyValueChanged(
    LPCWSTR, const PROPERTYKEY) {
  // 设备属性（名称 / 图标等）变化不影响输出可用性。
  return S_OK;
}

HRESULT STDMETHODCALLTYPE AudioOutputWatcher::QueryInterface(REFIID riid,
                                                             void** object) {
  if (object == nullptr) return E_POINTER;
  if (riid == __uuidof(IUnknown) ||
      riid == __uuidof(IMMNotificationClient)) {
    *object = static_cast<IMMNotificationClient*>(this);
    AddRef();
    return S_OK;
  }
  *object = nullptr;
  return E_NOINTERFACE;
}

ULONG STDMETHODCALLTYPE AudioOutputWatcher::AddRef() {
  return ref_count_.fetch_add(1) + 1;
}

ULONG STDMETHODCALLTYPE AudioOutputWatcher::Release() {
  // 对象由 FlutterWindow 的 unique_ptr 持有，COM 不调用 AddRef / Release。
  // 即使未来有人调用，也只能递减计数，绝不能在这里 delete（会双重释放）。
  // 保底保留基引用 1。
  ULONG current = ref_count_.load();
  while (current > 1) {
    if (ref_count_.compare_exchange_weak(current, current - 1)) {
      return current - 1;
    }
  }
  return current;
}
