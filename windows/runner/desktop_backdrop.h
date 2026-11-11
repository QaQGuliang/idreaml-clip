#ifndef RUNNER_DESKTOP_BACKDROP_H_
#define RUNNER_DESKTOP_BACKDROP_H_

#include <windows.h>
#include <memory>

namespace Gdiplus { class Bitmap; }

// A desktop-only backdrop. Reads the configured wallpaper rather than capturing
// a screen, so foreground windows and the rail itself can never enter the blur.
// Construct/use/destroy on the COM-initialized UI thread, inside GDI+'s lifetime.
class DesktopBackdrop {
 public:
  DesktopBackdrop();
  ~DesktopBackdrop();
  DesktopBackdrop(const DesktopBackdrop&) = delete;
  DesktopBackdrop& operator=(const DesktopBackdrop&) = delete;

  // Cheap metadata refresh; true means existing rail renderings need repainting.
  bool Refresh();
  void Invalidate();

  // Returns an opaque, blurred image of exactly this desktop area, sampled at
  // roughly 1/4 physical resolution. Stretch to bounds' complete width/height
  // before clipping to cards; do not use its pixel size as the window size.
  // Invalid bounds/allocation failure return nullptr. Unavailable wallpapers
  // produce the desktop background colour (or a neutral fallback).
  std::unique_ptr<Gdiplus::Bitmap> Render(const RECT& bounds, float dpi_scale);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_DESKTOP_BACKDROP_H_
