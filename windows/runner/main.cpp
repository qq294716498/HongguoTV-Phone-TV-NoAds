#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "app_branding.h"
#include "single_instance.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  const bool update_start = !command_line_arguments.empty() &&
      command_line_arguments.front() == "--windows-update-start";
  SingleInstanceGuard instance_guard;
  const auto instance_result = instance_guard.Start(update_start);
  if (instance_result != SingleInstanceResult::kPrimary) {
    if (instance_result == SingleInstanceResult::kActivated ||
        instance_result == SingleInstanceResult::kLegacyDetected) return EXIT_SUCCESS;
    if (update_start) {
      const std::string error = "Windows update startup refused: " +
          Utf8FromUtf16(instance_guard.error().c_str()) + "\r\n";
      DWORD written = 0;
      const HANDLE output = GetStdHandle(STD_ERROR_HANDLE);
      if (output && output != INVALID_HANDLE_VALUE)
        WriteFile(output, error.data(), static_cast<DWORD>(error.size()), &written, nullptr);
      OutputDebugStringW(instance_guard.error().c_str());
    } else {
      MessageBoxW(nullptr, instance_guard.error().c_str(), APP_WINDOW_TITLE,
          MB_OK | MB_ICONWARNING);
    }
    return EXIT_FAILURE;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, instance_guard);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(APP_WINDOW_TITLE, origin, size)) {
    return EXIT_FAILURE;
  }
  if (!instance_guard.AttachWindow(window.GetHandle())) {
    if (update_start) {
      OutputDebugStringW(instance_guard.error().c_str());
    } else {
      MessageBoxW(nullptr, instance_guard.error().c_str(), APP_WINDOW_TITLE,
          MB_OK | MB_ICONERROR);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
