#include <windows.h>
#include <bcrypt.h>
#include <tlhelp32.h>
#include <algorithm>
#include <array>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include "../runner/single_instance.h"

namespace fs = std::filesystem;

std::wstring Wide(const std::string& value) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) throw std::runtime_error("Invalid UTF-8");
  std::wstring result(size, 0);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size);
  return result;
}

bool Equal(const fs::path& a, const fs::path& b) {
  return _wcsicmp(a.c_str(), b.c_str()) == 0;
}

void SafePath(const fs::path& path) {
  if (!path.is_absolute() || path.native().size() > 240 || path.native().rfind(L"\\\\", 0) == 0 || path == path.root_path())
    throw std::runtime_error("Unsafe update path");
  for (fs::path part = path; !part.empty(); part = part.parent_path()) {
    const DWORD attributes = GetFileAttributesW(part.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
      throw std::runtime_error("Update path contains a reparse point");
    if (part == part.parent_path()) break;
  }
}

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (size <= 0) return "<invalid path>";
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size, nullptr, nullptr);
  return result;
}

std::string Json(const std::string& value) {
  std::ostringstream result;
  result << '"';
  for (const unsigned char byte : value) {
    if (byte == '"' || byte == '\\') result << '\\' << byte;
    else if (byte < 32) result << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(byte);
    else result << byte;
  }
  result << '"';
  return result.str();
}

fs::path diagnosticTransaction;
std::string phase = "plan";
std::string cancellationNonce;
bool cancellationActive = true;

void Log(const std::string& event, const std::map<std::string, std::string>& fields = {}) {
  if (diagnosticTransaction.empty()) return;
  try {
    std::ofstream output(diagnosticTransaction / L"helper-diagnostics.jsonl", std::ios::app | std::ios::binary);
    output << "{\"event\":" << Json(event) << ",\"phase\":" << Json(phase)
        << ",\"helperPid\":" << GetCurrentProcessId() << ",\"tick\":" << GetTickCount64();
    for (const auto& field : fields) output << ',' << Json(field.first) << ':' << Json(field.second);
    output << "}\n";
    output.flush();
  } catch (...) {}
}

void Phase(const std::string& value) {
  phase = value;
  Log("phase");
}

std::string SystemError(DWORD code) {
  std::array<wchar_t, 2048> text{};
  const DWORD count = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, code, 0, text.data(), static_cast<DWORD>(text.size()), nullptr);
  std::wstring message(text.data(), count);
  while (!message.empty() && (message.back() == L'\r' || message.back() == L'\n')) message.pop_back();
  return Utf8(message);
}

std::runtime_error Failure(const std::string& operation, DWORD code, const fs::path& from = {}, const fs::path& to = {}) {
  Log(operation, {{"win32Error", std::to_string(code)}, {"from", Utf8(from.native())}, {"to", Utf8(to.native())}, {"systemMessage", SystemError(code)}});
  return std::runtime_error(operation + " failed, Win32=" + std::to_string(code) + " (" + SystemError(code) + ")" +
      (from.empty() ? "" : "; from=" + Utf8(from.native())) + (to.empty() ? "" : "; to=" + Utf8(to.native())));
}

void Write(const fs::path& path, const std::string& text) {
  const fs::path pending = path.native() + L".writing";
  const HANDLE file = CreateFileW(pending.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) throw Failure("CreateFileW(transaction)", GetLastError(), pending);
  DWORD written = 0;
  const BOOL ok = WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
  const DWORD writeError = ok ? ERROR_SUCCESS : GetLastError();
  const BOOL flushed = ok && FlushFileBuffers(file);
  const DWORD flushError = flushed ? ERROR_SUCCESS : GetLastError();
  CloseHandle(file);
  if (!ok || written != text.size()) throw Failure("WriteFile(transaction)", ok ? ERROR_WRITE_FAULT : writeError, pending);
  if (!flushed) throw Failure("FlushFileBuffers(transaction)", flushError, pending);
  if (!MoveFileExW(pending.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
    throw Failure("MoveFileExW(transaction-state)", GetLastError(), pending, path);
}

std::string Read(const fs::path& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) throw std::runtime_error("Cannot read transaction file: " + Utf8(path.native()));
  return std::string(std::istreambuf_iterator<char>(stream), {});
}

void CheckCancelled() {
  if (!cancellationActive || cancellationNonce.empty()) return;
  const auto request = diagnosticTransaction / L"cancel.txt";
  if (fs::exists(request) && Read(request) == cancellationNonce) {
    Log("cancellation-observed");
    throw std::runtime_error("Update cancelled before directory activation; old version preserved");
  }
}

std::string Hash(const fs::path& path) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0)
    throw std::runtime_error("SHA256 unavailable");
  DWORD size = 0, result = 0;
  BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, reinterpret_cast<PUCHAR>(&size), sizeof(size), &result, 0);
  std::vector<UCHAR> object(size);
  const NTSTATUS created = BCryptCreateHash(algorithm, &hash, object.data(), size, nullptr, 0, 0);
  if (created < 0) { BCryptCloseAlgorithmProvider(algorithm, 0); throw std::runtime_error("SHA256 initialization failed"); }
  std::ifstream stream(path, std::ios::binary);
  std::array<char, 65536> buffer{};
  bool ok = static_cast<bool>(stream);
  try {
    while (stream && ok) {
      CheckCancelled();
      stream.read(buffer.data(), buffer.size());
      const auto bytes = stream.gcount();
      if (bytes > 0) ok = BCryptHashData(hash, reinterpret_cast<PUCHAR>(buffer.data()), static_cast<ULONG>(bytes), 0) >= 0;
    }
  } catch (...) {
    BCryptDestroyHash(hash);
    BCryptCloseAlgorithmProvider(algorithm, 0);
    throw;
  }
  std::array<UCHAR, 32> digest{};
  ok = ok && stream.eof() && BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0) >= 0;
  BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (!ok) throw std::runtime_error("Cannot hash update file");
  std::ostringstream text;
  for (const auto byte : digest) text << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte);
  return text.str();
}

void CheckTree(const fs::path& root, const fs::path& records) {
  CheckCancelled();
  SafePath(root);
  std::map<fs::path, std::string> expected;
  std::istringstream lines(Read(records));
  std::string line;
  while (std::getline(lines, line)) {
    CheckCancelled();
    if (!line.empty() && line.back() == '\r') line.pop_back();
    const auto tab = line.find('\t');
    if (tab != 64 || line.size() < 66) throw std::runtime_error("Invalid file record");
    const fs::path relative(Wide(line.substr(65)));
    if (relative.is_absolute() || relative.has_root_name()) throw std::runtime_error("Absolute file record");
    for (const auto& part : relative) {
      if (part == L".." || part == L"." || part.native().find_first_of(L":\r\n\t") != std::wstring::npos)
        throw std::runtime_error("Unsafe file record");
    }
    const fs::path path = root / relative;
    SafePath(path);
    if (!expected.emplace(relative, line.substr(0, 64)).second || Hash(path) != line.substr(0, 64))
      throw std::runtime_error("Update file hash mismatch");
  }
  if (expected.empty() || expected.size() > 2048) throw std::runtime_error("Invalid file count");
  size_t count = 0;
  for (const auto& entry : fs::recursive_directory_iterator(root)) {
    CheckCancelled();
    SafePath(entry.path());
    if (entry.is_regular_file()) {
      if (expected.count(entry.path().lexically_relative(root)) != 1) throw std::runtime_error("Unowned application file");
      ++count;
    }
  }
  if (count != expected.size()) throw std::runtime_error("Incomplete application directory");
}

void CheckVersion(const fs::path& exe, DWORD build, const std::string& semantic) {
  DWORD ignored = 0;
  const DWORD size = GetFileVersionInfoSizeW(exe.c_str(), &ignored);
  if (!size) throw std::runtime_error("Missing executable version");
  std::vector<char> bytes(size);
  if (!GetFileVersionInfoW(exe.c_str(), 0, size, bytes.data())) throw std::runtime_error("Invalid executable version");
  VS_FIXEDFILEINFO* version = nullptr;
  UINT length = 0;
  if (!VerQueryValueW(bytes.data(), L"\\", reinterpret_cast<void**>(&version), &length) ||
      length < sizeof(VS_FIXEDFILEINFO) || LOWORD(version->dwFileVersionLS) != build)
    throw std::runtime_error("Wrong executable build");
  std::ostringstream actual;
  actual << HIWORD(version->dwFileVersionMS) << '.' << LOWORD(version->dwFileVersionMS) << '.' << HIWORD(version->dwFileVersionLS);
  if (actual.str() != semantic) throw std::runtime_error("Wrong executable version");
  std::ifstream file(exe, std::ios::binary);
  IMAGE_DOS_HEADER dos{};
  IMAGE_NT_HEADERS64 pe{};
  file.read(reinterpret_cast<char*>(&dos), sizeof(dos));
  if (dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0 || dos.e_lfanew > 1024 * 1024)
    throw std::runtime_error("Invalid Windows executable");
  file.seekg(dos.e_lfanew);
  file.read(reinterpret_cast<char*>(&pe), sizeof(pe));
  if (!file || pe.Signature != IMAGE_NT_SIGNATURE || pe.FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
      pe.OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) throw std::runtime_error("Wrong executable architecture");
}

PROCESS_INFORMATION Start(const fs::path& root, const fs::path& plan) {
  const auto exe = root / L"HongguoTV.exe";
  std::wstring command = L"\"" + exe.native() + L"\" --windows-update-start \"" + plan.native() + L"\"";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  SECURITY_ATTRIBUTES attributes{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  const auto output = CreateFileW((plan.parent_path() / L"startup-processes.log").c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE, &attributes, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  const DWORD outputError = output == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  const auto input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  const DWORD inputError = input == INVALID_HANDLE_VALUE ? GetLastError() : ERROR_SUCCESS;
  if (output == INVALID_HANDLE_VALUE || input == INVALID_HANDLE_VALUE) {
    if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
    if (input != INVALID_HANDLE_VALUE) CloseHandle(input);
    if (output == INVALID_HANDLE_VALUE) throw Failure("CreateFileW(startup-output)", outputError, plan.parent_path() / L"startup-processes.log");
    throw Failure("CreateFileW(startup-input)", inputError, L"NUL");
  }
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdOutput = output;
  startup.hStdError = output;
  startup.hStdInput = input;
  PROCESS_INFORMATION process{};
  const BOOL created = CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, TRUE, 0, nullptr, root.c_str(), &startup, &process);
  const DWORD createError = created ? ERROR_SUCCESS : GetLastError();
  CloseHandle(output);
  CloseHandle(input);
  if (!created) throw Failure("CreateProcessW", createError, exe, root);
  Log("child-started", {{"childPid", std::to_string(process.dwProcessId)}, {"executable", Utf8(exe.native())}, {"workingDirectory", Utf8(root.native())}});
  CloseHandle(process.hThread);
  std::ofstream evidence(plan.parent_path() / L"started-pids.txt", std::ios::app);
  evidence << process.dwProcessId << '\n';
  return process;
}

bool Move(const fs::path& from, const fs::path& to) {
  DWORD code = ERROR_SUCCESS;
  for (int i = 0; i < 30; ++i) {
    if (MoveFileExW(from.c_str(), to.c_str(), MOVEFILE_WRITE_THROUGH)) {
      Log("MoveFileExW-success", {{"from", Utf8(from.native())}, {"to", Utf8(to.native())}, {"attempts", std::to_string(i + 1)}});
      return true;
    }
    code = GetLastError();
    if (i == 0 || i == 29) Log("MoveFileExW-failure", {{"from", Utf8(from.native())}, {"to", Utf8(to.native())},
        {"attempt", std::to_string(i + 1)}, {"win32Error", std::to_string(code)}, {"systemMessage", SystemError(code)}});
    if (i != 29) Sleep(100);
  }
  SetLastError(code);
  return false;
}

bool ChildExited(HANDLE child, DWORD pid, DWORD wait, const std::string& event, DWORD waitError = ERROR_SUCCESS) {
  DWORD code = STILL_ACTIVE;
  const BOOL queried = GetExitCodeProcess(child, &code);
  const DWORD queryError = queried ? ERROR_SUCCESS : GetLastError();
  Log(event, {{"childPid", std::to_string(pid)}, {"waitResult", std::to_string(wait)},
      {"waitError", std::to_string(waitError)}, {"exitCode", std::to_string(code)}, {"exitQueryError", std::to_string(queryError)}});
  return wait == WAIT_OBJECT_0;
}

bool StopChild(const PROCESS_INFORMATION& child) {
  DWORD wait = WaitForSingleObject(child.hProcess, 0);
  DWORD waitError = wait == WAIT_FAILED ? GetLastError() : ERROR_SUCCESS;
  if (ChildExited(child.hProcess, child.dwProcessId, wait, "child-before-stop", waitError)) return true;
  if (wait != WAIT_TIMEOUT) return false;
#ifdef HONGGUOTV_UPDATER_TEST
  if (GetEnvironmentVariableW(L"HONGGUOTV_UPDATER_TEST_STOP_FAILURE", nullptr, 0) != 0) {
    Log("test-child-stop-unconfirmed", {{"childPid", std::to_string(child.dwProcessId)}});
    return false;
  }
#endif
  const BOOL terminated = TerminateProcess(child.hProcess, 1);
  const DWORD terminateError = terminated ? ERROR_SUCCESS : GetLastError();
  Log("TerminateProcess", {{"childPid", std::to_string(child.dwProcessId)}, {"succeeded", terminated ? "true" : "false"},
      {"win32Error", std::to_string(terminateError)}});
  wait = WaitForSingleObject(child.hProcess, 5000);
  waitError = wait == WAIT_FAILED ? GetLastError() : ERROR_SUCCESS;
  return ChildExited(child.hProcess, child.dwProcessId, wait, "child-after-stop", waitError);
}

void WaitForHandoff(HANDLE parent, DWORD pid, const std::string& nonce) {
  Phase("waiting-parent-handoff");
  for (int i = 0; i < 300; ++i) {
    CheckCancelled();
    const DWORD wait = WaitForSingleObject(parent, 100);
    if (wait == WAIT_FAILED) throw Failure("WaitForSingleObject(parent)", GetLastError());
    if (wait == WAIT_OBJECT_0) {
      const auto authorization = diagnosticTransaction / L"commit.txt";
      if (!fs::exists(authorization) || Read(authorization) != nonce)
        throw std::runtime_error("Parent exited without update handoff authorization; old version preserved");
      CheckCancelled();
      DWORD exitCode = STILL_ACTIVE;
      const BOOL queried = GetExitCodeProcess(parent, &exitCode);
      const DWORD queryError = queried ? ERROR_SUCCESS : GetLastError();
      Log("parent-exit-confirmed", {{"parentPid", std::to_string(pid)}, {"exitCode", std::to_string(exitCode)}, {"exitQueryError", std::to_string(queryError)}});
      return;
    }
  }
  throw std::runtime_error("Application did not finish saving and exit; old version preserved");
}

bool OtherInstance(const fs::path& executable, DWORD excluded) {
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) throw Failure("CreateToolhelp32Snapshot", GetLastError());
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  bool found = false;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == excluded || _wcsicmp(entry.szExeFile, L"HongguoTV.exe") != 0) continue;
      const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
      if (!process) {
        const DWORD code = GetLastError();
        Log("other-instance-query-unavailable", {{"candidatePid", std::to_string(entry.th32ProcessID)}, {"win32Error", std::to_string(code)}});
        found = true;
        break;
      }
      std::array<wchar_t, 32768> image{};
      DWORD length = static_cast<DWORD>(image.size());
      const BOOL queried = QueryFullProcessImageNameW(process, 0, image.data(), &length);
      const DWORD queryError = queried ? ERROR_SUCCESS : GetLastError();
      found = !queried || Equal(fs::path(image.data()), executable);
      if (found) Log("other-instance-detected", {{"candidatePid", std::to_string(entry.th32ProcessID)},
          {"win32Error", std::to_string(queryError)}, {"image", queried ? Utf8(std::wstring(image.data(), length)) : "unavailable"}});
      CloseHandle(process);
      if (found) break;
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return found;
}

int wmain(int argc, wchar_t** argv) {
  if (argc != 2) return 2;
  fs::path plan = fs::absolute(argv[1]).lexically_normal();
  const auto transaction = plan.parent_path();
  diagnosticTransaction = transaction;
  fs::path root, stage, backup;
  HANDLE parent = nullptr;
  HANDLE lock = INVALID_HANDLE_VALUE;
  PROCESS_INFORMATION child{};
  bool swapped = false;
  bool movedOld = false;
  bool committed = false;
  bool rollbackAllowed = true;
  bool handoffCompleted = false;
  try {
    SafePath(plan);
    std::map<std::string, std::string> fields;
    std::istringstream lines(Read(plan));
    std::string line;
    while (std::getline(lines, line)) {
      if (!line.empty() && line.back() == '\r') line.pop_back();
      const auto equals = line.find('=');
      if (equals == std::string::npos || !fields.emplace(line.substr(0, equals), line.substr(equals + 1)).second)
        throw std::runtime_error("Invalid update plan");
    }
    root = fs::path(Wide(fields.at("root"))).lexically_normal();
    stage = fs::path(Wide(fields.at("stage"))).lexically_normal();
    backup = fs::path(Wide(fields.at("backup"))).lexically_normal();
    const auto nonce = fields.at("nonce");
    if (nonce.size() != 32 || nonce.find_first_not_of("0123456789abcdef") != std::string::npos ||
        !Equal(root.parent_path(), stage.parent_path()) || !Equal(root.parent_path(), backup.parent_path()) ||
        stage.filename() != fs::path(L".hongguo-stage-" + Wide(nonce)) ||
        backup.filename() != fs::path(L".hongguo-backup-" + Wide(nonce)) || fs::exists(backup))
      throw std::runtime_error("Invalid transaction directories");
    cancellationNonce = nonce;
    SafePath(root); SafePath(stage); SafePath(backup);
    if (root == root.root_path() || Equal(transaction, root) || Equal(transaction.parent_path(), root))
      throw std::runtime_error("Invalid update transaction location");
    Phase("acquire-lock");
    const auto lockPath = root.parent_path() / L".hongguo-update.lock";
    lock = CreateFileW(lockPath.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_HIDDEN, nullptr);
    if (lock == INVALID_HANDLE_VALUE) throw Failure("CreateFileW(update-lock)", GetLastError(), lockPath);
    const DWORD pid = std::stoul(fields.at("pid"));
    parent = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!parent) throw Failure("OpenProcess(parent)", GetLastError());
    Log("parent-opened", {{"parentPid", std::to_string(pid)}, {"root", Utf8(root.native())}, {"stage", Utf8(stage.native())}, {"backup", Utf8(backup.native())}});
    std::array<wchar_t, 32768> image{};
    DWORD imageLength = static_cast<DWORD>(image.size());
    if (!QueryFullProcessImageNameW(parent, 0, image.data(), &imageLength)) throw Failure("QueryFullProcessImageNameW(parent)", GetLastError());
    if (!Equal(fs::path(image.data()), root / L"HongguoTV.exe")) throw std::runtime_error("Parent application does not match");
    if (OtherInstance(root / L"HongguoTV.exe", pid)) throw std::runtime_error("Another application instance is running; close it before updating");
    const DWORD build = std::stoul(fields.at("build"));
    const DWORD oldBuild = std::stoul(fields.at("oldBuild"));
    if (build <= oldBuild) throw std::runtime_error("Update is not newer");
    Phase("validate-prepared-directory");
    CheckTree(stage, transaction / L"new-files.tsv");
    Phase("validate-current-directory");
    CheckTree(root, transaction / L"old-files.tsv");
    CheckVersion(stage / L"HongguoTV.exe", build, fields.at("version"));
    CheckVersion(root / L"HongguoTV.exe", oldBuild, fields.at("oldVersion"));
    CheckCancelled();
    Phase("ready");
    Write(transaction / L"ready.txt", nonce);
    WaitForHandoff(parent, pid, nonce);
    handoffCompleted = true;
    CloseHandle(parent); parent = nullptr;
    if (OtherInstance(root / L"HongguoTV.exe", 0)) throw std::runtime_error("Another application instance started; old version preserved");
    Phase("revalidate-before-activation");
    CheckTree(stage, transaction / L"new-files.tsv");
    CheckTree(root, transaction / L"old-files.tsv");
    CheckCancelled();
    cancellationActive = false;
    Phase("backup-current-directory");
    if (!Move(root, backup)) throw Failure("MoveFileExW(backup-current)", GetLastError(), root, backup);
    movedOld = true;
    Phase("activate-prepared-directory");
    if (!Move(stage, root)) throw Failure("MoveFileExW(activate-prepared)", GetLastError(), stage, root);
    swapped = true;
    Phase("start-new-application");
    Write(transaction / L"status.txt", "starting");
    child = Start(root, plan);
    bool accepted = false;
    Phase("wait-new-application-ack");
    for (int i = 0; i < 600; ++i) {
      const DWORD wait = WaitForSingleObject(child.hProcess, 100);
      if (wait == WAIT_OBJECT_0) { ChildExited(child.hProcess, child.dwProcessId, wait, "child-exited-before-ack"); break; }
      if (wait == WAIT_FAILED) throw Failure("WaitForSingleObject(new-application)", GetLastError());
      if (fs::exists(transaction / L"ack.txt") && Read(transaction / L"ack.txt") == nonce) { accepted = true; break; }
    }
    if (!accepted) throw std::runtime_error("New application failed startup confirmation");
    committed = true;
    Log("startup-accepted", {{"childPid", std::to_string(child.dwProcessId)}});
    CloseHandle(child.hProcess); child.hProcess = nullptr;
    Phase("complete");
    Write(transaction / L"status.txt", "complete; previous application retained in backup directory");
    CloseHandle(lock);
    return 0;
  } catch (const std::exception& error) {
    if (parent) CloseHandle(parent);
    const std::string failedPhase = phase;
    Log("failure", {{"error", error.what()}});
    std::string status = std::string(committed ? "complete; diagnostics failed: " : "failed: ") + "phase=" + failedPhase + "; " + error.what();
    if (child.hProcess) {
      Phase("confirm-new-application-exit-before-rollback");
      rollbackAllowed = StopChild(child);
      CloseHandle(child.hProcess); child.hProcess = nullptr;
    }
    if (movedOld && !committed && !rollbackAllowed) {
      Log("rollback-withheld", {{"childPid", std::to_string(child.dwProcessId)}, {"root", Utf8(root.native())}, {"backup", Utf8(backup.native())}});
      status += "; new application PID " + std::to_string(child.dwProcessId) + " exit unconfirmed; rollback withheld; preserve current directory=" +
          Utf8(root.native()) + "; backup=" + Utf8(backup.native()) + "; configuration backup=" + Utf8((transaction / L"preferences-backup.json").native());
    } else if (movedOld && !committed) {
      Phase("rollback-directories");
      bool restored = !swapped || Move(root, stage);
      DWORD moveError = restored ? ERROR_SUCCESS : GetLastError();
      if (restored) { restored = Move(backup, root); moveError = restored ? ERROR_SUCCESS : GetLastError(); }
      if (restored) {
        status += "; rolled back to previous application";
        Phase("restore-configuration");
        const auto savedConfig = transaction / L"preferences-backup.json";
        const auto config = transaction.parent_path().parent_path() / L"shared_preferences.json";
        bool configRestored = true;
        if (fs::exists(savedConfig)) {
          SingleInstanceOptions recoveryOptions;
          recoveryOptions.update_wait_ms = 0;
#ifdef HONGGUOTV_UPDATER_TEST
          recoveryOptions.application_id += L".TransactionTest." + Wide(cancellationNonce);
          recoveryOptions.executable_name = L"HongguoTV-transaction-fixture.exe";
          recoveryOptions.product_name = L"Update fixture";
#endif
          SingleInstanceGuard recoveryLease(recoveryOptions);
          if (recoveryLease.Start(true) != SingleInstanceResult::kPrimary) {
            configRestored = false;
            status += "; configuration recovery withheld because another client is running or its identity is uncertain; preserve configuration backup=" + Utf8(savedConfig.native());
            Log("configuration-recovery-withheld", {{"reason", Utf8(recoveryLease.error())}, {"backup", Utf8(savedConfig.native())}});
          }
          SafePath(config);
          if (configRestored && fs::exists(config) && !CopyFileW(config.c_str(), (transaction / L"failed-preferences.json").c_str(), TRUE)) {
            const DWORD copyError = GetLastError();
            Log("CopyFileW(failed-preferences)", {{"win32Error", std::to_string(copyError)}, {"from", Utf8(config.native())}, {"to", Utf8((transaction / L"failed-preferences.json").native())}});
            configRestored = false;
            status += "; failed configuration could not be preserved, Win32=" + std::to_string(copyError);
          }
          if (configRestored && !CopyFileW(savedConfig.c_str(), config.c_str(), FALSE)) {
            const DWORD copyError = GetLastError();
            Log("CopyFileW(restore-preferences)", {{"win32Error", std::to_string(copyError)}, {"from", Utf8(savedConfig.native())}, {"to", Utf8(config.native())}});
            configRestored = false;
            status += "; configuration backup requires manual recovery, Win32=" + std::to_string(copyError);
          }
        }
        try { Write(transaction / L"status.txt", status); if (configRestored) { Phase("restart-previous-application"); auto previous = Start(root, plan); CloseHandle(previous.hProcess); } }
        catch (const std::exception& restartError) { status += "; restart old application manually: "; status += restartError.what(); }
      } else {
        status += "; rollback rename failed, Win32=" + std::to_string(moveError) + "; preserve backup=" + Utf8(backup.native()) + "; see helper-diagnostics.jsonl for source/destination paths";
      }
    } else if (handoffCompleted && !committed) {
      try {
        cancellationActive = false;
        Phase("revalidate-previous-for-restart");
        CheckTree(root, transaction / L"old-files.tsv");
        if (!OtherInstance(root / L"HongguoTV.exe", 0)) {
          Write(transaction / L"status.txt", status);
          auto previous = Start(root, plan);
          CloseHandle(previous.hProcess);
          status += "; previous application preserved and restarted";
        }
      } catch (const std::exception& restartError) {
        status += "; previous application was not restarted: ";
        status += restartError.what();
      }
    }
    try { Write(transaction / L"status.txt", status); } catch (...) {}
    if (lock != INVALID_HANDLE_VALUE) CloseHandle(lock);
    return committed ? 0 : 1;
  }
}
