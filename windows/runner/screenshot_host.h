#ifndef RUNNER_SCREENSHOT_HOST_H_
#define RUNNER_SCREENSHOT_HOST_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include "pinned_image.h"
#include "scroll_capture.h"

#include <memory>
#include <cstdint>
#include <set>

// A separate engine/window preserves the clipboard window during hotkey capture.
class ScreenshotHost {
 public:
  static constexpr UINT kCloseMessage = WM_APP + 65;
  ScreenshotHost(HWND owner, HWND view, flutter::FlutterEngine* engine,
                 const flutter::DartProject& project);
  ~ScreenshotHost();
  void Close();
  bool HandleShortcut(const MSG& message);
  bool active() const { return active_; }

 private:
  using Value = flutter::EncodableValue;
  using Result = flutter::MethodResult<Value>;
  void HandleMain(const flutter::MethodCall<Value>& call,
                  std::unique_ptr<Result> result);
  void HandleEditor(const flutter::MethodCall<Value>& call,
                    std::unique_ptr<Result> result);
  void InvokePinAction(HWND window, const char* method, Value argument, const wchar_t* error);
  bool Capture();
  bool EnsureEditor();
  void ShowLongEditor(const RECT& selection);
  void RestoreOverlayStyle();
  void DestroyEditor();
  static LRESULT CALLBACK WindowProc(HWND window, UINT message,
                                     WPARAM wparam, LPARAM lparam);
  HWND owner_;
  HWND main_view_;
  POINT initial_cursor_{};
  HWND window_ = nullptr;
  HWND previous_foreground_ = nullptr;
  RECT screen_{};
  bool prepared_ = false;
  bool active_ = false;
  bool local_shortcuts_ = false;
  std::set<WPARAM> consumed_keys_;
  bool pinned_ = false;
  bool editor_ready_ = false;
  bool positioning_ = false;
  bool long_editor_ = false;
  bool maximized_ = false;
  bool wait_for_compositor_ = false;
  int64_t session_ = 0;
  bool closing_ = false;
  bool close_pending_ = false;
  int pending_calls_ = 0;
  std::shared_ptr<bool> alive_ = std::make_shared<bool>(true);
  void CompleteForwardedCall();
  flutter::DartProject project_;
  flutter::EncodableMap snapshot_;
  std::unique_ptr<flutter::MethodChannel<Value>> main_channel_;
  std::unique_ptr<flutter::MethodChannel<Value>> editor_channel_;
  std::unique_ptr<flutter::FlutterViewController> editor_;
  std::unique_ptr<ScrollCapture> scroll_;
  PinnedImages pins_;
};

#endif
