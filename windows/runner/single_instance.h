#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <functional>
#include <string>

struct SingleInstanceOptions {
  std::wstring application_id = L"HongguoTV.Client.v1";
  std::wstring executable_name = L"HongguoTV.exe";
  std::wstring product_name = L"\u7ea2\u679cTV";
  std::wstring window_class = L"FLUTTER_RUNNER_WIN32_WINDOW";
  std::wstring window_title = L"\u7ea2\u679cTV";
  DWORD activation_timeout_ms = 8000;
  DWORD message_timeout_ms = 1000;
  DWORD update_wait_ms = 10000;
};

enum class SingleInstanceResult {
  kPrimary,
  kActivated,
  kLegacyDetected,
  kBlocked,
  kError,
};

class SingleInstanceGuard {
 public:
  static constexpr LRESULT kActivationAccepted = 0x4847;

  explicit SingleInstanceGuard(SingleInstanceOptions options = {});
  ~SingleInstanceGuard();
  SingleInstanceGuard(const SingleInstanceGuard&) = delete;
  SingleInstanceGuard& operator=(const SingleInstanceGuard&) = delete;

  SingleInstanceResult Start(bool update_start = false);
  bool AttachWindow(HWND window);
  void DetachWindow();
  UINT ActivationMessage() const { return activation_message_; }
  bool HandleActivation(UINT message, LRESULT* result);
  void SetRestoreCallback(std::function<void()> callback);
  void SetDesktopReady(bool ready);
  void SetFirstFrameReady();
  bool activation_pending() const { return activation_pending_; }
  const std::wstring& error() const { return error_; }
  const std::wstring& mutex_name() const { return mutex_name_; }

 private:
  SingleInstanceResult CheckLegacy(bool update_start);
  SingleInstanceResult WaitForPrimary();
  HWND FindPrimaryWindow() const;
  void FlushActivation();

  SingleInstanceOptions options_;
  HANDLE mutex_ = nullptr;
  bool owns_mutex_ = false;
  HWND window_ = nullptr;
  UINT activation_message_ = 0;
  std::wstring sid_;
  std::wstring mutex_name_;
  std::wstring window_property_;
  std::wstring error_;
  std::function<void()> restore_;
  bool activation_pending_ = false;
  bool desktop_ready_ = false;
  bool closing_ = false;
  bool first_frame_ready_ = false;
};

#endif
