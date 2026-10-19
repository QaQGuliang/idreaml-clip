#include "screenshot_host.h"

#include <commdlg.h>
#include <dwmapi.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <iterator>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
constexpr char kChannel[] = "idreaml_clip/screenshot";
constexpr wchar_t kClass[] = L"IdreamlScreenshotWindow";

const Value* Field(const Map& map, const char* key) {
  auto it = map.find(Value(key));
  return it == map.end() ? nullptr : &it->second;
}

std::wstring Wide(const std::string& text) {
  int count = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(count, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      out.data(), count);
  return out;
}

std::string Utf8(const wchar_t* text) {
  int length = static_cast<int>(wcslen(text));
  int count = WideCharToMultiByte(CP_UTF8, 0, text, length, nullptr, 0,
                                nullptr, nullptr);
  std::string out(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, length, out.data(), count,
                      nullptr, nullptr);
  return out;
}

struct WindowCandidates { RECT screen; List windows; };
BOOL CALLBACK CollectWindows(HWND hwnd, LPARAM data) {
  if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return TRUE;
  DWORD cloaked = 0;
  DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
  if (cloaked != 0) return TRUE;
  RECT bounds{};
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS,
                                   &bounds, sizeof(bounds)))) {
    GetWindowRect(hwnd, &bounds);
  }
  auto* candidates = reinterpret_cast<WindowCandidates*>(data);
  RECT intersection{};
  if (IntersectRect(&intersection, &bounds, &candidates->screen)) {
    candidates->windows.emplace_back(List{
        Value(static_cast<int32_t>(intersection.left - candidates->screen.left)),
        Value(static_cast<int32_t>(intersection.top - candidates->screen.top)),
        Value(static_cast<int32_t>(intersection.right - candidates->screen.left)),
        Value(static_cast<int32_t>(intersection.bottom - candidates->screen.top))});
  }
  return TRUE;
}
}  // namespace

ScreenshotHost::ScreenshotHost(HWND owner, HWND view,
                               flutter::FlutterEngine* engine,
                               const flutter::DartProject& project)
    : owner_(owner), main_view_(view), project_(project) {
  main_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      engine->messenger(), kChannel, &flutter::StandardMethodCodec::GetInstance());
  main_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleMain(call, std::move(result)); });
}

ScreenshotHost::~ScreenshotHost() {
  *alive_ = false;
  main_channel_->SetMethodCallHandler(nullptr);
  DestroyEditor();
}

void ScreenshotHost::DestroyEditor() {
  scroll_.reset();
  if (editor_channel_) editor_channel_->SetMethodCallHandler(nullptr);
  editor_channel_.reset();
  editor_.reset();
  if (window_) DestroyWindow(window_);
  window_ = nullptr;
  editor_ready_ = false;
}

void ScreenshotHost::HandleMain(const flutter::MethodCall<Value>& call,
                                std::unique_ptr<Result> result) {
  const auto& method = call.method_name();
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (method == "warmUp") {
    if (!EnsureEditor()) {
      DestroyEditor();
      result->Error("window", "无法预热截图编辑窗口"); return;
    }
    result->Success();
  } else if (method == "prepare") {
    if (active_) { result->Error("busy", "已有截图正在进行"); return; }
    POINT point{};
    GetCursorPos(&point);
    if (args) {
      auto x = Field(*args, "x");
      auto y = Field(*args, "y");
      if (x && y) {
        point = {static_cast<LONG>(std::get<double>(*x)),
                 static_cast<LONG>(std::get<double>(*y))};
        ClientToScreen(main_view_, &point);
      }
    }
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetMonitorInfo(MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST), &monitor)) {
      result->Error("monitor", "无法读取目标显示器"); return;
    }
    screen_ = monitor.rcMonitor;
    ++session_;
    wait_for_compositor_ = args && Field(*args, "x");
    previous_foreground_ = GetForegroundWindow();
    prepared_ = true;
    result->Success();
  } else if (method == "open") {
    if (!prepared_ || active_) { result->Error("state", "截图状态无效"); return; }
    prepared_ = false;
    snapshot_.clear();
    if (!Capture()) { result->Error("capture", "无法捕获当前屏幕或屏幕尺寸过大"); return; }
    snapshot_[Value("session")] = Value(session_);
    if (args) {
      if (auto styles = Field(*args, "styles")) snapshot_[Value("styles")] = *styles;
    }
    if (!EnsureEditor()) {
      DestroyEditor();
      snapshot_.clear();
      result->Error("window", "无法创建截图编辑窗口"); return;
    }
    // Moving a reusable hidden window between monitors can change its DPI.
    positioning_ = true;
    SetWindowPos(window_, HWND_TOPMOST, screen_.left, screen_.top,
                 screen_.right - screen_.left, screen_.bottom - screen_.top,
                 SWP_NOACTIVATE);
    positioning_ = false;
    active_ = true;
    SetTimer(window_, 1, 15000, nullptr);
    if (editor_ready_) {
      editor_channel_->InvokeMethod("start", std::make_unique<Value>(std::move(snapshot_)));
      snapshot_.clear();
    }
    result->Success();
  } else if (method == "chooseSavePath") {
    if (!active_) { result->Error("state", "截图窗口已关闭"); return; }
    wchar_t filename[32768] = {};
    std::wstring initial;
    if (args) {
      if (auto value = Field(*args, "name")) {
        auto name = Wide(std::get<std::string>(*value));
        wcsncpy_s(filename, name.c_str(), _TRUNCATE);
      }
      if (auto value = Field(*args, "directory")) initial = Wide(std::get<std::string>(*value));
    }
    OPENFILENAMEW dialog{};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = window_;
    dialog.lpstrFilter = L"PNG 图片\0*.png\0\0";
    dialog.lpstrFile = filename;
    dialog.nMaxFile = static_cast<DWORD>(std::size(filename));
    dialog.lpstrDefExt = L"png";
    dialog.lpstrTitle = L"截图另存为";
    dialog.lpstrInitialDir = initial.empty() ? nullptr : initial.c_str();
    dialog.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (GetSaveFileNameW(&dialog)) result->Success(Value(Utf8(filename)));
    else if (CommDlgExtendedError() != 0) result->Error("dialog", "无法打开另存为对话框");
    else result->Success();
  } else if (method == "close") {
    result->Success();
    PostMessage(owner_, kCloseMessage, 0, 0);
  } else {
    result->NotImplemented();
  }
}

bool ScreenshotHost::Capture() {
  MONITORINFO current{};
  current.cbSize = sizeof(current);
  if (!GetMonitorInfo(MonitorFromRect(&screen_, MONITOR_DEFAULTTONULL), &current) ||
      !EqualRect(&screen_, &current.rcMonitor)) return false;
  const int width = screen_.right - screen_.left;
  const int height = screen_.bottom - screen_.top;
  if (width <= 0 || height <= 0 || static_cast<int64_t>(width) * height > 40000000) return false;
  // Wait for the compositor to reflect the button-path panel hide.
  if (wait_for_compositor_) DwmFlush();
  HDC desktop = GetDC(nullptr);
  if (!desktop) return false;
  HDC memory = CreateCompatibleDC(desktop);
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  HBITMAP bitmap = CreateDIBSection(desktop, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  bool success = false;
  if (memory && bitmap && pixels) {
    auto previous = SelectObject(memory, bitmap);
    success = BitBlt(memory, 0, 0, width, height, desktop,
                     screen_.left, screen_.top, SRCCOPY | CAPTUREBLT) != FALSE;
    if (success) {
      auto* bytes = static_cast<uint8_t*>(pixels);
      std::vector<uint8_t> image(bytes, bytes + static_cast<size_t>(width) * height * 4);
      for (size_t i = 3; i < image.size(); i += 4) image[i] = 255;
      snapshot_[Value("pixels")] = Value(std::move(image));
      snapshot_[Value("width")] = Value(width);
      snapshot_[Value("height")] = Value(height);
      WindowCandidates candidates{screen_, {}};
      EnumWindows(CollectWindows, reinterpret_cast<LPARAM>(&candidates));
      snapshot_[Value("windows")] = Value(std::move(candidates.windows));
    }
    SelectObject(memory, previous);
  }
  if (bitmap) DeleteObject(bitmap);
  if (memory) DeleteDC(memory);
  ReleaseDC(nullptr, desktop);
  return success;
}

bool ScreenshotHost::EnsureEditor() {
  if (editor_) return true;
  // Prewarm on the main window's monitor without capturing or taking focus.
  RECT bounds = screen_;
  if (IsRectEmpty(&bounds)) {
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    if (!GetMonitorInfo(MonitorFromWindow(owner_, MONITOR_DEFAULTTONEAREST), &monitor)) return false;
    bounds = monitor.rcMonitor;
  }
  WNDCLASSW cls{};
  cls.hInstance = GetModuleHandle(nullptr);
  cls.lpfnWndProc = WindowProc;
  cls.lpszClassName = kClass;
  cls.hCursor = LoadCursor(nullptr, IDC_CROSS);
  RegisterClassW(&cls);
  window_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kClass,
      L"理梦剪藏 · 截图", WS_POPUP, bounds.left, bounds.top,
      bounds.right - bounds.left, bounds.bottom - bounds.top,
      nullptr, nullptr, GetModuleHandle(nullptr), this);
  if (!window_) return false;
  auto project = project_;
  project.set_dart_entrypoint("screenshotMain");
  project.set_dart_entrypoint_arguments({});
  editor_ = std::make_unique<flutter::FlutterViewController>(
      bounds.right - bounds.left, bounds.bottom - bounds.top, project);
  if (!editor_->engine() || !editor_->view()) return false;
  editor_channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      editor_->engine()->messenger(), kChannel,
      &flutter::StandardMethodCodec::GetInstance());
  editor_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) { HandleEditor(call, std::move(result)); });
  HWND child = editor_->view()->GetNativeWindow();
  SetParent(child, window_);
  MoveWindow(child, 0, 0, bounds.right - bounds.left,
             bounds.bottom - bounds.top, TRUE);
  return true;
}

void ScreenshotHost::HandleEditor(const flutter::MethodCall<Value>& call,
                                  std::unique_ptr<Result> result) {
  const auto& name = call.method_name();
  if (name == "beginScroll" || name == "scrollFrame") {
    const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    auto integer = [&](const char* key, int64_t* out) {
      const auto* value = args ? Field(*args, key) : nullptr;
      if (value) {
        if (auto v = std::get_if<int32_t>(value)) { *out = *v; return true; }
        if (auto v = std::get_if<int64_t>(value)) { *out = *v; return true; }
      }
      return false;
    };
    int64_t session = 0;
    if (!active_ || !integer("session", &session) || session != session_) {
      result->Error("state", "截图会话已结束"); return;
    }
    if (name == "beginScroll") {
      if (scroll_) { result->Error("state", "长截图已开始"); return; }
      int64_t x, y, w, h, px, py, pw, ph;
      if (!integer("x", &x) || !integer("y", &y) || !integer("width", &w) ||
          !integer("height", &h) || !integer("panelX", &px) || !integer("panelY", &py) ||
          !integer("panelWidth", &pw) || !integer("panelHeight", &ph) ||
          x < 0 || y < 0 || w < 16 || h < 32 || px < 0 || py < 0 || pw < 1 || ph < 1 ||
          x > 40000 || y > 40000 || px > 40000 || py > 40000 ||
          w > 8192 || h > 8192 || pw > 40000 || ph > 40000 ||
          x + w > screen_.right - screen_.left || y + h > screen_.bottom - screen_.top ||
          px + pw > screen_.right - screen_.left || py + ph > screen_.bottom - screen_.top) {
        result->Error("region", "长截图选区无效"); return;
      }
      RECT rect{screen_.left + static_cast<LONG>(x), screen_.top + static_cast<LONG>(y),
          screen_.left + static_cast<LONG>(x + w), screen_.top + static_cast<LONG>(y + h)};
      RECT panel{screen_.left + static_cast<LONG>(px), screen_.top + static_cast<LONG>(py),
          screen_.left + static_cast<LONG>(px + pw), screen_.top + static_cast<LONG>(py + ph)};
      scroll_ = std::make_unique<ScrollCapture>(window_);
      std::string error;
      if (!scroll_->Begin(screen_, rect, panel, &error)) {
        scroll_.reset();
        ShowWindow(window_, SW_SHOW);
        SetForegroundWindow(window_);
        result->Error("capture", error); return;
      }
    }
    if (!scroll_) { result->Error("state", "长截图未开始"); return; }
    std::vector<uint8_t> pixels;
    std::string error;
    if (!scroll_->Frame(&pixels, &error)) {
      result->Error("capture", error); return;
    }
    result->Success(Value(Map{
        {Value("pixels"), Value(std::move(pixels))},
        {Value("width"), Value(scroll_->width())},
        {Value("height"), Value(scroll_->height())},
        {Value("session"), Value(session_)}}));
  } else if (name == "load") {
    editor_ready_ = true;
    if (active_) result->Success(Value(std::move(snapshot_)));
    else result->Success();
    snapshot_.clear();
  } else if (name == "ready") {
    const auto* id = call.arguments() ? std::get_if<int64_t>(call.arguments()) : nullptr;
    const auto* small_id = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
    if (!active_ || ((!id || *id != session_) && (!small_id || *small_id != session_))) {
      result->Success(); return;
    }
    KillTimer(window_, 1);
    if (scroll_) {
      scroll_.reset();
      MONITORINFO monitor{};
      monitor.cbSize = sizeof(monitor);
      if (GetMonitorInfo(MonitorFromRect(&screen_, MONITOR_DEFAULTTONEAREST), &monitor))
        screen_ = monitor.rcMonitor;
    }
    positioning_ = true;
    SetWindowPos(window_, HWND_TOPMOST, screen_.left, screen_.top,
                 screen_.right - screen_.left, screen_.bottom - screen_.top,
                 SWP_SHOWWINDOW);
    positioning_ = false;
    SetForegroundWindow(window_);
    SetFocus(editor_->view()->GetNativeWindow());
    result->Success();
  } else if (name == "close") {
    result->Success();
    const auto* id = call.arguments() ? std::get_if<int64_t>(call.arguments()) : nullptr;
    const auto* small_id = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
    if (active_ && ((id && *id == session_) || (small_id && *small_id == session_))) {
      PostMessage(owner_, kCloseMessage, 0, 0);
    }
  } else if (name == "commit" || name == "styles") {
    ++pending_calls_;
    auto alive = alive_;
    auto response = std::shared_ptr<Result>(std::move(result));
    main_channel_->InvokeMethod(name,
        call.arguments() ? std::make_unique<Value>(*call.arguments()) : nullptr,
        std::make_unique<flutter::MethodResultFunctions<Value>>(
            [this, response, alive](const Value* value) {
              if (!*alive) return;
              if (value) response->Success(*value); else response->Success();
              CompleteForwardedCall();
            },
            [this, response, alive](const std::string& code, const std::string& message,
                       const Value* details) {
              if (!*alive) return;
              if (details) response->Error(code, message, *details);
              else response->Error(code, message);
              CompleteForwardedCall();
            },
            [this, response, alive]() {
              if (!*alive) return;
              response->NotImplemented(); CompleteForwardedCall();
            }));
  } else {
    result->NotImplemented();
  }
}

void ScreenshotHost::CompleteForwardedCall() {
  --pending_calls_;
  if (pending_calls_ == 0 && close_pending_) PostMessage(owner_, kCloseMessage, 0, 0);
}

void ScreenshotHost::Close() {
  if (closing_ || (!active_ && !prepared_)) return;
  if (pending_calls_ != 0) { close_pending_ = true; return; }
  close_pending_ = false;
  closing_ = true;
  bool restore = window_ && GetForegroundWindow() == window_;
  scroll_.reset();
  if (window_) {
    KillTimer(window_, 1);
    ShowWindow(window_, SW_HIDE);
  }
  active_ = false;
  // Release session images and editing state; retain only the warm engine.
  if (editor_ready_) editor_channel_->InvokeMethod("reset", std::make_unique<Value>(session_));
  snapshot_.clear();
  prepared_ = false;
  if (restore && IsWindow(previous_foreground_) && IsWindowVisible(previous_foreground_)) {
    SetForegroundWindow(previous_foreground_);
  }
  main_channel_->InvokeMethod("closed", nullptr);
  closing_ = false;
}

LRESULT CALLBACK ScreenshotHost::WindowProc(HWND window, UINT message,
                                            WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<ScreenshotHost*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<ScreenshotHost*>(reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (self) {
    if (message == WM_HOTKEY && wparam == ScrollCapture::kCancelHotkey && self->scroll_) {
      PostMessage(self->owner_, kCloseMessage, 0, 0);
      return 0;
    }
    if (self->scroll_ && (message == WM_DISPLAYCHANGE ||
        (message == WM_DPICHANGED && !self->positioning_))) {
      self->scroll_->Invalidate();
      return 0;
    }
    if (message == WM_CLOSE || message == WM_DISPLAYCHANGE ||
        (message == WM_DPICHANGED && !self->positioning_) || (message == WM_TIMER && wparam == 1)) {
      if (self->active_) PostMessage(self->owner_, kCloseMessage, 0, 0);
      return 0;
    }
    if (self->editor_) {
      auto handled = self->editor_->HandleTopLevelWindowProc(window, message, wparam, lparam);
      if (handled) return *handled;
    }
    switch (message) {
      case WM_ACTIVATE:
        if (LOWORD(wparam) != WA_INACTIVE && self->editor_) {
          SetFocus(self->editor_->view()->GetNativeWindow());
        }
        return 0;
      case WM_SIZE:
        if (self->editor_) {
          RECT bounds{};
          GetClientRect(window, &bounds);
          MoveWindow(self->editor_->view()->GetNativeWindow(), 0, 0,
                     bounds.right, bounds.bottom, TRUE);
        }
        return 0;
    }
  }
  return DefWindowProc(window, message, wparam, lparam);
}
