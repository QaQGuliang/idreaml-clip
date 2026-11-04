#ifndef RUNNER_PINNED_IMAGE_H_
#define RUNNER_PINNED_IMAGE_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <set>
#include <string>
#include <vector>

// Pinned images outlive their capture session and the visibility of the main window.
class PinnedImages {
 public:
  using Copy = std::function<void(HWND, const std::vector<uint8_t>&)>;
  using SaveBorder = std::function<void(HWND, const std::string&)>;
  ~PinnedImages();
  bool SetDefaultBorder(const std::string& value);
  bool Show(const std::vector<uint8_t>& png, POINT origin, const RECT& screen,
            Copy copy, SaveBorder save_border);

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  std::set<HWND> windows_;
  int default_border_ = 0;
};

#endif
