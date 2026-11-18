#ifndef RUNNER_AUDIO_OUTPUT_WATCHER_H_
#define RUNNER_AUDIO_OUTPUT_WATCHER_H_

#include <windows.h>

#include <mmdeviceapi.h>
#include <propsys.h>

#include <atomic>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

// Windows 默认播放设备丢失监听（ADR-0036）。
//
// 只回答一件事：之前的默认 render 设备是否已经不可用。用户在两个仍然存活的
// 输出之间主动切换时不认为丢失；设备被拔掉 / 禁用 / 删除才上报。
//
// 线程模型：IMMNotificationClient 回调可能来自任意 COM worker 线程，回调里
// 只登记待处理事件并 PostMessage，真正的设备枚举、存活判断与 Flutter 通道
// 调用都在窗口线程执行（见 HandlePlatformMessage）。
class AudioOutputWatcher : public IMMNotificationClient {
 public:
  // 私有窗口消息：COM 回调把平台线程唤醒，窗口过程再调用
  // HandlePlatformMessage。
  static constexpr UINT kOutputLostMessage = WM_APP + 0x4F;  // 'O'

  AudioOutputWatcher();
  ~AudioOutputWatcher() override;

  AudioOutputWatcher(const AudioOutputWatcher&) = delete;
  AudioOutputWatcher& operator=(const AudioOutputWatcher&) = delete;

  // 创建设备枚举器、缓存当前默认设备并注册通知。失败返回 false（静默降级）。
  // 必须在窗口线程调用，窗口与 Flutter 通道已存在。
  bool Start(HWND window, std::function<void()> on_output_lost);

  // 注销通知并释放枚举器。幂等；必须在引擎 / COM 反初始化之前调用。
  void Stop();

  // 窗口线程处理 PostMessage 的待办事件。重复事件无害（Dart 侧暂停幂等）。
  void HandlePlatformMessage();

  // IMMNotificationClient：
  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR device_id,
                                                 DWORD new_state) override;
  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR device_id) override;
  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR device_id) override;
  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(
      EDataFlow flow, ERole role, LPCWSTR default_device_id) override;
  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR device_id,
                                                   const PROPERTYKEY key) override;

  // IUnknown：
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

 private:
  std::wstring CurrentDefaultDevice() const;
  bool IsDeviceActive(const std::wstring& device_id) const;
  void PostPlatformMessage();

  std::atomic<ULONG> ref_count_{1};
  HWND window_ = nullptr;
  std::function<void()> on_output_lost_;
  IMMDeviceEnumerator* enumerator_ = nullptr;
  bool started_ = false;

  // 最近一次已知的默认 render 设备（只由窗口线程读写）。
  std::wstring default_device_;

  // COM 回调线程写入、窗口线程取走。
  mutable std::mutex pending_mutex_;
  std::wstring pending_default_device_;
  bool has_pending_default_ = false;
  std::vector<std::wstring> pending_removed_devices_;
  bool platform_message_pending_ = false;
};

#endif  // RUNNER_AUDIO_OUTPUT_WATCHER_H_
