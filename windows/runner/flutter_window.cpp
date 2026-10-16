#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 42;
constexpr UINT kRestore = 41001;
constexpr UINT kToggle = 41002;
constexpr UINT kQuit = 41003;
}

bool FlutterWindow::AddTray() {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = 1;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"红果TV · 右键恢复 / 播放暂停 / 退出");
  tray_active_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  if (tray_active_) {
    icon.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &icon);
  }
  return tray_active_;
}

void FlutterWindow::RemoveTray() {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  tray_active_ = false;
}

void FlutterWindow::TrayAction(const char* action) {
  if (desktop_channel_) desktop_channel_->InvokeMethod("trayAction",
    std::make_unique<flutter::EncodableValue>(action));
}

void FlutterWindow::TrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kRestore, L"恢复窗口");
  AppendMenuW(menu, MF_STRING | (playback_attached_ ? MF_ENABLED : MF_GRAYED),
    kToggle, playing_ ? L"暂停" : L"播放");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kQuit, L"退出红果TV");
  POINT position{};
  GetCursorPos(&position);
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
    position.x, position.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  PostMessage(GetHandle(), WM_NULL, 0, 0);
  if (command == kRestore) TrayAction("restore");
  if (command == kToggle && playback_attached_) TrayAction("toggle");
  if (command == kQuit) TrayAction("quit");
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  desktop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    flutter_controller_->engine()->messenger(), "duanju/desktop",
    &flutter::StandardMethodCodec::GetInstance());
  desktop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "initialize") {
      result->Success(flutter::EncodableValue(tray_active_ || AddTray()));
    } else if (call.method_name() == "dispose") {
      RemoveTray();
      result->Success();
    } else if (call.method_name() == "setPlayback") {
      const auto* values = std::get_if<flutter::EncodableMap>(call.arguments());
      auto flag = [values](const char* name) {
        if (!values) return false;
        const auto found = values->find(flutter::EncodableValue(name));
        return found != values->end() && std::holds_alternative<bool>(found->second)
          && std::get<bool>(found->second);
      };
      playback_attached_ = flag("attached");
      playing_ = flag("playing");
      result->Success();
    } else { result->NotImplemented(); }
  });
  device_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "duanju/device",
          &flutter::StandardMethodCodec::GetInstance());
  device_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setPlaybackScreenOn") {
          const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
          bool enabled = false;
          if (arguments) {
            const auto value = arguments->find(flutter::EncodableValue("enabled"));
            if (value != arguments->end()) {
              const auto* flag = std::get_if<bool>(&value->second);
              enabled = flag && *flag;
            }
          }
          const EXECUTION_STATE state = enabled
              ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED
              : ES_CONTINUOUS;
          if (SetThreadExecutionState(state) == 0) {
            result->Error("screen_on", "Unable to update playback power state");
          } else {
            result->Success();
          }
          return;
        }
        if (call.method_name() != "playbackPower") {
          result->NotImplemented();
          return;
        }
        SYSTEM_POWER_STATUS power{};
        const bool known = GetSystemPowerStatus(&power) != 0;
        MEMORYSTATUSEX memory{};
        memory.dwLength = sizeof(memory);
        const bool memory_known = GlobalMemoryStatusEx(&memory) != 0;
        flutter::EncodableMap values;
        values[flutter::EncodableValue("batterySaver")] =
            flutter::EncodableValue(known && power.SystemStatusFlag == 1);
        values[flutter::EncodableValue("onBattery")] =
            flutter::EncodableValue(!known || power.ACLineStatus != 1);
        values[flutter::EncodableValue("lowMemory")] =
            flutter::EncodableValue(!memory_known || memory.ullTotalPhys < 4ULL * 1024 * 1024 * 1024);
        result->Success(flutter::EncodableValue(values));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTray();
  desktop_channel_.reset();
  SetThreadExecutionState(ES_CONTINUOUS);
  device_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  static const UINT taskbar_created = RegisterWindowMessage(L"TaskbarCreated");
  if (taskbar_created != 0 && message == taskbar_created && tray_active_) AddTray();
  if (message == kTrayMessage && tray_active_) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONDBLCLK) TrayAction("restore");
    if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) TrayMenu();
    return 0;
  }
  if (message == WM_COMMAND && tray_active_) {
    if (LOWORD(wparam) == kRestore) { TrayAction("restore"); return 0; }
    if (LOWORD(wparam) == kToggle && playback_attached_) { TrayAction("toggle"); return 0; }
    if (LOWORD(wparam) == kQuit) { TrayAction("quit"); return 0; }
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
