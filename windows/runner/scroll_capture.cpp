#include "scroll_capture.h"

#include <dwmapi.h>
#include <algorithm>
#include <climits>

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

bool DrawsIn(HWND hwnd, const RECT& rect) {
  if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return false;
  DWORD cloaked = 0;
  DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked, sizeof(cloaked));
  if (cloaked) return false;
  RECT bounds{}, intersection{};
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS,
                                   &bounds, sizeof(bounds)))) GetWindowRect(hwnd, &bounds);
  if (!IntersectRect(&intersection, &bounds, &rect)) return false;
  if (GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_LAYERED) {
    BYTE alpha = 255;
    DWORD flags = 0;
    if (GetLayeredWindowAttributes(hwnd, nullptr, &alpha, &flags) &&
        (flags & LWA_ALPHA) && alpha == 0) return false;
  }
  // GetWindowRgn coordinates start at GetWindowRect, including invisible
  // resize margins. DWM's visible frame bounds can have a different origin.
  HRGN shape = CreateRectRgn(0, 0, 0, 0);
  bool draws = true;
  if (shape) {
    if (GetWindowRgn(hwnd, shape) != ERROR && GetWindowRect(hwnd, &bounds)) {
      OffsetRect(&intersection, -bounds.left, -bounds.top);
      draws = RectInRegion(shape, &intersection) != FALSE;
    }
    DeleteObject(shape);
  }
  return draws;
}

struct Obstruction { HWND target; HWND editor; RECT rect; bool blocked = false; };
BOOL CALLBACK CheckObstruction(HWND hwnd, LPARAM data) {
  auto* check = reinterpret_cast<Obstruction*>(data);
  if (hwnd == check->target) return FALSE;
  check->blocked = hwnd != check->editor && DrawsIn(hwnd, check->rect);
  return !check->blocked;
}

struct WindowAtSelection { RECT region; RECT center; HWND window = nullptr; };
BOOL CALLBACK FindContainingWindow(HWND hwnd, LPARAM data) {
  auto* selection = reinterpret_cast<WindowAtSelection*>(data);
  RECT bounds{};
  if (!GetWindowRect(hwnd, &bounds) || !Inside(selection->region, bounds) ||
      !DrawsIn(hwnd, selection->center)) return TRUE;
  selection->window = hwnd;
  return FALSE;
}

BOOL CALLBACK CollectMonitor(HMONITOR, HDC, LPRECT bounds, LPARAM data) {
  reinterpret_cast<std::vector<RECT>*>(data)->push_back(*bounds);
  return TRUE;
}

bool IsChromiumViewport(HWND window) {
  wchar_t name[64]{};
  return GetClassNameW(window, name, 64) && wcscmp(name, L"Chrome_RenderWidgetHostHWND") == 0;
}

HWND ChildAt(HWND window, POINT screen) {
  while (window) {
    POINT point = screen;
    if (!ScreenToClient(window, &point)) return nullptr;
    constexpr UINT flags = CWP_SKIPINVISIBLE | CWP_SKIPDISABLED;
    HWND child = ChildWindowFromPointEx(window, point, flags);
    // Chromium marks its wheel-message bridge WS_EX_TRANSPARENT despite
    // explicitly forwarding WM_MOUSEWHEEL to the page's event target.
    if (child && child != window && (GetWindowLongPtrW(child, GWL_EXSTYLE) & WS_EX_TRANSPARENT) &&
        !IsChromiumViewport(child)) {
      child = ChildWindowFromPointEx(window, point, flags | CWP_SKIPTRANSPARENT);
    }
    if (child == window || !child) return window;
    window = child;
  }
  return nullptr;
}

HWND ScrollbarOwner(HWND hit, HWND root) {
  for (HWND window = hit; window; window = GetParent(window)) {
    if (GetWindowLongPtrW(window, GWL_STYLE) & WS_VSCROLL) return window;
    if (window == root) break;
  }
  return nullptr;
}

struct PaneCheck {
  HWND root, selected;
  RECT region;
  bool conflicting = false;
};

BOOL CALLBACK CheckScrollPane(HWND hwnd, LPARAM data) {
  auto* check = reinterpret_cast<PaneCheck*>(data);
  if (hwnd == check->selected || IsChild(hwnd, check->selected) || !IsWindowVisible(hwnd) ||
      !(GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_VSCROLL)) return TRUE;
  RECT bounds{}, overlap{};
  if (!GetWindowRect(hwnd, &bounds) || !IntersectRect(&overlap, &bounds, &check->region)) return TRUE;
  const POINT mid{(overlap.left + overlap.right) / 2, (overlap.top + overlap.bottom) / 2};
  const HWND hit = ChildAt(check->root, mid);
  if (hwnd != hit && !IsChild(hwnd, hit)) return TRUE;
  check->conflicting = true;
  return FALSE;
}

bool OneScrollPane(HWND target, HWND center, const RECT& rect) {
  const HWND pane = ScrollbarOwner(center, target);
  // Static window chrome and borders may surround the selected scroll pane.
  // Only another visible scroll pane creates an ambiguous wheel destination.
  PaneCheck check{target, pane ? pane : center, rect};
  EnumChildWindows(target, CheckScrollPane, reinterpret_cast<LPARAM>(&check));
  return !check.conflicting;
}
}  // namespace

std::vector<RECT> DesktopMonitors() {
  std::vector<RECT> monitors;
  if (!EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                           reinterpret_cast<LPARAM>(&monitors))) monitors.clear();
  return monitors;
}

RECT DesktopBounds(const std::vector<RECT>& monitors) {
  RECT bounds{};
  for (const auto& monitor : monitors) UnionRect(&bounds, &bounds, &monitor);
  return bounds;
}

std::vector<RECT> DesktopGaps(const RECT& rect, const std::vector<RECT>& monitors) {
  std::vector<RECT> gaps{rect};
  for (const auto& monitor : monitors) {
    std::vector<RECT> remaining;
    for (const auto& gap : gaps) {
      RECT cut{};
      if (!IntersectRect(&cut, &gap, &monitor)) {
        remaining.push_back(gap);
        continue;
      }
      if (cut.top > gap.top) remaining.push_back({gap.left, gap.top, gap.right, cut.top});
      if (cut.bottom < gap.bottom) remaining.push_back({gap.left, cut.bottom, gap.right, gap.bottom});
      if (cut.left > gap.left) remaining.push_back({gap.left, cut.top, cut.left, cut.bottom});
      if (cut.right < gap.right) remaining.push_back({cut.right, cut.top, gap.right, cut.bottom});
    }
    gaps.swap(remaining);
    if (gaps.empty()) break;
  }
  return gaps;
}

// One DC and one top-down DIB for the entire scroll session.
class DesktopPixelReader {
 public:
  explicit DesktopPixelReader(const RECT& rect) : rect_(rect) {
    const LONG w = rect.right - rect.left, h = rect.bottom - rect.top;
    if (w < 1 || h < 1 || static_cast<int64_t>(w) * h > 40000000) return;
    desktop_ = GetDC(nullptr);
    if (!desktop_) return;
    memory_ = CreateCompatibleDC(desktop_);
    if (!memory_) return;
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = w;
    info.bmiHeader.biHeight = -h;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    bitmap_ = CreateDIBSection(desktop_, &info, DIB_RGB_COLORS, &data_, nullptr, 0);
    if (bitmap_) previous_ = SelectObject(memory_, bitmap_);
  }

  ~DesktopPixelReader() {
    if (previous_) SelectObject(memory_, previous_);
    if (bitmap_) DeleteObject(bitmap_);
    if (memory_) DeleteDC(memory_);
    if (desktop_) ReleaseDC(nullptr, desktop_);
  }

  bool Read(std::vector<uint8_t>* pixels) {
    const LONG w = rect_.right - rect_.left, h = rect_.bottom - rect_.top;
    if (!previous_ || !data_ || !BitBlt(memory_, 0, 0, w, h, desktop_, rect_.left, rect_.top,
                                        SRCCOPY | CAPTUREBLT) || !GdiFlush()) return false;
    const size_t count = static_cast<size_t>(w) * h;
    auto* words = static_cast<uint32_t*>(data_);
    for (size_t i = 0; i < count; ++i) words[i] |= 0xff000000u;
    const auto* bytes = static_cast<const uint8_t*>(data_);
    pixels->assign(bytes, bytes + count * 4);
    return true;
  }

 private:
  const RECT rect_;
  HDC desktop_ = nullptr, memory_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ previous_ = nullptr;
  void* data_ = nullptr;
};

bool ReadDesktopPixels(const RECT& rect, std::vector<uint8_t>* pixels) {
  return DesktopPixelReader(rect).Read(pixels);
}

ScrollCapture::ScrollCapture(HWND editor) : editor_(editor) {}
ScrollCapture::~ScrollCapture() { Restore(); }

bool ScrollCapture::Begin(const RECT& screen, const RECT& rect,
                           const RECT& panel, std::string* error) {
  screen_ = screen;
  rect_ = rect;
  obscured_ = false;
  if (!Inside(rect, screen) || !Inside(panel, screen) || width() < 16 || height() < 32 ||
      width() > 8192 || height() > 8192 || static_cast<int64_t>(width()) * height() > 16000000) {
    *error = "选区过小或过大，请重新框选滚动内容";
    return false;
  }
  const auto monitors = DesktopMonitors();
  if (!DesktopGaps(rect, monitors).empty() || !DesktopGaps(panel, monitors).empty()) {
    *error = "滚动选区和控制区必须完整位于显示器的可见区域内";
    return false;
  }
  const bool editor_had_focus = GetForegroundWindow() == editor_;
  ShowWindow(editor_, SW_HIDE);
  DwmFlush();
  const POINT center{rect.left + width() / 2, rect.top + height() / 2};
  WindowAtSelection selection{rect, {center.x, center.y, center.x + 1, center.y + 1}};
  EnumWindows(FindContainingWindow, reinterpret_cast<LPARAM>(&selection));
  target_ = selection.window;
  if (!target_ || target_ == editor_ || !GetWindowRect(target_, &target_bounds_) ||
      !Inside(rect, target_bounds_)) {
    *error = "请框选同一个窗口中的滚动内容区域";
    Restore();
    return false;
  }
  source_thread_ = GetWindowThreadProcessId(target_, &source_process_);
  wheel_point_ = center;
  wheel_target_ = ChildAt(target_, center);
  RECT viewport{}, contents{};
  if (GetWindowRect(wheel_target_, &viewport) && IntersectRect(&contents, &viewport, &rect)) {
    // Stay in the same control and out of our panel. In a browser a central
    // media player may consume the wheel, so prefer the lower content area.
    const LONG y = IsChromiumViewport(wheel_target_)
        ? contents.top + (contents.bottom - contents.top) * 7 / 8 : center.y;
    const POINT anchors[] = {{center.x, y}, {panel.left - 1, y},
                             {panel.right, y}, center, {center.x, panel.top - 1},
                             {center.x, panel.bottom}};
    for (const POINT anchor : anchors) {
      if (PtInRect(&contents, anchor) && !PtInRect(&panel, anchor) &&
          ChildAt(target_, anchor) == wheel_target_) {
        wheel_point_ = anchor;
        break;
      }
    }
  }
  wheel_thread_ = GetWindowThreadProcessId(wheel_target_, &wheel_process_);
  // Top-level bounds alone don't detect a region spanning two overlapping
  // windows or adjacent native scroll panes in the same application.
  if (!OneScrollPane(target_, wheel_target_, rect_)) {
    *error = "选区包含不同的滚动窗格，请只框选其中一个";
    Restore();
    return false;
  }
  if (!CheckObscured(error)) {
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
  if (editor_had_focus) SetForegroundWindow(target_);
  SetWindowPos(editor_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  DwmFlush();
  return true;
}

bool ScrollCapture::CheckSource(std::string* error) {
  obscured_ = false;
  RECT bounds{};
  if (!active_ || invalidated_) {
    *error = "屏幕布局已改变，请点击完成编辑已有内容";
    return false;
  }
  DWORD pid = 0;
  if (GetWindowThreadProcessId(target_, &pid) != source_thread_ || pid != source_process_ ||
      !IsWindowVisible(target_) || IsIconic(target_) ||
      !GetWindowRect(target_, &bounds) || !EqualRect(&bounds, &target_bounds_)) {
    *error = "目标窗口已移动或不可见，请恢复原位置，或点击完成";
    return false;
  }
  return CheckObscured(error);
}

bool ScrollCapture::CheckObscured(std::string* error) {
  Obstruction obstruction{target_, editor_, rect_};
  EnumWindows(CheckObstruction, reinterpret_cast<LPARAM>(&obstruction));
  // Windows can scroll an unobscured inactive window. Focus alone must not
  // invalidate its pixels; geometry and z-order determine capture validity.
  obscured_ = obstruction.blocked;
  if (obscured_) {
    *error = "目标区域被其他窗口遮挡，请移开遮挡窗口，或点击完成";
    return false;
  }
  return true;
}

bool ScrollCapture::Frame(std::vector<uint8_t>* pixels, std::string* error) {
  if (!CheckSource(error)) return false;
  if (!reader_) reader_ = std::make_unique<DesktopPixelReader>(rect_);
  if (!reader_->Read(pixels)) {
    reader_.reset();
    *error = "暂时无法采集画面，请重试或点击完成";
    return false;
  }
  return true;
}

bool ScrollCapture::ScrollStep(std::string* error) {
  if (!CheckSource(error)) return false;
  DWORD pid = 0;
  // Send directly to the recorded control. Another unobscuring foreground
  // window can keep its focus without becoming the wheel destination.
  if (!wheel_target_ ||
      GetWindowThreadProcessId(wheel_target_, &pid) != wheel_thread_ || pid != wheel_process_ ||
      GetAncestor(WindowFromPoint(wheel_point_), GA_ROOT) != target_ ||
      ChildAt(target_, wheel_point_) != wheel_target_ ||
      !OneScrollPane(target_, wheel_target_, rect_)) {
    *error = "滚动窗口或选区内的控件已改变，可手动滚动或点击完成";
    return false;
  }
  UINT lines = 3;
  SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
  UINT message = WM_MOUSEWHEEL;
  HWND receiver = wheel_target_;
  WPARAM amount = MAKEWPARAM(0, static_cast<WORD>(-WHEEL_DELTA));
  LPARAM point = MAKELPARAM(wheel_point_.x, wheel_point_.y);
  // With a small selection or a system page-scroll preference, a single
  // wheel notch can skip the entire selection. Standard Win32 scrollbars
  // expose a one-line operation that keeps consecutive frames overlapping.
  if (lines == WHEEL_PAGESCROLL || height() < 160) {
    const HWND owner = ScrollbarOwner(wheel_target_, target_);
    if (owner && !IsChromiumViewport(owner)) {
      receiver = owner;
      message = WM_VSCROLL;
      amount = SB_LINEDOWN;
      point = 0;
    } else if (lines == WHEEL_PAGESCROLL) {
      *error = "系统滚轮设置为整页滚动，请手动滚动或点击完成";
      return false;
    }
  }
  if (message == WM_MOUSEWHEEL &&
      (wheel_point_.x < SHRT_MIN || wheel_point_.x > SHRT_MAX ||
       wheel_point_.y < SHRT_MIN || wheel_point_.y > SHRT_MAX)) {
    *error = "选区超出滚轮消息的坐标范围，请手动滚动或点击完成";
    return false;
  }
  DWORD_PTR result = 0;
  if (!SendMessageTimeoutW(receiver, message, amount, point,
                           SMTO_ABORTIFHUNG | SMTO_BLOCK | SMTO_ERRORONEXIT, 100, &result)) {
    *error = "目标窗口未响应自动滚动，可手动滚动或点击完成";
    return false;
  }
  return true;
}

void ScrollCapture::Restore() {
  reader_.reset();
  if (hotkey_) UnregisterHotKey(editor_, kCancelHotkey);
  hotkey_ = false;
  active_ = false;
  if (IsWindow(editor_)) {
    SetWindowRgn(editor_, nullptr, TRUE);
    SetWindowDisplayAffinity(editor_, WDA_NONE);
  }
}
