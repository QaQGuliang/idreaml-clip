// Console-only tests: reads wallpaper metadata, never changes wallpaper or
// captures a screen. Including the implementation keeps pure math helpers out
// of the product's public API while exercising the identical production code.
#include "../../windows/runner/desktop_backdrop.cpp"

#include <iostream>
#include <stdexcept>
#include <cwchar>
#include <cstddef>

namespace {
void Require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

void Near(float value, float expected, const char* message) {
  Require(std::abs(value - expected) < .01f, message);
}

void CheckRect(const Gdiplus::RectF& actual, float x, float y, float width,
               float height, const char* message) {
  Near(actual.X, x, message); Near(actual.Y, y, message);
  Near(actual.Width, width, message); Near(actual.Height, height, message);
}

void TestBlur() {
  constexpr int width = 33, height = 17;
  std::vector<uint32_t> input(width * height, 0xff123456U), output(input.size());
  BoxPass(input, output, width, height, 4, true);
  Require(output == input, "Horizontal blur changed a constant colour");
  BoxPass(input, output, width, height, 4, false);
  Require(output == input, "Vertical blur changed a constant colour");

  // Clamped edges: [0, 90, 180] becomes [30, 90, 150], not black padding.
  const std::vector<uint32_t> ramp{0xff000000U, 0xff5a5a5aU, 0xffb4b4b4U};
  std::vector<uint32_t> edge(3);
  BoxPass(ramp, edge, 3, 1, 1, true);
  Require(edge == std::vector<uint32_t>({0xff1e1e1eU, 0xff5a5a5aU, 0xff969696U}),
          "Horizontal edge extension is incorrect");
  BoxPass(ramp, edge, 1, 3, 1, false);
  Require(edge == std::vector<uint32_t>({0xff1e1e1eU, 0xff5a5a5aU, 0xff969696U}),
          "Vertical edge extension is incorrect");

  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      input[static_cast<size_t>(y) * width + x] = (x + y) % 2 ? 0xffffffffU : 0xff000000U;
    }
  }
  for (int pass = 0; pass < 3; ++pass) {
    BoxPass(input, output, width, height, 3, true);
    BoxPass(output, input, width, height, 3, false);
  }
  int darkest = 255, lightest = 0;
  for (int y = 5; y < height - 5; ++y) {
    for (int x = 5; x < width - 5; ++x) {
      const auto pixel = input[static_cast<size_t>(y) * width + x];
      Require((pixel >> 24) == 255, "Blur made an opaque background transparent");
      darkest = std::min(darkest, static_cast<int>(pixel & 255));
      lightest = std::max(lightest, static_cast<int>(pixel & 255));
    }
  }
  Require(darkest > 110 && lightest < 140 && lightest - darkest < 5,
          "High-frequency wallpaper texture was not blurred");
}

void TestPlacement() {
  const RECT negative_monitor{-1920, -200, 0, 880};
  CheckRect(Placement(negative_monitor, 1000, 1000, DWPOS_CENTER),
      -1460, -160, 1000, 1000, "Centered wallpaper placement");
  CheckRect(Placement(negative_monitor, 1000, 1000, DWPOS_FIT),
      -1500, -200, 1080, 1080, "Fit wallpaper placement");
  CheckRect(Placement(negative_monitor, 1000, 1000, DWPOS_FILL),
      -1920, -620, 1920, 1920, "Fill wallpaper placement");
  CheckRect(Placement(negative_monitor, 1000, 1000, DWPOS_STRETCH),
      -1920, -200, 1920, 1080, "Stretched wallpaper placement");
  const RECT virtual_desktop{-1920, -200, 1920, 1080};
  CheckRect(Placement(virtual_desktop, 3840, 2160, DWPOS_SPAN),
      -1920, -640, 3840, 2160, "Spanned wallpaper placement");
}

uint64_t OpaqueHash(Bitmap& bitmap) {
  Require(bitmap.GetLastStatus() == Gdiplus::Ok && bitmap.GetWidth() && bitmap.GetHeight(),
          "Wallpaper render returned an invalid bitmap");
  const Gdiplus::Rect rect(0, 0, static_cast<INT>(bitmap.GetWidth()),
                          static_cast<INT>(bitmap.GetHeight()));
  Gdiplus::BitmapData data{};
  Require(bitmap.LockBits(&rect, Gdiplus::ImageLockModeRead, PixelFormat32bppPARGB,
                          &data) == Gdiplus::Ok, "Could not inspect rendered bitmap");
  bool opaque = true;
  uint64_t hash = 1469598103934665603ULL;
  for (UINT y = 0; y < bitmap.GetHeight(); ++y) {
    const auto* row = reinterpret_cast<const uint32_t*>(static_cast<const BYTE*>(data.Scan0) +
        static_cast<ptrdiff_t>(y) * data.Stride);
    for (UINT x = 0; x < bitmap.GetWidth(); ++x) {
      opaque = opaque && ((row[x] >> 24) == 255);
      hash = (hash ^ row[x]) * 1099511628211ULL;
    }
  }
  bitmap.UnlockBits(&data);
  Require(opaque, "Glass background disappeared or became partially transparent");
  return hash;
}

bool SavePreview(Bitmap& bitmap, const std::wstring& path, int width, int height) {
  UINT count = 0, bytes = 0;
  if (Gdiplus::GetImageEncodersSize(&count, &bytes) != Gdiplus::Ok || !bytes) return false;
  std::vector<BYTE> buffer(bytes);
  auto* encoders = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  if (Gdiplus::GetImageEncoders(count, bytes, encoders) != Gdiplus::Ok) return false;
  for (UINT i = 0; i < count; ++i) {
    if (std::wcscmp(encoders[i].MimeType, L"image/png") != 0) continue;
    Bitmap preview(width, height, PixelFormat32bppPARGB);
    {
      Gdiplus::Graphics graphics(&preview);
      graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
      graphics.DrawImage(&bitmap, 0, 0, width, height);
    }
    return preview.Save(path.c_str(), &encoders[i].Clsid, nullptr) == Gdiplus::Ok;
  }
  return false;
}

void TestDesktop(const std::wstring& preview_path) {
  const auto metadata = ReadWallpaper();
  std::cout << "Wallpaper monitors: " << metadata.monitors.size() << '\n';
  RECT bounds{0, 0, 480, 320};
  if (!metadata.monitors.empty()) {
    const auto& area = metadata.monitors.front().bounds;
    bounds = {area.left + 24, area.top + 24,
              area.left + 504, area.top + 344};
  }
  DesktopBackdrop backdrop;
  Require(backdrop.Refresh(), "Initial wallpaper refresh must invalidate rails");
  auto first = backdrop.Render(bounds, 1.25f);
  Require(first != nullptr, "Wallpaper render failed");
  Require(first->GetWidth() == 120 && first->GetHeight() == 80,
          "Backdrop samples no longer map to the complete physical desktop bounds");
  const auto hash = OpaqueHash(*first);
  auto cached = backdrop.Render(bounds, 1.25f);
  Require(cached && OpaqueHash(*cached) == hash, "Repeated render/cache changed wallpaper pixels");
  if (!backdrop.Refresh()) {
    auto refreshed = backdrop.Render(bounds, 1.25f);
    Require(refreshed && OpaqueHash(*refreshed) == hash,
            "Unchanged metadata unnecessarily changed backdrop output");
  } else {
    // A real slideshow may advance during this read-only test.
    std::cout << "Wallpaper changed during test; refreshed output accepted.\n";
  }
  const RECT invalid{10, 10, 10, 20};
  Require(backdrop.Render(invalid, 1) == nullptr, "Empty bounds must not allocate a backdrop");
  const RECT far_too_large{0, 0, 32769, 100};
  Require(backdrop.Render(far_too_large, 1) == nullptr, "Unbounded render allocation is permitted");
  const RECT negative{-900, -400, -580, 240};
  auto offscreen = backdrop.Render(negative, 2);
  Require(offscreen != nullptr, "Negative desktop coordinates failed");
  OpaqueHash(*offscreen);
  backdrop.Invalidate();
  Require(backdrop.Refresh(), "Explicit wallpaper invalidation was ignored");
  auto fresh = backdrop.Render(bounds, 1.25f);
  Require(fresh != nullptr, "Wallpaper refresh after invalidation failed");
  OpaqueHash(*fresh);
  if (!preview_path.empty()) {
    Require(SavePreview(*fresh, preview_path, bounds.right - bounds.left,
                        bounds.bottom - bounds.top), "Failed to save requested wallpaper-only preview");
  }
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  std::wstring preview;
  if (argc == 3 && std::wcscmp(argv[1], L"--output") == 0) preview = argv[2];
  else if (argc != 1) {
    std::cerr << "Usage: desktop_backdrop_test [--output wallpaper-blur.png]\n";
    return 2;
  }
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com)) { std::cerr << "COM initialization failed\n"; return 2; }
  Gdiplus::GdiplusStartupInput input;
  ULONG_PTR token = 0;
  if (Gdiplus::GdiplusStartup(&token, &input, nullptr) != Gdiplus::Ok) {
    CoUninitialize(); return 2;
  }
  int result = 0;
  try {
    TestBlur(); TestPlacement(); TestDesktop(preview);
    std::cout << "PASS: blur, edge extension, placement, wallpaper cache, opaque output\n";
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    result = 1;
  }
  Gdiplus::GdiplusShutdown(token);
  CoUninitialize();
  return result;
}
