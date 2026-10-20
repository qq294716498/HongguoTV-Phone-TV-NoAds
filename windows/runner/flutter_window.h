#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"
#include "single_instance.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  FlutterWindow(const flutter::DartProject& project, SingleInstanceGuard& instance_guard);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;
  SingleInstanceGuard& instance_guard_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> device_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> desktop_channel_;
  bool tray_active_ = false;
  bool playback_attached_ = false;
  bool playing_ = false;
  HICON tray_icon_ = nullptr;
  bool AddTray();
  void RemoveTray();
  void TrayAction(const char* action);
  void TrayMenu();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
