#ifndef RUNNER_SCROLL_CAPTURE_H_
#define RUNNER_SCROLL_CAPTURE_H_

#include <windows.h>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

bool ReadDesktopPixels(const RECT& rect, std::vector<uint8_t>* pixels);
std::vector<RECT> DesktopMonitors();
RECT DesktopBounds(const std::vector<RECT>& monitors);
// Pieces of a selection which lie in gaps of the physical monitor layout.
std::vector<RECT> DesktopGaps(const RECT& rect, const std::vector<RECT>& monitors);
class DesktopPixelReader;

// Clips the existing editor to its border and control panel. The hole in the
// window region leaves scrolling input with the original application.
class ScrollCapture {
 public:
  static constexpr int kCancelHotkey = 0x5343;
  explicit ScrollCapture(HWND editor);
  ~ScrollCapture();
  bool Begin(const RECT& screen, const RECT& rect, const RECT& panel,
             std::string* error);
  bool Frame(std::vector<uint8_t>* pixels, std::string* error);
  bool ScrollStep(std::string* error);
  const RECT& selection() const { return rect_; }
  void Invalidate() { invalidated_ = true; }
  void Restore();
  bool active() const { return active_; }
  bool obscured() const { return obscured_; }
  int width() const { return rect_.right - rect_.left; }
  int height() const { return rect_.bottom - rect_.top; }

 private:
  bool CheckSource(std::string* error);
  bool CheckObscured(std::string* error);
  HWND editor_;
  HWND target_ = nullptr;
  HWND wheel_target_ = nullptr;
  POINT wheel_point_{};
  DWORD wheel_process_ = 0, wheel_thread_ = 0;
  DWORD source_process_ = 0, source_thread_ = 0;
  std::unique_ptr<DesktopPixelReader> reader_;
  RECT screen_{}, rect_{}, target_bounds_{};
  bool active_ = false;
  bool obscured_ = false;
  bool invalidated_ = false;
  bool hotkey_ = false;
};

#endif
