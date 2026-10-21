#include "single_instance.h"

#include <sddl.h>
#include <tlhelp32.h>

#include <algorithm>
#include <array>
#include <cwchar>
#include <utility>
#include <vector>

namespace {
std::wstring ProcessSid(HANDLE process) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token)) return {};
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> storage(size);
  const bool read = size != 0 && GetTokenInformation(
      token, TokenUser, storage.data(), size, &size) != FALSE;
  CloseHandle(token);
  if (!read) return {};
  LPWSTR value = nullptr;
  const auto user = reinterpret_cast<const TOKEN_USER*>(storage.data());
  if (!ConvertSidToStringSidW(user->User.Sid, &value)) return {};
  std::wstring result(value);
  LocalFree(value);
  return result;
}

bool Exited(HANDLE process) {
  return WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
}

std::wstring VersionString(const std::vector<BYTE>& data, const wchar_t* name) {
  struct Translation { WORD language; WORD code_page; };
  Translation* translations = nullptr;
  UINT size = 0;
  if (!VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation",
      reinterpret_cast<void**>(&translations), &size)) return {};
  for (UINT index = 0; index < size / sizeof(Translation); ++index) {
    std::array<wchar_t, 160> key{};
    swprintf_s(key.data(), key.size(), L"\\StringFileInfo\\%04x%04x\\%s",
        static_cast<unsigned>(translations[index].language),
        static_cast<unsigned>(translations[index].code_page), name);
    LPWSTR value = nullptr;
    UINT length = 0;
    if (VerQueryValueW(data.data(), key.data(),
        reinterpret_cast<void**>(&value), &length) && length > 1) return value;
  }
  return {};
}

struct WindowSearch {
  const SingleInstanceOptions* options;
  const std::wstring* property;
  const std::wstring* sid;
  DWORD legacy_pid = 0;
  HWND found = nullptr;
};

BOOL CALLBACK FindWindowForInstance(HWND window, LPARAM parameter) {
  auto& search = *reinterpret_cast<WindowSearch*>(parameter);
  std::array<wchar_t, 256> name{};
  if (GetClassNameW(window, name.data(), static_cast<int>(name.size())) == 0 ||
      search.options->window_class != name.data()) return TRUE;
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (search.legacy_pid != 0) {
    if (pid != search.legacy_pid) return TRUE;
    std::array<wchar_t, 256> title{};
    GetWindowTextW(window, title.data(), static_cast<int>(title.size()));
    if (search.options->window_title != title.data()) return TRUE;
  } else {
    if (GetPropW(window, search.property->c_str()) !=
        reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(pid))) return TRUE;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return TRUE;
    const bool same_user = ProcessSid(process) == *search.sid;
    CloseHandle(process);
    if (!same_user) return TRUE;
  }
  search.found = window;
  return FALSE;
}
}

SingleInstanceGuard::SingleInstanceGuard(SingleInstanceOptions options)
    : options_(std::move(options)) {}

SingleInstanceGuard::~SingleInstanceGuard() {
  DetachWindow();
  if (owns_mutex_) ReleaseMutex(mutex_);
  if (mutex_) CloseHandle(mutex_);
}

SingleInstanceResult SingleInstanceGuard::Start(bool update_start) {
  if (mutex_) {
    error_ = L"The application instance guard has already started.";
    return SingleInstanceResult::kError;
  }
  sid_ = ProcessSid(GetCurrentProcess());
  if (sid_.empty()) {
    error_ = L"Unable to identify the current Windows user. No second client was started.";
    return SingleInstanceResult::kError;
  }
  mutex_name_ = L"Global\\" + options_.application_id + L"." + sid_;
  window_property_ = options_.application_id + L".Window." + sid_;
  activation_message_ = RegisterWindowMessageW(
      (options_.application_id + L".Restore." + sid_).c_str());
  mutex_ = CreateMutexW(nullptr, FALSE, mutex_name_.c_str());
  if (!mutex_ || !activation_message_) {
    error_ = L"Unable to initialize the application instance guard. No second client was started.";
    return SingleInstanceResult::kError;
  }
  const DWORD wait = WaitForSingleObject(mutex_, update_start ? options_.update_wait_ms : 0);
  if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
    owns_mutex_ = true;
    return CheckLegacy(update_start);
  }
  if (wait != WAIT_TIMEOUT) {
    error_ = L"Unable to inspect the existing application instance. No second client was started.";
    return SingleInstanceResult::kError;
  }
  if (update_start) {
    error_ = L"Another client for this Windows user is still running. Update startup was refused.";
    return SingleInstanceResult::kBlocked;
  }
  return WaitForPrimary();
}

SingleInstanceResult SingleInstanceGuard::WaitForPrimary() {
  const ULONGLONG deadline = GetTickCount64() + options_.activation_timeout_ms;
  do {
    const DWORD wait = WaitForSingleObject(mutex_, 0);
    if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
      owns_mutex_ = true;
      return CheckLegacy(false);
    }
    if (wait != WAIT_TIMEOUT) break;
    const HWND existing = FindPrimaryWindow();
    if (existing) {
      DWORD pid = 0;
      GetWindowThreadProcessId(existing, &pid);
      AllowSetForegroundWindow(pid);
      DWORD_PTR response = 0;
      const ULONGLONG now = GetTickCount64();
      const DWORD remaining = static_cast<DWORD>(std::min<ULONGLONG>(
          deadline > now ? deadline - now : 1, options_.message_timeout_ms));
      if (SendMessageTimeoutW(existing, activation_message_, 0, 0,
          SMTO_ABORTIFHUNG | SMTO_BLOCK, std::max<DWORD>(remaining, 1), &response) &&
          response == static_cast<DWORD_PTR>(kActivationAccepted)) {
        return SingleInstanceResult::kActivated;
      }
    }
    if (GetTickCount64() >= deadline) break;
    Sleep(50);
  } while (GetTickCount64() < deadline);
  error_ = L"The existing client is still starting or is not responding. The restore request could not be confirmed; no second client was started.";
  return SingleInstanceResult::kBlocked;
}

HWND SingleInstanceGuard::FindPrimaryWindow() const {
  WindowSearch search{&options_, &window_property_, &sid_};
  EnumWindows(FindWindowForInstance, reinterpret_cast<LPARAM>(&search));
  return search.found;
}

SingleInstanceResult SingleInstanceGuard::CheckLegacy(bool update_start) {
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    error_ = L"Unable to inspect older application clients. No second client was started.";
    return SingleInstanceResult::kError;
  }
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  std::vector<DWORD> legacy;
  bool unknown = false;
  if (!Process32FirstW(snapshot, &entry)) unknown = true;
  else do {
    if (entry.th32ProcessID == GetCurrentProcessId() ||
        _wcsicmp(entry.szExeFile, options_.executable_name.c_str()) != 0) continue;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
        FALSE, entry.th32ProcessID);
    if (!process) {
      if (GetLastError() != ERROR_INVALID_PARAMETER) unknown = true;
      continue;
    }
    const std::wstring owner = ProcessSid(process);
    if (owner.empty()) {
      if (!Exited(process)) unknown = true;
      CloseHandle(process);
      continue;
    }
    if (owner != sid_) { CloseHandle(process); continue; }
    std::array<wchar_t, 32768> path{};
    DWORD length = static_cast<DWORD>(path.size());
    if (!QueryFullProcessImageNameW(process, 0, path.data(), &length)) {
      if (!Exited(process)) unknown = true;
      CloseHandle(process);
      continue;
    }
    const DWORD size = GetFileVersionInfoSizeW(path.data(), nullptr);
    std::vector<BYTE> version(size);
    if (size == 0 || !GetFileVersionInfoW(path.data(), 0, size, version.data())) {
      if (!Exited(process)) unknown = true;
      CloseHandle(process);
      continue;
    }
    const bool branded = VersionString(version, L"ProductName") == options_.product_name &&
        _wcsicmp(VersionString(version, L"OriginalFilename").c_str(),
            options_.executable_name.c_str()) == 0;
    if (branded && VersionString(version, L"HongguoSingleInstance") != L"1" &&
        !Exited(process)) legacy.push_back(entry.th32ProcessID);
    CloseHandle(process);
  } while (Process32NextW(snapshot, &entry));
  if (GetLastError() != ERROR_NO_MORE_FILES) unknown = true;
  CloseHandle(snapshot);
  if (unknown) {
    error_ = L"An older client could not be identified safely. Close other copies for this Windows user and try again; no second client was started.";
    return SingleInstanceResult::kBlocked;
  }
  if (legacy.empty()) return SingleInstanceResult::kPrimary;
  if (!update_start) {
    for (const DWORD pid : legacy) {
      WindowSearch search{&options_, &window_property_, &sid_, pid};
      EnumWindows(FindWindowForInstance, reinterpret_cast<LPARAM>(&search));
      if (!search.found) continue;
      AllowSetForegroundWindow(pid);
      DWORD_PTR response = 0;
      if (SendMessageTimeoutW(search.found, WM_COMMAND, 41001, 0,
          SMTO_ABORTIFHUNG | SMTO_BLOCK, options_.message_timeout_ms, &response)) {
        if (IsIconic(search.found)) SendMessageTimeoutW(search.found,
            WM_SYSCOMMAND, SC_RESTORE, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK,
            options_.message_timeout_ms, &response);
        return SingleInstanceResult::kLegacyDetected;
      }
    }
  }
  error_ = L"An older client for this Windows user is running. Its restore request could not be confirmed. Close it normally before starting this version; no second client was started.";
  return SingleInstanceResult::kBlocked;
}

bool SingleInstanceGuard::AttachWindow(HWND window) {
  if (!owns_mutex_ || !window || !SetPropW(window, window_property_.c_str(),
      reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(GetCurrentProcessId())))) {
    error_ = L"Unable to register the application window for restore requests.";
    return false;
  }
  window_ = window;
  return true;
}

void SingleInstanceGuard::DetachWindow() {
  if (window_) RemovePropW(window_, window_property_.c_str());
  window_ = nullptr;
}

bool SingleInstanceGuard::HandleActivation(UINT message, LRESULT* result) {
  if (activation_message_ == 0 || message != activation_message_) return false;
  if (closing_) {
    if (result) *result = 0;
    return true;
  }
  activation_pending_ = true;
  FlushActivation();
  if (result) *result = kActivationAccepted;
  return true;
}

void SingleInstanceGuard::SetRestoreCallback(std::function<void()> callback) {
  restore_ = std::move(callback);
  FlushActivation();
}

void SingleInstanceGuard::SetDesktopReady(bool ready) {
  desktop_ready_ = ready;
  closing_ = !ready;
  if (closing_) activation_pending_ = false;
  FlushActivation();
}

void SingleInstanceGuard::SetFirstFrameReady() {
  first_frame_ready_ = true;
  FlushActivation();
}

void SingleInstanceGuard::FlushActivation() {
  if (!activation_pending_ || !desktop_ready_ || !first_frame_ready_ || !restore_) return;
  activation_pending_ = false;
  restore_();
}
