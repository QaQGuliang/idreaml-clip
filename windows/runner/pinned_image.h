#ifndef RUNNER_PINNED_IMAGE_H_
#define RUNNER_PINNED_IMAGE_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <set>
#include <vector>

// Pinned images outlive their capture session and the visibility of the main window.
class PinnedImages {
 public:
  using Copy = std::function<void(HWND, const std::vector<uint8_t>&)>;
  ~PinnedImages();
  bool Show(const std::vector<uint8_t>& png, POINT origin, const RECT& screen,
            Copy copy);

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  std::set<HWND> windows_;
};

#endif
