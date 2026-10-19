#ifndef RUNNER_SCROLL_CAPTURE_H_
#define RUNNER_SCROLL_CAPTURE_H_

#include <windows.h>
#include <cstdint>
#include <string>
#include <vector>

bool ReadDesktopPixels(const RECT& rect, std::vector<uint8_t>* pixels);

// Clips the existing editor to its border and control panel. The hole in the
// window region leaves scrolling input with the original application.
class ScrollCapture {
 public:
  static constexpr int kCancelHotkey = 0x5343;
  explicit ScrollCapture(HWND editor) : editor_(editor) {}
  ~ScrollCapture() { Restore(); }
  bool Begin(const RECT& screen, const RECT& rect, const RECT& panel,
             std::string* error);
  bool Frame(std::vector<uint8_t>* pixels, std::string* error);
  void Invalidate() { invalidated_ = true; }
  void Restore();
  bool active() const { return active_; }
  int width() const { return rect_.right - rect_.left; }
  int height() const { return rect_.bottom - rect_.top; }

 private:
  HWND editor_;
  HWND target_ = nullptr;
  RECT screen_{}, rect_{}, target_bounds_{};
  bool active_ = false;
  bool invalidated_ = false;
  bool hotkey_ = false;
};

#endif
