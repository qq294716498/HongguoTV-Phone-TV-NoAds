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

void Write(const fs::path& path, const std::string& text) {
  std::ofstream stream(path, std::ios::binary | std::ios::trunc);
  stream << text;
  stream.flush();
  if (!stream) throw std::runtime_error("Cannot write transaction state");
}

std::string Read(const fs::path& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) throw std::runtime_error("Missing transaction file");
  return std::string(std::istreambuf_iterator<char>(stream), {});
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
  while (stream && ok) {
    stream.read(buffer.data(), buffer.size());
    const auto bytes = stream.gcount();
    if (bytes > 0) ok = BCryptHashData(hash, reinterpret_cast<PUCHAR>(buffer.data()), static_cast<ULONG>(bytes), 0) >= 0;
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
  SafePath(root);
  std::map<fs::path, std::string> expected;
  std::istringstream lines(Read(records));
  std::string line;
  while (std::getline(lines, line)) {
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
  const auto input = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &attributes, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (output == INVALID_HANDLE_VALUE || input == INVALID_HANDLE_VALUE) {
    if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
    if (input != INVALID_HANDLE_VALUE) CloseHandle(input);
    throw std::runtime_error("Cannot open startup diagnostics");
  }
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdOutput = output;
  startup.hStdError = output;
  startup.hStdInput = input;
  PROCESS_INFORMATION process{};
  const BOOL created = CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, TRUE, 0, nullptr, root.c_str(), &startup, &process);
  CloseHandle(output);
  CloseHandle(input);
  if (!created)
    throw std::runtime_error("Cannot restart application");
  CloseHandle(process.hThread);
  std::ofstream evidence(plan.parent_path() / L"started-pids.txt", std::ios::app);
  evidence << process.dwProcessId << '\n';
  return process;
}

bool Move(const fs::path& from, const fs::path& to) {
  for (int i = 0; i < 30; ++i) {
    if (MoveFileExW(from.c_str(), to.c_str(), MOVEFILE_WRITE_THROUGH)) return true;
    Sleep(100);
  }
  return false;
}

bool OtherInstance(const fs::path& executable, DWORD excluded) {
  const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot verify other application instances");
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  bool found = false;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == excluded || _wcsicmp(entry.szExeFile, L"HongguoTV.exe") != 0) continue;
      const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
      if (!process) { found = true; break; }
      std::array<wchar_t, 32768> image{};
      DWORD length = static_cast<DWORD>(image.size());
      found = !QueryFullProcessImageNameW(process, 0, image.data(), &length) || Equal(fs::path(image.data()), executable);
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
  fs::path root, stage, backup;
  HANDLE parent = nullptr;
  HANDLE lock = INVALID_HANDLE_VALUE;
  bool swapped = false;
  bool movedOld = false;
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
    SafePath(root); SafePath(stage); SafePath(backup);
    if (root == root.root_path() || Equal(transaction, root) || Equal(transaction.parent_path(), root))
      throw std::runtime_error("Invalid update transaction location");
    lock = CreateFileW((root.parent_path() / L".hongguo-update.lock").c_str(), GENERIC_READ | GENERIC_WRITE,
        0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_HIDDEN, nullptr);
    if (lock == INVALID_HANDLE_VALUE) throw std::runtime_error("Another update is active or directory is read only");
    const DWORD pid = std::stoul(fields.at("pid"));
    parent = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    std::array<wchar_t, 32768> image{};
    DWORD imageLength = static_cast<DWORD>(image.size());
    if (!parent || !QueryFullProcessImageNameW(parent, 0, image.data(), &imageLength) ||
        !Equal(fs::path(image.data()), root / L"HongguoTV.exe")) throw std::runtime_error("Parent application does not match");
    if (OtherInstance(root / L"HongguoTV.exe", pid)) throw std::runtime_error("Another application instance is running; close it before updating");
    const DWORD build = std::stoul(fields.at("build"));
    const DWORD oldBuild = std::stoul(fields.at("oldBuild"));
    if (build <= oldBuild) throw std::runtime_error("Update is not newer");
    CheckTree(stage, transaction / L"new-files.tsv");
    CheckTree(root, transaction / L"old-files.tsv");
    CheckVersion(stage / L"HongguoTV.exe", build, fields.at("version"));
    CheckVersion(root / L"HongguoTV.exe", oldBuild, fields.at("oldVersion"));
    Write(transaction / L"ready.txt", nonce);
    if (WaitForSingleObject(parent, 30000) != WAIT_OBJECT_0) throw std::runtime_error("Application did not finish saving and exit");
    CloseHandle(parent); parent = nullptr;
    if (OtherInstance(root / L"HongguoTV.exe", 0)) throw std::runtime_error("Another application instance started; old version preserved");
    CheckTree(stage, transaction / L"new-files.tsv");
    CheckTree(root, transaction / L"old-files.tsv");
    if (!Move(root, backup)) throw std::runtime_error("Application directory is busy; old version preserved");
    movedOld = true;
    if (!Move(stage, root)) throw std::runtime_error("Cannot activate prepared directory");
    swapped = true;
    Write(transaction / L"status.txt", "starting");
    auto child = Start(root, plan);
    bool accepted = false;
    for (int i = 0; i < 600; ++i) {
      if (WaitForSingleObject(child.hProcess, 100) == WAIT_OBJECT_0) break;
      if (fs::exists(transaction / L"ack.txt") && Read(transaction / L"ack.txt") == nonce) { accepted = true; break; }
    }
    if (!accepted) {
      if (WaitForSingleObject(child.hProcess, 0) == WAIT_TIMEOUT) {
        TerminateProcess(child.hProcess, 1);
        WaitForSingleObject(child.hProcess, 5000);
      }
      CloseHandle(child.hProcess);
      throw std::runtime_error("New application failed startup confirmation");
    }
    CloseHandle(child.hProcess);
    Write(transaction / L"status.txt", "complete; previous application retained in backup directory");
    CloseHandle(lock);
    return 0;
  } catch (const std::exception& error) {
    if (parent) CloseHandle(parent);
    std::string status = std::string("failed: ") + error.what();
    if (movedOld) {
      bool restored = !swapped || Move(root, stage);
      restored = restored && Move(backup, root);
      if (restored) {
        status += "; rolled back to previous application";
        const auto savedConfig = transaction / L"preferences-backup.json";
        const auto config = transaction.parent_path().parent_path() / L"shared_preferences.json";
        bool configRestored = true;
        if (fs::exists(savedConfig)) {
          SafePath(config);
          if (fs::exists(config)) CopyFileW(config.c_str(), (transaction / L"failed-preferences.json").c_str(), TRUE);
          if (!CopyFileW(savedConfig.c_str(), config.c_str(), FALSE)) {
            configRestored = false;
            status += "; configuration backup requires manual recovery";
          }
        }
        try { Write(transaction / L"status.txt", status); if (configRestored) { auto child = Start(root, plan); CloseHandle(child.hProcess); } }
        catch (...) { status += "; restart old application manually"; }
      } else {
        status += "; rollback directory is busy, preserve backup and close application before recovery";
      }
    }
    try { Write(transaction / L"status.txt", status); } catch (...) {}
    if (lock != INVALID_HANDLE_VALUE) CloseHandle(lock);
    return 1;
  }
}
