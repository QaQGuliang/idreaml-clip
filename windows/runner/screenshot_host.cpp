#include "screenshot_host.h"

#include <commdlg.h>
#include <dwmapi.h>
#include <flutter_windows.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <iterator>
#include <string>
#include <vector>

#include "resource.h"

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

bool Integer(const Map* map, const char* key, int64_t* out) {
  const auto* value = map ? Field(*map, key) : nullptr;
  if (value) {
    if (auto v = std::get_if<int32_t>(value)) { *out = *v; return true; }
    if (auto v = std::get_if<int64_t>(value)) { *out = *v; return true; }
  }
  return false;
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

void ScreenshotHost::InvokePinAction(HWND window, const char* method, Value argument,
                                     const wchar_t* error) {
  const auto failed = [window, alive = alive_, error]() {
    if (*alive && IsWindow(window)) MessageBoxW(window, error, L"理梦剪藏", MB_OK | MB_ICONWARNING);
  };
  main_channel_->InvokeMethod(method, std::make_unique<Value>(std::move(argument)),
      std::make_unique<flutter::MethodResultFunctions<Value>>(
          [](const Value*) {},
          [failed](const std::string&, const std::string&, const Value*) { failed(); }, failed));
}

void ScreenshotHost::HandleMain(const flutter::MethodCall<Value>& call,
                                std::unique_ptr<Result> result) {
  const auto& method = call.method_name();
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (method == "setPinBorderDefault") {
    const auto* value = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
    if (!value || !pins_.SetDefaultBorder(*value)) { result->Error("border", "未知的贴图边框"); return; }
    result->Success();
  } else if (method == "warmUp") {
    if (!EnsureEditor()) {
      DestroyEditor();
      result->Error("window", "无法预热截图编辑窗口"); return;
    }
    result->Success();
  } else if (method == "prepare") {
    if (active_) { result->Error("busy", "已有截图正在进行"); return; }
    // The panel can disappear between prepare and open. Keep the invocation
    // point in signed physical desktop coordinates until the snapshot exists.
    if (!GetCursorPos(&initial_cursor_) && args) {
      const auto* x = Field(*args, "x");
      const auto* y = Field(*args, "y");
      if (x && y && std::holds_alternative<double>(*x) && std::holds_alternative<double>(*y)) {
        initial_cursor_ = {static_cast<LONG>(std::get<double>(*x)),
                           static_cast<LONG>(std::get<double>(*y))};
        ClientToScreen(main_view_, &initial_cursor_);
      }
    }
    ++session_;
    pinned_ = false;
    wait_for_compositor_ = args && Field(*args, "x");
    previous_foreground_ = GetForegroundWindow();
    prepared_ = true;
    result->Success();
  } else if (method == "open") {
    if (!prepared_ || active_) { result->Error("state", "截图状态无效"); return; }
    prepared_ = false;
    snapshot_.clear();
    if (!Capture()) { result->Error("capture", "无法捕获桌面，或桌面总尺寸超过截图上限"); return; }
    snapshot_[Value("session")] = Value(session_);
    if (args) {
      if (auto styles = Field(*args, "styles")) snapshot_[Value("styles")] = *styles;
      if (auto arrow = Field(*args, "defaultArrowStyle")) snapshot_[Value("defaultArrowStyle")] = *arrow;
      if (auto picker = Field(*args, "showColorPicker")) snapshot_[Value("showColorPicker")] = *picker;
      if (auto scroll = Field(*args, "autoScroll")) snapshot_[Value("autoScroll")] = *scroll;
      if (auto shortcut = Field(*args, "screenshotShortcut")) snapshot_[Value("screenshotShortcut")] = *shortcut;
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
    local_shortcuts_ = false;
    consumed_keys_.clear();
    SetTimer(window_, 1, 15000, nullptr);
    if (editor_ready_) {
      auto payload = std::make_unique<Value>();
      payload->emplace<Map>().swap(snapshot_);
      editor_channel_->InvokeMethod("start", std::move(payload));
    }
    result->Success();
  } else if (method == "pinImage") {
    if (!active_) { result->Error("state", "截图窗口已关闭"); return; }
    if (pinned_) { result->Success(); return; }
    const auto* value = args ? Field(*args, "png") : nullptr;
    const auto* png = value ? std::get_if<std::vector<uint8_t>>(value) : nullptr;
    int64_t x, y;
    if (!png || !Integer(args, "x", &x) || !Integer(args, "y", &y) ||
        x < 0 || y < 0 || x >= screen_.right - screen_.left || y >= screen_.bottom - screen_.top) {
      result->Error("region", "贴图内容或位置无效"); return;
    }
    const POINT origin{screen_.left + static_cast<LONG>(x), screen_.top + static_cast<LONG>(y)};
    const auto copy = [this](HWND window, const std::vector<uint8_t>& image) {
      InvokePinAction(window, "copyPinnedImage", Value(image), L"无法复制贴图，请重试。");
    };
    const auto save_border = [this](HWND window, const std::string& border) {
      InvokePinAction(window, "savePinBorderDefault", Value(border), L"无法保存默认贴图边框，请重试。");
    };
    MONITORINFO pin_monitor{};
    pin_monitor.cbSize = sizeof(pin_monitor);
    if (!GetMonitorInfo(MonitorFromPoint(origin, MONITOR_DEFAULTTONEAREST), &pin_monitor) ||
        !pins_.Show(*png, origin, pin_monitor.rcWork, copy, save_border)) {
      result->Error("window", "无法显示贴图，请重试"); return;
    }
    // Keep the editor reachable if history storage fails after pinning a full screen.
    // Closing the session hides it and reveals the pinned window underneath.
    SetWindowPos(window_, long_editor_ ? HWND_TOP : HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    pinned_ = true;
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
  const auto monitors = DesktopMonitors();
  screen_ = DesktopBounds(monitors);
  const int width = screen_.right - screen_.left;
  const int height = screen_.bottom - screen_.top;
  if (width <= 0 || height <= 0 || width > 16384 || height > 16384 ||
      static_cast<int64_t>(width) * height > 40000000) return false;
  // Wait for the compositor to reflect the button-path panel hide.
  if (wait_for_compositor_) DwmFlush();
  std::vector<uint8_t> image;
  if (!ReadDesktopPixels(screen_, &image)) return false;
  for (const auto& gap : DesktopGaps(screen_, monitors)) {
    for (LONG y = gap.top; y < gap.bottom; ++y) {
      const auto offset = (static_cast<size_t>(y - screen_.top) * width +
                            (gap.left - screen_.left)) * 4;
      std::fill_n(image.begin() + offset, (gap.right - gap.left) * 4, uint8_t{0});
    }
  }
  snapshot_[Value("pixels")].emplace<std::vector<uint8_t>>(std::move(image));
  snapshot_[Value("width")] = Value(width);
  snapshot_[Value("height")] = Value(height);
  snapshot_[Value("originX")] = Value(static_cast<int32_t>(screen_.left));
  snapshot_[Value("originY")] = Value(static_cast<int32_t>(screen_.top));
  snapshot_[Value("initialCursorX")] = Value(static_cast<int32_t>(initial_cursor_.x - screen_.left));
  snapshot_[Value("initialCursorY")] = Value(static_cast<int32_t>(initial_cursor_.y - screen_.top));
  List displays;
  for (const auto& r : monitors) {
    displays.emplace_back(List{
        Value(static_cast<int32_t>(r.left - screen_.left)), Value(static_cast<int32_t>(r.top - screen_.top)),
        Value(static_cast<int32_t>(r.right - screen_.left)), Value(static_cast<int32_t>(r.bottom - screen_.top))});
  }
  snapshot_[Value("monitors")] = Value(std::move(displays));
  WindowCandidates candidates{screen_, {}};
  EnumWindows(CollectWindows, reinterpret_cast<LPARAM>(&candidates));
  snapshot_[Value("windows")] = Value(std::move(candidates.windows));
  return true;
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
  cls.hIcon = LoadIcon(cls.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
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

void ScreenshotHost::ShowLongEditor(const RECT& selection) {
  const auto monitor = MonitorFromRect(&selection, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{sizeof(info)};
  RECT work = selection;
  if (GetMonitorInfo(monitor, &info)) work = info.rcWork;
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  // A narrow capture can still use the full set of editing tools.
  const LONG ideal_width = std::clamp<LONG>(selection.right - selection.left + MulDiv(40, dpi, 96),
                                            MulDiv(1000, dpi, 96), MulDiv(1320, dpi, 96));
  const LONG width = std::min<LONG>(ideal_width, (work.right - work.left) * 9 / 10);
  const LONG height = std::min<LONG>(MulDiv(800, dpi, 96), (work.bottom - work.top) * 9 / 10);
  // The host is hidden while changing the taskbar style so Explorer updates its entry.
  long_editor_ = true;
  // Flutter draws the shared title/toolbar. Windows owns the resize border,
  // system menu, taskbar and maximize/restore geometry.
  SetWindowLongPtr(window_, GWL_STYLE, WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
  SetWindowLongPtr(window_, GWL_EXSTYLE, WS_EX_APPWINDOW);
  SetWindowTextW(window_, L"理梦剪藏 · 长图编辑");
  SetWindowPos(window_, HWND_NOTOPMOST, work.left + (work.right - work.left - width) / 2,
               work.top + (work.bottom - work.top - height) / 2, width, height,
               SWP_FRAMECHANGED | SWP_SHOWWINDOW);
}

void ScreenshotHost::RestoreOverlayStyle() {
  // Close() has hidden the window; discard maximized/minimized state as well.
  long_editor_ = false;
  maximized_ = false;
  SetWindowLongPtr(window_, GWL_STYLE, WS_POPUP);
  SetWindowLongPtr(window_, GWL_EXSTYLE, WS_EX_TOOLWINDOW);
  SetWindowTextW(window_, L"理梦剪藏 · 截图");
  SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

// Run before TranslateMessage so an intercepted C cannot generate a WM_CHAR.
// Route only the editor's own input, leaving normal typing and IME to Flutter.
bool ScreenshotHost::HandleShortcut(const MSG& message) {
  if (message.message != WM_KEYDOWN && message.message != WM_KEYUP) return false;
  const char* action;
  switch (message.wParam) {
    case VK_ESCAPE: action = "escape"; break;
    case VK_F2: action = "togglePicker"; break;
    case 'C': action = "copyColor"; break;
    default: return false;
  }
  if (!active_ || scroll_ || !IsWindowVisible(window_) || GetForegroundWindow() != window_) {
    return false;
  }
  const HWND child = editor_->view()->GetNativeWindow();
  const HWND focus = GetFocus();
  if ((message.hwnd != child && message.hwnd != window_) ||
      (focus != child && focus != window_)) return false;

  if (message.message == WM_KEYUP) return consumed_keys_.erase(message.wParam) != 0;
  if (message.lParam & (1L << 30)) return consumed_keys_.count(message.wParam) != 0;
  consumed_keys_.erase(message.wParam);  // An earlier release may have gone to another window.
  if (!local_shortcuts_ ||
      (GetKeyState(VK_CONTROL) | GetKeyState(VK_SHIFT) | GetKeyState(VK_MENU) |
       GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) return false;

  consumed_keys_.insert(message.wParam);
  editor_channel_->InvokeMethod("localShortcut", std::make_unique<Value>(Map{
      {Value("session"), Value(session_)}, {Value("key"), Value(action)}}));
  return true;
}

void ScreenshotHost::HandleEditor(const flutter::MethodCall<Value>& call,
                                  std::unique_ptr<Result> result) {
  const auto& name = call.method_name();
  const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (name == "setLocalShortcuts") {
    int64_t session = 0;
    const auto* value = args ? Field(*args, "enabled") : nullptr;
    const auto* enabled = value ? std::get_if<bool>(value) : nullptr;
    if (active_ && Integer(args, "session", &session) && session == session_ && enabled) {
      local_shortcuts_ = *enabled;
    }
    result->Success();
    return;
  }
  if (name == "longEditorWindow") {
    int64_t session = 0;
    if (!active_ || !long_editor_ || !Integer(args, "session", &session) || session != session_) {
      result->Success(); return;
    }
    const auto* value = Field(*args, "action");
    const auto* action = value ? std::get_if<std::string>(value) : nullptr;
    if (action && *action == "minimize") {
      ShowWindow(window_, SW_MINIMIZE);
    } else if (action && *action == "toggleMaximize") {
      ShowWindow(window_, IsZoomed(window_) ? SW_RESTORE : SW_MAXIMIZE);
    } else if (action && *action == "drag") {
      POINT point{};
      // The gesture starts on the Flutter child, which may hold mouse capture.
      // Ignore delayed gestures after the user has already released the button.
      const int primary = GetSystemMetrics(SM_SWAPBUTTON) ? VK_RBUTTON : VK_LBUTTON;
      if ((GetAsyncKeyState(primary) & 0x8000) && GetCursorPos(&point)) {
        ReleaseCapture();
        SendMessage(window_, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(point.x, point.y));
      }
    } else {
      result->Error("window", "未知的长图窗口操作"); return;
    }
    result->Success(); return;
  }
  if (name == "copyColor") {
    int64_t session = 0;
    if (!active_ || scroll_ || !Integer(args, "token", &session) || session != session_) {
      result->Error("state", "取色会话已结束"); return;
    }
    const auto* value = Field(*args, "hex");
    const auto* hex = value ? std::get_if<std::string>(value) : nullptr;
    if (!hex || hex->size() != 7 || hex->front() != '#' ||
        hex->find_first_not_of("0123456789ABCDEFabcdef", 1) != std::string::npos) {
      result->Error("color", "颜色值无效"); return;
    }
  }
  if (name == "beginScroll" || name == "scrollFrame" || name == "scrollStep") {
    auto integer = [&](const char* key, int64_t* out) {
      return Integer(args, key, out);
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
        const char* code = scroll_->obscured() ? "obscured" : "capture";
        scroll_.reset();
        ShowWindow(window_, SW_SHOW);
        SetForegroundWindow(window_);
        result->Error(code, error); return;
      }
    }
    if (!scroll_) { result->Error("state", "长截图未开始"); return; }
    std::string error;
    if (name == "scrollStep") {
      if (!scroll_->ScrollStep(&error)) {
        result->Error(scroll_->obscured() ? "obscured" : "scroll", error); return;
      }
      result->Success();
      return;
    }
    // Write directly into the codec payload. A map initializer_list copies its
    // elements, including the entire BGRA buffer on every captured frame.
    Value frame;
    auto& fields = frame.emplace<Map>();
    auto& pixels = fields[Value("pixels")].emplace<std::vector<uint8_t>>();
    if (!scroll_->Frame(&pixels, &error)) {
      const char* code = scroll_->obscured() ? "obscured" : "capture";
      if (name == "beginScroll") {
        scroll_.reset();
        ShowWindow(window_, SW_SHOW);
        SetForegroundWindow(window_);
      }
      result->Error(code, error); return;
    }
    fields.emplace(Value("width"), Value(scroll_->width()));
    fields.emplace(Value("height"), Value(scroll_->height()));
    fields.emplace(Value("session"), Value(session_));
    result->Success(frame);
  } else if (name == "load") {
    editor_ready_ = true;
    if (active_) {
      Value payload;
      payload.emplace<Map>().swap(snapshot_);
      result->Success(payload);
    } else {
      snapshot_.clear();
      result->Success();
    }
  } else if (name == "ready" || name == "longEditorReady") {
    const auto* id = call.arguments() ? std::get_if<int64_t>(call.arguments()) : nullptr;
    const auto* small_id = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
    if (!active_ || ((!id || *id != session_) && (!small_id || *small_id != session_))) {
      result->Success(); return;
    }
    KillTimer(window_, 1);
    local_shortcuts_ = true;
    if (long_editor_ || (name == "longEditorReady" && !scroll_)) {
      result->Success(); return;
    }
    positioning_ = true;
    if (name == "longEditorReady") {
      const RECT selection = scroll_->selection();
      ShowWindow(window_, SW_HIDE);
      scroll_.reset();  // Remove the capture region before showing the editor.
      ShowLongEditor(selection);
    } else {
      scroll_.reset();
      SetWindowPos(window_, HWND_TOPMOST, screen_.left, screen_.top,
                   screen_.right - screen_.left, screen_.bottom - screen_.top,
                   SWP_SHOWWINDOW);
    }
    positioning_ = false;
    // Hiding the quick panel or opening from a background hotkey can leave
    // another application's input queue in the foreground. A topmost popup
    // remains visible in that case, but typing still goes to the other app.
    if (!SetForegroundWindow(window_)) {
      HWND foreground = GetForegroundWindow();
      DWORD thread = GetCurrentThreadId();
      DWORD other = foreground ? GetWindowThreadProcessId(foreground, nullptr) : 0;
      if (foreground != window_ && other && other != thread &&
          !IsHungAppWindow(foreground) && AttachThreadInput(thread, other, TRUE)) {
        SetForegroundWindow(window_);
        AttachThreadInput(thread, other, FALSE);
      }
    }
    SetFocus(editor_->view()->GetNativeWindow());
    result->Success();
  } else if (name == "close") {
    result->Success();
    const auto* id = call.arguments() ? std::get_if<int64_t>(call.arguments()) : nullptr;
    const auto* small_id = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
    if (active_ && ((id && *id == session_) || (small_id && *small_id == session_))) {
      PostMessage(owner_, kCloseMessage, 0, 0);
    }
  } else if (name == "commit" || name == "styles" || name == "copyColor" ||
             name == "getScreenshotShortcut") {
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
    if (long_editor_) RestoreOverlayStyle();
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
    if (message == WM_CLOSE && self->long_editor_ && self->active_) {
      self->editor_channel_->InvokeMethod("requestClose", std::make_unique<Value>(self->session_));
      return 0;
    }
    if (message == WM_CLOSE || (!self->long_editor_ && (message == WM_DISPLAYCHANGE ||
        (message == WM_DPICHANGED && !self->positioning_))) || (message == WM_TIMER && wparam == 1)) {
      if (self->active_) PostMessage(self->owner_, kCloseMessage, 0, 0);
      return 0;
    }
    if (self->editor_) {
      auto handled = self->editor_->HandleTopLevelWindowProc(window, message, wparam, lparam);
      if (handled) return *handled;
    }
    switch (message) {
      case WM_DPICHANGED:
        if (self->long_editor_ && !self->positioning_) {
          const auto& rect = *reinterpret_cast<const RECT*>(lparam);
          SetWindowPos(window, nullptr, rect.left, rect.top, rect.right - rect.left,
                       rect.bottom - rect.top, SWP_NOZORDER | SWP_NOACTIVATE);
          return 0;
        }
        break;
      case WM_GETMINMAXINFO:
        if (self->long_editor_) {
          const auto monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
          const auto dpi = FlutterDesktopGetDpiForMonitor(monitor);
          auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
          limits->ptMinTrackSize = {MulDiv(420, dpi, 96), MulDiv(360, dpi, 96)};
          // Windows otherwise maximizes a captionless frame over the taskbar.
          MONITORINFO info{sizeof(info)};
          WINDOWINFO frame{sizeof(frame)};
          if (GetMonitorInfo(monitor, &info) && GetWindowInfo(window, &frame)) {
            RECT bounds = info.rcWork;
            InflateRect(&bounds, frame.cxWindowBorders, frame.cyWindowBorders);
            limits->ptMaxPosition = {bounds.left - info.rcMonitor.left, bounds.top - info.rcMonitor.top};
            limits->ptMaxSize = {bounds.right - bounds.left, bounds.bottom - bounds.top};
          }
          return 0;
        }
        break;
      case WM_ACTIVATE:
        if (LOWORD(wparam) == WA_INACTIVE) return 0;
        [[fallthrough]];
      case WM_SETFOCUS:
        if (self->editor_) {
          SetFocus(self->editor_->view()->GetNativeWindow());
        }
        return 0;
      case WM_SIZE:
        if (self->long_editor_ && self->editor_channel_ &&
            (wparam == SIZE_RESTORED || wparam == SIZE_MAXIMIZED)) {
          const bool maximized = wparam == SIZE_MAXIMIZED;
          if (self->maximized_ != maximized) {
            self->maximized_ = maximized;
            self->editor_channel_->InvokeMethod("longEditorWindowState", std::make_unique<Value>(Map{
                {Value("session"), Value(self->session_)}, {Value("maximized"), Value(maximized)}}));
          }
        }
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
