// Synthetic Win32 test host. Never use the production application identity.
#include <windows.h>

#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <sstream>
#include <string>

#include "single_instance.h"

namespace {
constexpr wchar_t kPrefix[] = L"HongguoTV.NativeHarness.";
constexpr wchar_t kExecutable[] = L"single_instance_harness.exe";
constexpr wchar_t kProduct[] = L"HongguoTV Single Instance Harness";
std::map<std::wstring, std::wstring> args;
std::unique_ptr<SingleInstanceGuard> guard;
HWND window = nullptr;
std::wstring report_path, control_path, result_name, error_text, mutex_name;
ULONGLONG started = 0, started_guard = 0, guard_elapsed = 0;
DWORD attach_delay = 0, lifetime = 20000, child_pid = 0;
unsigned long last_command = 0, restores = 0, toggles = 0;
bool attached = false, legacy = false, hold_only = false;
bool desktop_ready = true, first_frame_ready = true, paused = true;
bool hang_activation = false, update_start = false, ack = false;
bool mutex_exists = false;

std::wstring Arg(const wchar_t* name, const wchar_t* fallback = L"") {
  auto it = args.find(name);
  return it == args.end() ? fallback : it->second;
}
DWORD Number(const wchar_t* name, DWORD fallback) {
  const auto value = Arg(name);
  return value.empty() ? fallback : static_cast<DWORD>(std::stoul(value));
}
std::string Json(const std::wstring& value) {
  std::ostringstream out;
  out << '"';
  for (wchar_t c : value) {
    if (c == '"' || c == '\\') out << '\\' << static_cast<char>(c);
    else if (c >= 32 && c < 127) out << static_cast<char>(c);
    else {
      const char hex[] = "0123456789abcdef";
      out << "\\u" << hex[(c >> 12) & 15] << hex[(c >> 8) & 15]
          << hex[(c >> 4) & 15] << hex[c & 15];
    }
  }
  out << '"';
  return out.str();
}
const char* Bool(bool value) { return value ? "true" : "false"; }
void Report() {
  const auto temporary = report_path + L".tmp." + std::to_wstring(GetCurrentProcessId());
  std::ofstream out(std::filesystem::path(temporary), std::ios::binary | std::ios::trunc);
  out << "{\"result\":" << Json(result_name)
      << ",\"pid\":" << GetCurrentProcessId()
      << ",\"hwnd\":" << reinterpret_cast<UINT_PTR>(window)
      << ",\"attached\":" << Bool(attached)
      << ",\"visible\":" << Bool(window && IsWindowVisible(window))
      << ",\"minimized\":" << Bool(window && IsIconic(window))
      << ",\"paused\":" << Bool(paused)
      << ",\"desktop_ready\":" << Bool(desktop_ready)
      << ",\"first_frame_ready\":" << Bool(first_frame_ready)
      << ",\"pending\":" << Bool(guard && guard->activation_pending())
      << ",\"restores\":" << restores << ",\"toggles\":" << toggles
      << ",\"command\":" << last_command << ",\"elapsed_ms\":" << guard_elapsed
      << ",\"mutex\":" << Json(mutex_name) << ",\"error\":" << Json(error_text)
      << ",\"ack\":" << Bool(ack) << ",\"child_pid\":" << child_pid
      << ",\"mutex_exists\":" << Bool(mutex_exists) << "}";
  out.close();
  MoveFileExW(temporary.c_str(), report_path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}
void RestoreOwnWindow() {
  const DWORD delay = restores == 0 ? Number(L"restore-delay-once", 0) : 0;
  if (delay) Sleep(delay);
  ++restores;
  if (window) ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOWNOACTIVATE);
  Report();
}
void ReadControl() {
  if (control_path.empty()) return;
  std::ifstream input{std::filesystem::path(control_path)};
  unsigned long sequence = 0;
  std::string command;
  if (!(input >> sequence >> command) || sequence <= last_command) return;
  last_command = sequence;
  if (command == "close") PostQuitMessage(0);
  else if (command == "hide" && window) ShowWindow(window, SW_HIDE);
  else if (command == "minimize" && window) ShowWindow(window, SW_MINIMIZE);
  else if (command == "suspend") {
    desktop_ready = false;
    if (guard) guard->SetDesktopReady(false);
  }
  else if (command == "desktop") {
    desktop_ready = true;
    if (guard) guard->SetDesktopReady(true);
  } else if (command == "frame") {
    first_frame_ready = true;
    if (guard) guard->SetFirstFrameReady();
  } else if (command == "probe") {
    HANDLE probe = CreateMutexW(nullptr, FALSE, Arg(L"probe-mutex").c_str());
    mutex_exists = probe && GetLastError() == ERROR_ALREADY_EXISTS;
    if (probe) CloseHandle(probe);
  }
  Report();
}
LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (guard && message == guard->ActivationMessage()) {
    if (hang_activation) Sleep(2200);
    LRESULT response = 0;
    if (guard->HandleActivation(message, &response)) {
      Report();
      return response;
    }
  }
  if (message == WM_COMMAND) {
    if (LOWORD(wparam) == 41001) RestoreOwnWindow();
    if (LOWORD(wparam) == 41002) { ++toggles; paused = !paused; Report(); }
    return 0;
  }
  if (message == WM_CLOSE) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
void SpawnInheritedChild(const std::wstring& own_executable) {
  const auto child_report = Arg(L"child-report");
  if (child_report.empty()) return;
  std::wstring command = L"\"" + own_executable + L"\" --test-isolation --hold-only"
      L" --application-id \"" + Arg(L"application-id") + L"\" --report \"" + child_report
      + L"\" --control \"" + Arg(L"child-control") + L"\" --probe-mutex \"" + mutex_name
      + L"\" --lifetime 15000";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, TRUE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
    error_text = L"Cannot create inherited child: " + std::to_wstring(GetLastError());
    return;
  }
  child_pid = process.dwProcessId;
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
}
std::wstring ResultName(SingleInstanceResult result) {
  switch (result) {
    case SingleInstanceResult::kPrimary: return L"primary";
    case SingleInstanceResult::kActivated: return L"activated";
    case SingleInstanceResult::kLegacyDetected: return L"legacy";
    case SingleInstanceResult::kBlocked: return L"blocked";
    default: return L"error";
  }
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  for (int i = 1; i < argc; ++i) {
    std::wstring key = argv[i];
    if (key.compare(0, 2, L"--") != 0) return 90;
    key.erase(0, 2);
    std::wstring value = L"1";
    if (i + 1 < argc && std::wstring(argv[i + 1]).compare(0, 2, L"--") != 0) value = argv[++i];
    args[key] = value;
  }
  if (Arg(L"test-isolation") != L"1" || Arg(L"application-id").find(kPrefix) != 0 ||
      Arg(L"report").empty()) return 91;
  wchar_t executable[32768]{};
  GetModuleFileNameW(nullptr, executable, 32768);
  if (_wcsicmp(std::filesystem::path(executable).filename().c_str(), kExecutable) != 0) return 92;
  report_path = Arg(L"report");
  control_path = Arg(L"control");
  started = GetTickCount64();
  lifetime = Number(L"lifetime", 20000);
  attach_delay = Number(L"attach-delay", 0);
  hold_only = Arg(L"hold-only") == L"1";
  legacy = Arg(L"legacy") == L"1";
  desktop_ready = Arg(L"ready", L"1") != L"0";
  first_frame_ready = desktop_ready;
  hang_activation = Arg(L"hang-activation") == L"1";
  update_start = Arg(L"update-start") == L"1";
  if (hold_only) {
    result_name = L"holder";
    Report();
  } else if (!legacy) {
    SingleInstanceOptions options;
    options.application_id = Arg(L"application-id");
    options.executable_name = kExecutable;
    options.product_name = kProduct;
    options.window_class = Arg(L"application-id") + L".Window";
    options.window_title = options.window_class;
    options.activation_timeout_ms = Number(L"activation-timeout", 2500);
    options.message_timeout_ms = Number(L"message-timeout", 1000);
    options.update_wait_ms = Number(L"update-wait", 800);
    guard = std::make_unique<SingleInstanceGuard>(options);
    started_guard = GetTickCount64();
    const auto result = guard->Start(update_start);
    guard_elapsed = GetTickCount64() - started_guard;
    result_name = ResultName(result);
    error_text = guard->error();
    mutex_name = guard->mutex_name();
    ack = update_start && result == SingleInstanceResult::kPrimary;
    Report();
    if (result != SingleInstanceResult::kPrimary) {
      return !update_start && (result == SingleInstanceResult::kActivated ||
                              result == SingleInstanceResult::kLegacyDetected) ? 0 : 4;
    }
    if (Arg(L"single-shot") == L"1") return 0;
  } else {
    result_name = L"legacy-owner";
    Report();
  }

  if (!hold_only && Arg(L"no-window") != L"1") {
    const auto window_class = Arg(L"application-id") + L".Window";
    WNDCLASSW type{};
    type.lpfnWndProc = WindowProc;
    type.hInstance = GetModuleHandleW(nullptr);
    type.lpszClassName = window_class.c_str();
    if (!RegisterClassW(&type)) return 93;
    window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, window_class.c_str(),
                            window_class.c_str(), WS_OVERLAPPEDWINDOW,
                            -24000, -24000, 120, 80, nullptr, nullptr, type.hInstance, nullptr);
    if (!window) return 94;
    if (Arg(L"visible", L"1") == L"1") ShowWindow(window, SW_SHOWNOACTIVATE);
    if (guard) {
      guard->SetRestoreCallback(RestoreOwnWindow);
      if (desktop_ready) guard->SetDesktopReady(true);
      if (first_frame_ready) guard->SetFirstFrameReady();
    }
    Report();
  }
  if (guard) SpawnInheritedChild(executable);
  Report();
  MSG message{};
  bool running = true;
  while (running && GetTickCount64() - started < lifetime) {
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) { running = false; break; }
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (guard && window && !attached && GetTickCount64() - started >= attach_delay) {
      attached = guard->AttachWindow(window);
      if (!attached) error_text = guard->error();
      Report();
    }
    ReadControl();
    Sleep(10);
  }
  if (guard) guard->DetachWindow();
  if (window) DestroyWindow(window);
  window = nullptr;
  guard.reset();
  Report();
  return 0;
}
