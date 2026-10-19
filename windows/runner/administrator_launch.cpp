#include "administrator_launch.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <filesystem>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;

std::wstring ExecutablePath() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  return length > 0 && length < buffer.size()
      ? std::wstring(buffer.data(), length) : std::wstring();
}

std::wstring ToWide(const std::string& input) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      input.data(), static_cast<int>(input.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring output(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
      static_cast<int>(input.size()), output.data(), size);
  return output;
}

std::wstring QuoteArgument(const std::wstring& argument) {
  std::wstring output = L"\"";
  size_t slashes = 0;
  for (const auto ch : argument) {
    if (ch == L'\\') { ++slashes; continue; }
    output.append(ch == L'"' ? slashes * 2 + 1 : slashes, L'\\');
    output += ch;
    slashes = 0;
  }
  output.append(slashes * 2, L'\\');
  return output + L'"';
}

void Handle(HWND owner, const flutter::MethodCall<Value>& call,
            std::unique_ptr<flutter::MethodResult<Value>> result) {
  const auto& method = call.method_name();
  if (method == "isElevated") {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
      result->Error("token", "无法读取当前运行权限"); return;
    }
    TOKEN_ELEVATION elevation{};
    DWORD size = 0;
    const BOOL ok = GetTokenInformation(token, TokenElevation, &elevation,
                                        sizeof(elevation), &size);
    CloseHandle(token);
    if (!ok) { result->Error("token", "无法读取当前运行权限"); return; }
    result->Success(Value(elevation.TokenIsElevated != 0));
  } else if (method == "restartElevated") {
    const auto executable = ExecutablePath();
    if (executable.empty()) { result->Error("path", "无法获取程序路径"); return; }
    std::wstring parameters = L"--administrator-parent-pid=" +
                              std::to_wstring(GetCurrentProcessId());
    if (const auto* args = call.arguments()) {
      if (const auto* locator = std::get_if<std::string>(args); locator && !locator->empty()) {
        const auto path = ToWide(*locator);
        if (path.empty() || !std::filesystem::path(path).is_absolute()) {
          result->Error("path", "数据目录定位文件路径无效"); return;
        }
        parameters += L" " + QuoteArgument(L"--storage-locator=" + path);
      }
    }
    const auto directory = std::filesystem::path(executable).parent_path().wstring();
    SHELLEXECUTEINFOW info{};
    info.cbSize = sizeof(info);
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    info.hwnd = owner;
    info.lpVerb = L"runas";
    info.lpFile = executable.c_str();
    info.lpParameters = parameters.c_str();
    info.lpDirectory = directory.c_str();
    info.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&info)) {
      const DWORD error = GetLastError();
      result->Error(error == ERROR_CANCELLED ? "cancelled" : "launch",
          error == ERROR_CANCELLED ? "管理员授权已取消" : "无法以管理员身份启动程序");
      return;
    }
    if (info.hProcess == nullptr) { result->Error("launch", "未能创建重启进程"); return; }
    const bool exited = WaitForSingleObject(info.hProcess, 0) == WAIT_OBJECT_0;
    CloseHandle(info.hProcess);
    if (exited) { result->Error("launch", "管理员启动进程已退出"); return; }
    result->Success();
  } else if (method == "waitForParentExit") {
    const auto* args = call.arguments();
    int64_t parent = 0;
    if (args) {
      if (const auto* id32 = std::get_if<int32_t>(args)) parent = *id32;
      else if (const auto* id64 = std::get_if<int64_t>(args)) parent = *id64;
    }
    if (parent <= 0 || parent > MAXDWORD || parent == GetCurrentProcessId()) {
      result->Error("parent", "重启进程标识无效"); return;
    }
    HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                                  FALSE, static_cast<DWORD>(parent));
    if (!process) {
      if (GetLastError() == ERROR_INVALID_PARAMETER) result->Success();
      else result->Error("parent", "无法等待原进程退出");
      return;
    }
    std::vector<wchar_t> buffer(32768);
    DWORD size = static_cast<DWORD>(buffer.size());
    const auto executable = ExecutablePath();
    const bool matches = QueryFullProcessImageNameW(process, 0, buffer.data(), &size) &&
        CompareStringOrdinal(buffer.data(), static_cast<int>(size), executable.c_str(),
                             static_cast<int>(executable.size()), TRUE) == CSTR_EQUAL;
    if (!matches) {
      const bool exited = WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
      CloseHandle(process);
      if (exited) result->Success();
      else result->Error("parent", "原进程与当前程序不匹配");
      return;
    }
    const DWORD state = WaitForSingleObject(process, 30000);
    CloseHandle(process);
    if (state == WAIT_OBJECT_0) result->Success();
    else result->Error("parent", "等待原进程退出超时，请手动退出后重新启动");
  } else {
    result->NotImplemented();
  }
}
}  // namespace

AdministratorLaunch::AdministratorLaunch(HWND owner, flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "idreaml_clip/administrator", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([owner](const auto& call, auto result) {
    Handle(owner, call, std::move(result));
  });
}
