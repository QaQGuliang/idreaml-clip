// Exercises production GDI capture against isolated, deterministic test windows.
// It never reads/writes the clipboard or the user's application database.
#include "scroll_capture.h"
#include <dwmapi.h>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
int offset = 0;
HWND wheel_receiver = nullptr;
POINT wheel_position{};
constexpr int kWidth = 660, kHeight = 480;
uint32_t Pixel(int x, int y) {
  uint32_t value = static_cast<uint32_t>(x) * 73856093U ^ static_cast<uint32_t>(y) * 19349663U;
  value ^= value >> 13;
  return value | 0xff000000U;
}
void Check(bool okay, const char* message) {
  if (!okay) throw std::runtime_error(message);
}
LRESULT CALLBACK TargetProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_MOUSEWHEEL) {
    if (GET_WHEEL_DELTA_WPARAM(wparam) == -WHEEL_DELTA) {
      offset += 90;
      wheel_receiver = hwnd;
      wheel_position = {static_cast<short>(LOWORD(lparam)), static_cast<short>(HIWORD(lparam))};
    }
    return 0;
  }
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(hwnd, &paint);
    std::vector<uint32_t> pixels(kWidth * kHeight);
    POINT origin{};
    if (GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_CHILD)
      MapWindowPoints(hwnd, GetAncestor(hwnd, GA_ROOT), &origin, 1);
    for (int y = 0; y < kHeight; y++)
      for (int x = 0; x < kWidth; x++)
        pixels[y * kWidth + x] = Pixel(x + origin.x, y + origin.y + offset);
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = kWidth;
    info.bmiHeader.biHeight = -kHeight;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    StretchDIBits(dc, 0, 0, kWidth, kHeight, 0, 0, kWidth, kHeight,
                  pixels.data(), &info, DIB_RGB_COLORS, SRCCOPY);
    EndPaint(hwnd, &paint);
    return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}
void Pump() {
  MSG message{};
  while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
    TranslateMessage(&message);
    DispatchMessage(&message);
  }
  DwmFlush();
}
void Verify(const std::vector<uint8_t>& bytes, int w, int h) {
  Check(bytes.size() == static_cast<size_t>(w) * h * 4, "Frame length mismatch");
  for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
    const uint32_t expected = Pixel(x + 20, y + 30 + offset);
    const size_t at = static_cast<size_t>(y * w + x) * 4;
    for (int channel = 0; channel < 4; channel++) {
      if (bytes[at + channel] != static_cast<uint8_t>(expected >> (channel * 8))) {
        std::cerr << "Mismatch at " << x << ',' << y << " channel " << channel
                  << " got " << static_cast<int>(bytes[at + channel]) << '\n';
        throw std::runtime_error("Capture includes controls or incorrect pixels");
      }
    }
  }
}

void VerifyGeometry() {
  const std::vector<RECT> displays{{-1920, 0, 0, 1080}, {0, -300, 2560, 1140}};
  const RECT bounds = DesktopBounds(displays);
  Check(bounds.left == -1920 && bounds.top == -300 &&
        bounds.right == 2560 && bounds.bottom == 1140, "Invalid virtual desktop origin");
  Check(DesktopGaps({-100, 800, 1800, 1000}, displays).empty(), "Adjacent displays rejected");
  const RECT missing{-100, -10, 0, 0};
  auto gaps = DesktopGaps({-100, -10, 100, 100}, displays);
  Check(gaps.size() == 1 && EqualRect(&gaps[0], &missing), "Display gap not detected");
  std::cout << "PASS offset monitor coverage and holes\n";
}

void VerifyPopupCoverage(HWND target, const wchar_t* popup_class, ScrollCapture& capture,
                         const RECT& roi) {
  // An owned, input-transparent popup is still visible when it paints. Use
  // actual GDI pixels as a separate oracle for its transparent/visible states.
  HWND popup = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
      WS_EX_LAYERED | WS_EX_TRANSPARENT, popup_class, L"Owned popup", WS_POPUP,
      roi.left - 24, roi.top - 24, 100, 100, target, nullptr, GetModuleHandle(nullptr), nullptr);
  Check(popup != nullptr, "Cannot create owned popup");
  std::string error;
  std::vector<uint8_t> pixels;
  Check(SetLayeredWindowAttributes(popup, 0, 0, LWA_ALPHA), "Cannot hide layered pixels");
  ShowWindow(popup, SW_SHOWNOACTIVATE);
  Pump();
  Check(capture.Frame(&pixels, &error), "Zero-alpha popup blocked capture");
  Verify(pixels, capture.width(), capture.height());

  HRGN shape = CreateRectRgn(0, 0, 24, 100);
  HRGN top = CreateRectRgn(0, 0, 100, 24);
  Check(CombineRgn(shape, shape, top, RGN_OR) != ERROR, "Cannot combine popup regions");
  DeleteObject(top);
  Check(SetWindowRgn(popup, shape, TRUE), "Cannot shape popup");
  Check(SetLayeredWindowAttributes(popup, 0, 255, LWA_ALPHA), "Cannot show layered pixels");
  Pump();
  Check(capture.Frame(&pixels, &error), "Window-region hole blocked capture");
  Verify(pixels, capture.width(), capture.height());
  Check(SetWindowRgn(popup, nullptr, TRUE), "Cannot show entire popup");
  RedrawWindow(popup, nullptr, nullptr, RDW_ERASE | RDW_INVALIDATE | RDW_UPDATENOW);
  Pump();
  Check(ReadDesktopPixels(roi, &pixels) && pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 255,
        "Fixture owned popup was not visible");
  Check(!capture.Frame(&pixels, &error) && capture.obscured(), "Visible owned popup accepted");
  Check(!capture.ScrollStep(&error) && capture.obscured(), "Wheel sent with visible owned popup");
  DestroyWindow(popup);
  Pump();
  Check(capture.Frame(&pixels, &error) && !capture.obscured(), "Popup dismissal failed to resume");
  Verify(pixels, capture.width(), capture.height());
  std::cout << "PASS zero-alpha and region holes; visible click-through owned popup pauses capture\n";
}

void VerifyBrowserWindow(HWND target, HWND editor, const wchar_t* target_class, const RECT& screen) {
  WNDCLASSW viewport{};
  viewport.hInstance = GetModuleHandle(nullptr);
  viewport.lpfnWndProc = TargetProc;
  viewport.lpszClassName = L"Chrome_RenderWidgetHostHWND";
  Check(RegisterClassW(&viewport) != 0, "Cannot create Chromium wheel bridge class");
  HWND page = CreateWindowExW(WS_EX_TRANSPARENT, viewport.lpszClassName, L"Viewport",
      WS_CHILD | WS_VISIBLE | WS_VSCROLL, 0, 90, kWidth, kHeight - 90, target, nullptr,
      viewport.hInstance, nullptr);
  Check(page != nullptr, "Cannot create Chromium wheel bridge");
  SetWindowPos(page, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
  // A whole-window selection includes fixed browser chrome and rounded corners.
  HRGN rounded = CreateRoundRectRgn(0, 0, kWidth + 1, kHeight + 1, 18, 18);
  Check(SetWindowRgn(target, rounded, TRUE), "Cannot round fixture corners");
  RECT roi{};
  GetWindowRect(target, &roi);
  const RECT panel{roi.left + 250, roi.top + 350, roi.left + 400, roi.bottom};
  HWND foreground = CreateWindowExW(WS_EX_TOOLWINDOW, target_class, L"Independent foreground",
      WS_POPUP, roi.right + 8, roi.top, 80, 80, nullptr, nullptr, viewport.hInstance, nullptr);
  Check(foreground != nullptr, "Cannot create independent foreground window");
  ShowWindow(foreground, SW_SHOW);
  SetForegroundWindow(foreground);
  Pump();
  Check(GetForegroundWindow() == foreground, "Fixture could not set independent foreground");
  ScrollCapture capture(editor);
  std::string error;
  if (!capture.Begin(screen, roi, panel, &error)) throw std::runtime_error(error);
  Pump();
  std::vector<uint8_t> frame;
  Check(capture.Frame(&frame, &error), "Full browser-like window did not capture");
  Check(GetForegroundWindow() == foreground, "Starting capture stole focus");
  const int initial_offset = offset;
  wheel_receiver = nullptr;
  if (!capture.ScrollStep(&error)) throw std::runtime_error(error);
  Check(wheel_receiver == page && !PtInRect(&panel, wheel_position) &&
        wheel_position.y > roi.top + kHeight * 3 / 4,
        "Wheel did not reach the page below the central media player");
  Check(offset == initial_offset + 90 && GetForegroundWindow() == foreground,
        "Independent foreground received a wheel event or lost focus");
  ShowWindow(page, SW_HIDE);
  Check(!capture.ScrollStep(&error) && offset == initial_offset + 90,
        "Wheel sent after the original child disappeared");
  ShowWindow(editor, SW_HIDE);
  capture.Restore();
  SetWindowRgn(target, nullptr, TRUE);
  DestroyWindow(foreground);
  DestroyWindow(page);
  UnregisterClassW(viewport.lpszClassName, viewport.hInstance);
  std::cout << "PASS rounded entire window, static toolbar, scrollbar and browser wheel bridge\n";
  std::cout << "PASS independent foreground retained focus; wheel delivered once to original page\n";
}

void VerifySeams(HWND target, HWND child, HWND editor) {
  const auto monitors = DesktopMonitors();
  const RECT desktop = DesktopBounds(monitors);
  bool tested_x = false, tested_y = false;
  for (const auto& a : monitors) for (const auto& b : monitors) {
    LONG x = 0, y = 0;
    const LONG first_y = (std::max)(a.top, b.top), last_y = (std::min)(a.bottom, b.bottom);
    const LONG first_x = (std::max)(a.left, b.left), last_x = (std::min)(a.right, b.right);
    const bool horizontal = a.right == b.left && last_y - first_y >= kHeight;
    const bool vertical = a.bottom == b.top && last_x - first_x >= kWidth;
    if (horizontal && !tested_x) {
      x = b.left - 200;
      y = (first_y + last_y - kHeight) / 2;
    } else if (vertical && !tested_y) {
      x = (first_x + last_x - kWidth) / 2;
      y = b.top - 125;
    } else {
      continue;
    }
    const RECT roi{x + 20, y + 30, x + 440, y + 310};
    if (!DesktopGaps(roi, monitors).empty()) continue;
    SetWindowPos(editor, nullptr, desktop.left, desktop.top,
                 desktop.right - desktop.left, desktop.bottom - desktop.top,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    SetWindowPos(target, HWND_TOPMOST, x, y, kWidth, kHeight, SWP_SHOWWINDOW);
    SetForegroundWindow(target);
    // A topology with mixed DPI can send WM_DPICHANGED during that move.
    SetWindowPos(target, nullptr, x, y, kWidth, kHeight, SWP_NOZORDER);
    RedrawWindow(target, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    Pump();
    ScrollCapture capture(editor);
    std::string error;
    const RECT panel{x + 460, y + 30, x + 595, y + 170};
    if (!capture.Begin(desktop, roi, panel, &error)) throw std::runtime_error(error);
    Pump();
    std::vector<uint8_t> pixels;
    if (!capture.Frame(&pixels, &error)) throw std::runtime_error(error);
    Verify(pixels, capture.width(), capture.height());
    wheel_receiver = nullptr;
    if (!capture.ScrollStep(&error)) throw std::runtime_error(error);
    Check(wheel_receiver == child, "Wheel was not delivered to original nested target");
    RedrawWindow(target, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    Pump();
    if (!capture.Frame(&pixels, &error)) throw std::runtime_error(error);
    Verify(pixels, capture.width(), capture.height());
    ShowWindow(editor, SW_HIDE);
    capture.Restore();
    if (horizontal) tested_x = true;
    if (vertical) tested_y = true;
  }
  std::cout << "Physical monitor seam capture and wheel: horizontal=" << tested_x
            << " vertical=" << tested_y << " (" << monitors.size() << " monitors)\n";
}
}  // namespace

int main() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  const HWND previous = GetForegroundWindow();
  const auto instance = GetModuleHandle(nullptr);
  WNDCLASS target_class{};
  target_class.hInstance = instance;
  target_class.lpfnWndProc = TargetProc;
  target_class.lpszClassName = L"IdreamlScrollTestTarget";
  RegisterClass(&target_class);
  WNDCLASS editor_class{};
  editor_class.hInstance = instance;
  editor_class.lpfnWndProc = DefWindowProc;
  editor_class.hbrBackground = CreateSolidBrush(RGB(255, 0, 0));
  editor_class.lpszClassName = L"IdreamlScrollTestControls";
  RegisterClass(&editor_class);
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  GetMonitorInfo(MonitorFromWindow(previous, MONITOR_DEFAULTTOPRIMARY), &monitor);
  const RECT screen = monitor.rcMonitor;
  const int left = screen.left + 40, top = screen.top + 40;
  HWND target = CreateWindowEx(WS_EX_TOOLWINDOW, target_class.lpszClassName, L"长截图捕获验证",
      WS_POPUP, left, top, kWidth, kHeight, nullptr, nullptr, instance, nullptr);
  HWND editor = CreateWindowEx(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, editor_class.lpszClassName,
      L"长截图控制区验证", WS_POPUP, screen.left, screen.top,
      screen.right - screen.left, screen.bottom - screen.top,
      nullptr, nullptr, instance, nullptr);
  HWND child = CreateWindowEx(0, target_class.lpszClassName, L"Scrollable test control",
      WS_CHILD | WS_VISIBLE, 10, 10, kWidth - 20, kHeight - 20, target, nullptr, instance, nullptr);
  HWND blocker = nullptr;
  int exit_code = 0;
  {
    ScrollCapture capture(editor);
    try {
      VerifyGeometry();
      Check(target && child && editor, "Cannot create fixture windows");
      // Starting from a hidden console does not grant foreground activation.
      // Keep the capture fixture above the user's windows regardless of that.
      SetWindowPos(target, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
      const DWORD foreground_thread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
      const DWORD thread = GetCurrentThreadId();
      const bool attached = foreground_thread != thread &&
          AttachThreadInput(thread, foreground_thread, TRUE);
      SetForegroundWindow(target);
      if (attached) AttachThreadInput(thread, foreground_thread, FALSE);
      RedrawWindow(target, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW);
      Pump();
      const RECT roi{left + 20, top + 30, left + 440, top + 310};
      const POINT center{(roi.left + roi.right) / 2, (roi.top + roi.bottom) / 2};
      Check(GetAncestor(WindowFromPoint(center), GA_ROOT) == target,
            "Fixture target is not the visible capture source");
      // Deliberately overlap controls with the captured region.
      const RECT panel{left + 80, top + 50, left + 230, top + 180};
      std::vector<uint8_t> baseline;
      const bool readable = ReadDesktopPixels(roi, &baseline);
      if (!readable) std::cerr << "Baseline capture error=" << GetLastError() << '\n';
      Check(readable, "Desktop capture unavailable before starting scroll controls");
      std::string error;
      const bool began = capture.Begin(screen, roi, panel, &error);
      Check(began, error.c_str());
      Pump();
      Check(GetAncestor(WindowFromPoint(POINT{roi.right - 20, roi.bottom - 20}), GA_ROOT) == target,
            "Window region still blocks scrolling input");
      std::vector<uint8_t> frame;
      const auto read = [&] {
        const bool okay = capture.Frame(&frame, &error);
        if (!okay) std::cerr << "Win32Error=" << GetLastError() << " Foreground=" << GetForegroundWindow()
            << " target=" << target << " editor=" << editor << '\n';
        Check(okay, error.c_str());
      };
      read();
      Verify(frame, capture.width(), capture.height());
      std::cout << "PASS clean capture with overlapping excluded controls and input hole\n";
      Check(capture.ScrollStep(&error), "Automatic wheel failed");
      Check(wheel_receiver == child && offset == 90, "Wrong wheel target or wheel count");
      RedrawWindow(target, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
      Pump();
      read();
      Verify(frame, capture.width(), capture.height());
      std::cout << "PASS fresh scrolled content and physical coordinates\n";
      SetWindowPos(target, nullptr, left + 10, top, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
      Pump();
      Check(!capture.Frame(&frame, &error) && !capture.obscured(), "Moved target reported obscured");
      Check(!capture.ScrollStep(&error), "Wheel sent to moved target");
      SetWindowPos(target, nullptr, left, top, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
      Pump();
      read();
      blocker = CreateWindowEx(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, editor_class.lpszClassName,
          L"测试遮挡", WS_POPUP, roi.left + 10, roi.top + 10, 40, 40,
          nullptr, nullptr, instance, nullptr);
      ShowWindow(blocker, SW_SHOWNOACTIVATE);
      Pump();
      Check(!capture.Frame(&frame, &error), "Obscured target was not rejected");
      Check(!capture.ScrollStep(&error), "Wheel sent to obscured target");
      DestroyWindow(blocker);
      blocker = nullptr;
      Pump();
      read();
      VerifyPopupCoverage(target, editor_class.lpszClassName, capture, roi);
      HWND nested_pane = CreateWindowEx(0, target_class.lpszClassName, L"Separate scroll pane",
          WS_CHILD | WS_VISIBLE | WS_VSCROLL, 45, 55, 70, 62, child, nullptr, instance, nullptr);
      Check(nested_pane != nullptr, "Failed to create nested scroll pane");
      Pump();
      Check(!capture.ScrollStep(&error) && offset == 90,
            "Wheel sent with a separate native scrolling pane inside selection");
      DestroyWindow(nested_pane);
      Pump();
      capture.Invalidate();
      Check(!capture.Frame(&frame, &error), "Invalidated screen was not rejected");
      std::cout << "PASS movement, partial occlusion, nested pane, recovery and display invalidation\n";
      ShowWindow(editor, SW_HIDE);
      capture.Restore();
      Check(RegisterHotKey(editor, ScrollCapture::kCancelHotkey, MOD_NOREPEAT, VK_ESCAPE) != FALSE,
            "Esc hotkey leaked after restore");
      UnregisterHotKey(editor, ScrollCapture::kCancelHotkey);
      std::cout << "PASS session cleanup\n";
      VerifyBrowserWindow(target, editor, target_class.lpszClassName, screen);
      VerifySeams(target, child, editor);
    } catch (const std::exception& exception) {
      std::cerr << "FAIL " << exception.what() << '\n';
      ShowWindow(editor, SW_HIDE);
      exit_code = 1;
    }
  }
  if (blocker) DestroyWindow(blocker);
  DestroyWindow(editor);
  DestroyWindow(target);
  DeleteObject(editor_class.hbrBackground);
  if (IsWindow(previous)) SetForegroundWindow(previous);
  return exit_code;
}
