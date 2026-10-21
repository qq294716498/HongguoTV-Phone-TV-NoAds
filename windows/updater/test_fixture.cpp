#include <windows.h>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include "../runner/single_instance.h"

namespace fs = std::filesystem;

int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 2;
  const fs::path argument(argv[2]);
  SingleInstanceOptions instanceOptions;
  instanceOptions.application_id += L".TransactionTest." + argument.filename().wstring();
  instanceOptions.executable_name = L"HongguoTV-transaction-fixture.exe";
  instanceOptions.product_name = L"Update fixture";
  instanceOptions.update_wait_ms = 0;
  if (std::wstring(argv[1]) == L"--hold-client") {
    SingleInstanceGuard guard(instanceOptions);
    if (guard.Start(true) != SingleInstanceResult::kPrimary) return 8;
    std::ofstream config(argument.parent_path().parent_path() / L"shared_preferences.json");
    config << "active-other-client-config";
    config.close();
    std::ofstream(argument / L"other-client-ready") << GetCurrentProcessId();
    while (!fs::exists(argument / L"stop-other-client")) Sleep(50);
    return 0;
  }
  if (std::wstring(argv[1]) == L"--hold") {
    while (!fs::exists(argument / L"stop-old")) Sleep(50);
    return 0;
  }
  const auto transaction = argument.parent_path();
  std::ifstream plan(argument);
  std::map<std::string, std::string> fields;
  std::string line;
  while (std::getline(plan, line)) {
    const auto equals = line.find('=');
    fields[line.substr(0, equals)] = line.substr(equals + 1);
  }
  std::ifstream modeFile(transaction / L"test-mode");
  std::string mode;
  modeFile >> mode;
  if (TEST_BUILD == 39 && mode == "cross-directory-client") {
    const ULONGLONG deadline = GetTickCount64() + 10000;
    while (!fs::exists(transaction / L"other-client-ready") && GetTickCount64() < deadline) Sleep(10);
    instanceOptions.application_id = L"HongguoTV.Client.v1.TransactionTest." + transaction.filename().wstring();
    SingleInstanceGuard guard(instanceOptions);
    const auto result = guard.Start(true);
    std::ofstream(transaction / L"update-child-refused") <<
        (result == SingleInstanceResult::kBlocked ? "blocked" : "unexpected");
    return result == SingleInstanceResult::kBlocked ? 7 : 9;
  }
  if (TEST_BUILD == 39 && mode == "crash") {
    std::ofstream config(transaction.parent_path().parent_path() / L"shared_preferences.json");
    config << "failed-new-config";
    return 3;
  }
  if (TEST_BUILD == 39 && mode == "stop-unconfirmed") {
    std::ofstream config(transaction.parent_path().parent_path() / L"shared_preferences.json");
    config << "new-config-awaiting-ack";
    config.close();
    Sleep(120000);
    return 5;
  }
  if (TEST_BUILD == 39 && mode == "hang") {
    Sleep(90000);
    return 4;
  }
  std::ofstream ack(transaction / L"ack.txt");
  ack << fields["nonce"];
  ack.close();
  std::ofstream evidence(transaction / (L"child-" + std::to_wstring(TEST_BUILD)));
  evidence << GetCurrentProcessId();
  evidence.close();
  while (!fs::exists(transaction / L"stop-new")) Sleep(50);
  return 0;
}
