// Exercises production GDI capture against isolated, deterministic test windows.
// It never reads/writes the clipboard or the user's application database.
#include "scroll_capture.h"
#include <dwmapi.h>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
int offset = 0;
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
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(hwnd, &paint);
    std::vector<uint32_t> pixels(kWidth * kHeight);
    for (int y = 0; y < kHeight; y++)
      for (int x = 0; x < kWidth; x++) pixels[y * kWidth + x] = Pixel(x, y + offset);
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
  HWND blocker = nullptr;
  int exit_code = 0;
  {
    ScrollCapture capture(editor);
    try {
      Check(target && editor, "Cannot create fixture windows");
      ShowWindow(target, SW_SHOW);
      // The console helper was started hidden; activate only our fixture window.
      ShowWindow(target, SW_SHOW);
      const DWORD foreground_thread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
      const DWORD thread = GetCurrentThreadId();
      const bool attached = foreground_thread != thread &&
          AttachThreadInput(thread, foreground_thread, TRUE);
      SetForegroundWindow(target);
      if (attached) AttachThreadInput(thread, foreground_thread, FALSE);
      RedrawWindow(target, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW);
      Pump();
      const RECT roi{left + 20, top + 30, left + 440, top + 310};
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
      offset = 90;
      RedrawWindow(target, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW);
      Pump();
      read();
      Verify(frame, capture.width(), capture.height());
      std::cout << "PASS fresh scrolled content and physical coordinates\n";
      SetWindowPos(target, nullptr, left + 10, top, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
      Pump();
      Check(!capture.Frame(&frame, &error), "Moved target was not rejected");
      SetWindowPos(target, nullptr, left, top, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
      Pump();
      read();
      blocker = CreateWindowEx(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, editor_class.lpszClassName,
          L"测试遮挡", WS_POPUP, roi.left + 10, roi.top + 10, 40, 40,
          nullptr, nullptr, instance, nullptr);
      ShowWindow(blocker, SW_SHOWNOACTIVATE);
      Pump();
      Check(!capture.Frame(&frame, &error), "Obscured target was not rejected");
      DestroyWindow(blocker);
      blocker = nullptr;
      Pump();
      read();
      capture.Invalidate();
      Check(!capture.Frame(&frame, &error), "Invalidated screen was not rejected");
      std::cout << "PASS movement, occlusion, recovery and display invalidation\n";
      ShowWindow(editor, SW_HIDE);
      capture.Restore();
      Check(RegisterHotKey(editor, ScrollCapture::kCancelHotkey, MOD_NOREPEAT, VK_ESCAPE) != FALSE,
            "Esc hotkey leaked after restore");
      UnregisterHotKey(editor, ScrollCapture::kCancelHotkey);
      std::cout << "PASS session cleanup\n";
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
