#include "scroll_capture.h"

#include <dwmapi.h>
#include <algorithm>

namespace {
bool Inside(const RECT& inner, const RECT& outer) {
  return inner.left >= outer.left && inner.top >= outer.top &&
      inner.right <= outer.right && inner.bottom <= outer.bottom &&
      inner.right > inner.left && inner.bottom > inner.top;
}

bool CanExcludeCapture() {
  // Older Windows accepts 0x11 but produces a black rectangle instead.
  using VersionFunction = LONG(WINAPI*)(OSVERSIONINFOW*);
  const auto version = reinterpret_cast<VersionFunction>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
  OSVERSIONINFOW info{};
  info.dwOSVersionInfoSize = sizeof(info);
  return version && version(&info) == 0 &&
      (info.dwMajorVersion > 10 ||
       (info.dwMajorVersion == 10 && info.dwBuildNumber >= 19041));
}

struct Obstruction { HWND target; HWND editor; RECT rect; bool blocked = false; };
BOOL CALLBACK CheckObstruction(HWND hwnd, LPARAM data) {
  auto* check = reinterpret_cast<Obstruction*>(data);
  if (hwnd == check->target) return FALSE;
  if (hwnd == check->editor || !IsWindowVisible(hwnd) || IsIconic(hwnd)) return TRUE;
  DWORD cloaked = 0;
  DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
  if (cloaked) return TRUE;
  RECT bounds{}, intersection{};
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS,
                                   &bounds, sizeof(bounds)))) GetWindowRect(hwnd, &bounds);
  if (IntersectRect(&intersection, &bounds, &check->rect)) {
    check->blocked = true;
    return FALSE;
  }
  return TRUE;
}
}  // namespace

bool ReadDesktopPixels(const RECT& rect, std::vector<uint8_t>* pixels) {
  const int width = rect.right - rect.left, height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0 || static_cast<int64_t>(width) * height > 40000000) return false;
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
  void* data = nullptr;
  HBITMAP bitmap = CreateDIBSection(desktop, &info, DIB_RGB_COLORS, &data, nullptr, 0);
  bool success = false;
  if (memory && bitmap && data) {
    const auto previous = SelectObject(memory, bitmap);
    success = BitBlt(memory, 0, 0, width, height, desktop, rect.left, rect.top,
                     SRCCOPY | CAPTUREBLT) != FALSE;
    if (success) {
      const auto* bytes = static_cast<uint8_t*>(data);
      pixels->assign(bytes, bytes + static_cast<size_t>(width) * height * 4);
      for (size_t i = 3; i < pixels->size(); i += 4) (*pixels)[i] = 255;
    }
    SelectObject(memory, previous);
  }
  if (bitmap) DeleteObject(bitmap);
  if (memory) DeleteDC(memory);
  ReleaseDC(nullptr, desktop);
  return success;
}

bool ScrollCapture::Begin(const RECT& screen, const RECT& rect,
                           const RECT& panel, std::string* error) {
  screen_ = screen;
  rect_ = rect;
  if (!Inside(rect, screen) || !Inside(panel, screen) || width() < 16 || height() < 32 ||
      width() > 8192 || height() > 8192 || static_cast<int64_t>(width()) * height() > 16000000) {
    *error = "选区过小或过大，请重新框选滚动内容";
    return false;
  }
  ShowWindow(editor_, SW_HIDE);
  DwmFlush();
  const POINT center{rect.left + width() / 2, rect.top + height() / 2};
  target_ = GetAncestor(WindowFromPoint(center), GA_ROOT);
  if (!target_ || target_ == editor_ || !GetWindowRect(target_, &target_bounds_) ||
      !Inside(rect, target_bounds_)) {
    *error = "请框选同一个窗口中的滚动内容区域";
    Restore();
    return false;
  }
  constexpr DWORD kExclude = 0x11;
  const bool excluded = CanExcludeCapture() && SetWindowDisplayAffinity(editor_, kExclude);
  RECT overlap{};
  if (IntersectRect(&overlap, &rect, &panel) && !excluded) {
    *error = "无法将控制区排除在截图外，请缩小选区以留出控制区位置";
    Restore();
    return false;
  }
  const auto relative = [&](RECT r) {
    OffsetRect(&r, -screen.left, -screen.top);
    return r;
  };
  RECT outer = rect;
  InflateRect(&outer, 2, 2);
  IntersectRect(&outer, &outer, &screen);
  outer = relative(outer);
  const RECT inner = relative(rect), controls = relative(panel);
  HRGN region = CreateRectRgnIndirect(&outer);
  HRGN hole = CreateRectRgnIndirect(&inner);
  HRGN panel_region = CreateRectRgnIndirect(&controls);
  bool configured = region && hole && panel_region &&
      CombineRgn(region, region, hole, RGN_DIFF) != ERROR &&
      CombineRgn(region, region, panel_region, RGN_OR) != ERROR;
  if (hole) DeleteObject(hole);
  if (panel_region) DeleteObject(panel_region);
  if (configured) configured = SetWindowRgn(editor_, region, TRUE) != 0;
  if (!configured) {
    if (region) DeleteObject(region);
    *error = "无法创建长截图控制界面，请重试";
    Restore();
    return false;
  }
  // SetWindowRgn now owns region.
  hotkey_ = RegisterHotKey(editor_, kCancelHotkey, MOD_NOREPEAT, VK_ESCAPE) != FALSE;
  if (!hotkey_) {
    *error = "无法启用长截图的 Esc 取消键，请关闭占用该按键的程序后重试";
    Restore();
    return false;
  }
  active_ = true;
  invalidated_ = false;
  SetForegroundWindow(target_);
  SetWindowPos(editor_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  DwmFlush();
  return true;
}

bool ScrollCapture::Frame(std::vector<uint8_t>* pixels, std::string* error) {
  RECT bounds{};
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!active_ || invalidated_ ||
      !GetMonitorInfo(MonitorFromRect(&screen_, MONITOR_DEFAULTTONULL), &monitor) ||
      !EqualRect(&monitor.rcMonitor, &screen_)) {
    *error = "屏幕布局已改变，请点击完成编辑已有内容";
    return false;
  }
  if (!IsWindow(target_) || !IsWindowVisible(target_) || IsIconic(target_) ||
      !GetWindowRect(target_, &bounds) || !EqualRect(&bounds, &target_bounds_)) {
    *error = "目标窗口已移动或不可见，请恢复原位置，或点击完成";
    return false;
  }
  Obstruction obstruction{target_, editor_, rect_};
  EnumWindows(CheckObstruction, reinterpret_cast<LPARAM>(&obstruction));
  // Windows can scroll an unobscured inactive window. Focus alone must not
  // invalidate its pixels; geometry and z-order determine capture validity.
  if (obstruction.blocked) {
    *error = "目标区域被其他窗口遮挡，请移开遮挡窗口，或点击完成";
    return false;
  }
  if (!ReadDesktopPixels(rect_, pixels)) {
    *error = "暂时无法采集画面，请重试或点击完成";
    return false;
  }
  return true;
}

void ScrollCapture::Restore() {
  if (hotkey_) UnregisterHotKey(editor_, kCancelHotkey);
  hotkey_ = false;
  active_ = false;
  if (IsWindow(editor_)) {
    SetWindowRgn(editor_, nullptr, TRUE);
    SetWindowDisplayAffinity(editor_, WDA_NONE);
  }
}
