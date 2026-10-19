#include "directory_picker.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <string>

#include "utils.h"

namespace {
using Value = flutter::EncodableValue;

std::wstring ToWide(const std::string& input) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                       input.data(), static_cast<int>(input.size()),
                                       nullptr, 0);
  if (length <= 0) return {};
  std::wstring value(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(),
                      static_cast<int>(input.size()), value.data(), length);
  return value;
}

void ChooseDirectory(HWND owner, const flutter::MethodCall<Value>& call,
                     std::unique_ptr<flutter::MethodResult<Value>> result) {
  if (call.method_name() != "chooseDirectory") {
    result->NotImplemented();
    return;
  }
  Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
  HRESULT status = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                    CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(dialog.GetAddressOf()));
  FILEOPENDIALOGOPTIONS options = 0;
  if (SUCCEEDED(status)) status = dialog->GetOptions(&options);
  if (SUCCEEDED(status)) {
    status = dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM |
                               FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR);
  }
  if (FAILED(status)) {
    result->Error("directory_dialog", "无法打开文件夹选择窗口");
    return;
  }
  dialog->SetTitle(L"选择数据存储目录");
  if (const auto* args = call.arguments()) {
    if (const auto* initial = std::get_if<std::string>(args)) {
      const auto path = ToWide(*initial);
      Microsoft::WRL::ComPtr<IShellItem> folder;
      if (!path.empty() && SUCCEEDED(SHCreateItemFromParsingName(
              path.c_str(), nullptr, IID_PPV_ARGS(folder.GetAddressOf())))) {
        dialog->SetFolder(folder.Get());
      }
    }
  }
  status = dialog->Show(owner);
  if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    result->Success();
    return;
  }
  Microsoft::WRL::ComPtr<IShellItem> selected;
  PWSTR path = nullptr;
  if (SUCCEEDED(status)) status = dialog->GetResult(selected.GetAddressOf());
  if (SUCCEEDED(status)) status = selected->GetDisplayName(SIGDN_FILESYSPATH, &path);
  if (FAILED(status)) {
    result->Error("directory_dialog", "无法读取所选文件夹");
    return;
  }
  const auto selected_path = Utf8FromUtf16(path);
  CoTaskMemFree(path);
  result->Success(Value(selected_path));
}
}  // namespace

DirectoryPicker::DirectoryPicker(HWND owner, flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "idreaml_clip/directories",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [owner](const auto& call, auto result) {
        ChooseDirectory(owner, call, std::move(result));
      });
}
