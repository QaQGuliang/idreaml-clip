#include "desktop_backdrop.h"

#include <gdiplus.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <map>
#include <new>
#include <string>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
using Gdiplus::Bitmap;

struct MonitorWallpaper {
  std::wstring id, path;
  RECT bounds{};
  uint64_t modified = 0, bytes = 0;
  bool operator==(const MonitorWallpaper& other) const {
    return id == other.id && path == other.path &&
        EqualRect(&bounds, &other.bounds) && modified == other.modified &&
        bytes == other.bytes;
  }
};

struct WallpaperState {
  DESKTOP_WALLPAPER_POSITION position = DWPOS_FILL;
  COLORREF background = RGB(238, 236, 245);
  std::vector<MonitorWallpaper> monitors;
  bool operator==(const WallpaperState& other) const {
    return position == other.position && background == other.background &&
        monitors == other.monitors;
  }
};

WallpaperState ReadWallpaper() {
  WallpaperState result;
  ComPtr<IDesktopWallpaper> desktop;
  if (FAILED(CoCreateInstance(__uuidof(DesktopWallpaper), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(desktop.GetAddressOf())))) {
    return result;
  }
  desktop->GetPosition(&result.position);
  desktop->GetBackgroundColor(&result.background);
  UINT count = 0;
  if (FAILED(desktop->GetMonitorDevicePathCount(&count))) return result;
  for (UINT index = 0; index < std::min(count, 32U); ++index) {
    LPWSTR id = nullptr;
    if (FAILED(desktop->GetMonitorDevicePathAt(index, &id)) || !id) {
      CoTaskMemFree(id);
      continue;
    }
    MonitorWallpaper monitor;
    monitor.id = id;
    const HRESULT located = desktop->GetMonitorRECT(id, &monitor.bounds);
    LPWSTR path = nullptr;
    if (SUCCEEDED(desktop->GetWallpaper(id, &path)) && path) monitor.path = path;
    CoTaskMemFree(path);
    CoTaskMemFree(id);
    if (FAILED(located) || IsRectEmpty(&monitor.bounds)) continue;
    WIN32_FILE_ATTRIBUTE_DATA attributes{};
    if (!monitor.path.empty() && GetFileAttributesExW(monitor.path.c_str(),
        GetFileExInfoStandard, &attributes)) {
      monitor.modified = (static_cast<uint64_t>(attributes.ftLastWriteTime.dwHighDateTime) << 32) |
          attributes.ftLastWriteTime.dwLowDateTime;
      monitor.bytes = (static_cast<uint64_t>(attributes.nFileSizeHigh) << 32) |
          attributes.nFileSizeLow;
    }
    result.monitors.push_back(std::move(monitor));
  }
  std::sort(result.monitors.begin(), result.monitors.end(),
      [](const auto& a, const auto& b) { return a.id < b.id; });
  return result;
}

std::unique_ptr<Bitmap> Clone(Bitmap& source) {
  const Gdiplus::Rect all(0, 0, static_cast<INT>(source.GetWidth()),
                         static_cast<INT>(source.GetHeight()));
  auto result = std::unique_ptr<Bitmap>(source.Clone(all, PixelFormat32bppPARGB));
  return result && result->GetLastStatus() == Gdiplus::Ok ? std::move(result) : nullptr;
}

// The input is opaque. Three separable box passes approximate a Gaussian while
// keeping work proportional to pixel count, not the kernel's square area.
void BoxPass(const std::vector<uint32_t>& input, std::vector<uint32_t>& output,
             int width, int height, int radius, bool horizontal) {
  const int lines = horizontal ? height : width;
  const int length = horizontal ? width : height;
  const int divisor = radius * 2 + 1;
  auto index = [&](int line, int point) {
    return horizontal ? static_cast<size_t>(line) * width + point
                      : static_cast<size_t>(point) * width + line;
  };
  for (int line = 0; line < lines; ++line) {
    int red = 0, green = 0, blue = 0;
    auto add = [&](int point, int sign) {
      const auto pixel = input[index(line, std::clamp(point, 0, length - 1))];
      blue += sign * static_cast<int>(pixel & 255);
      green += sign * static_cast<int>((pixel >> 8) & 255);
      red += sign * static_cast<int>((pixel >> 16) & 255);
    };
    for (int point = -radius; point <= radius; ++point) add(point, 1);
    for (int point = 0; point < length; ++point) {
      output[index(line, point)] = 0xff000000U |
          (static_cast<uint32_t>(red / divisor) << 16) |
          (static_cast<uint32_t>(green / divisor) << 8) |
          static_cast<uint32_t>(blue / divisor);
      add(point - radius, -1);
      add(point + radius + 1, 1);
    }
  }
}

struct WallpaperImage {
  uint64_t modified = 0, bytes = 0;
  ULONGLONG retry_after = 0;
  UINT original_width = 0, original_height = 0;
  std::unique_ptr<Bitmap> bitmap;
};

WallpaperImage LoadImage(const MonitorWallpaper& monitor) {
  WallpaperImage result;
  result.modified = monitor.modified;
  result.bytes = monitor.bytes;
  if (monitor.path.empty() || monitor.bytes == 0 || monitor.bytes > 128ULL * 1024 * 1024) return result;
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(factory.GetAddressOf())))) return result;
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromFilename(monitor.path.c_str(), nullptr,
      GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder))) return result;
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame)) || FAILED(frame->GetSize(
      &result.original_width, &result.original_height))) return result;
  const auto width = result.original_width, height = result.original_height;
  if (!width || !height || static_cast<uint64_t>(width) * height > 100000000ULL) return result;
  const double scale = std::min({1.0, 4096.0 / width, 4096.0 / height,
      std::sqrt(4194304.0 / (static_cast<double>(width) * height))});
  const UINT scaled_width = std::max(1U, static_cast<UINT>(std::round(width * scale)));
  const UINT scaled_height = std::max(1U, static_cast<UINT>(std::round(height * scale)));
  ComPtr<IWICBitmapSource> source;
  if (scaled_width != width || scaled_height != height) {
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(factory->CreateBitmapScaler(&scaler)) || FAILED(scaler->Initialize(
        frame.Get(), scaled_width, scaled_height, WICBitmapInterpolationModeFant))) return result;
    source = scaler;
  } else {
    source = frame;
  }
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) || FAILED(converter->Initialize(
      source.Get(), GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone,
      nullptr, 0, WICBitmapPaletteTypeCustom))) return result;
  auto bitmap = std::make_unique<Bitmap>(scaled_width, scaled_height, PixelFormat32bppPARGB);
  Gdiplus::BitmapData data{};
  Gdiplus::Rect region(0, 0, static_cast<INT>(scaled_width), static_cast<INT>(scaled_height));
  if (bitmap->GetLastStatus() != Gdiplus::Ok || bitmap->LockBits(&region,
      Gdiplus::ImageLockModeWrite, PixelFormat32bppPARGB, &data) != Gdiplus::Ok) return result;
  const HRESULT copied = data.Stride > 0 ? converter->CopyPixels(nullptr,
      static_cast<UINT>(data.Stride), static_cast<UINT>(data.Stride) * scaled_height,
      static_cast<BYTE*>(data.Scan0)) : E_FAIL;
  bitmap->UnlockBits(&data);
  if (SUCCEEDED(copied)) result.bitmap = std::move(bitmap);
  return result;
}

Gdiplus::RectF Placement(const RECT& monitor, UINT source_width,
                       UINT source_height, DESKTOP_WALLPAPER_POSITION position) {
  const float area_width = static_cast<float>(monitor.right - monitor.left);
  const float area_height = static_cast<float>(monitor.bottom - monitor.top);
  float width = static_cast<float>(source_width), height = static_cast<float>(source_height);
  if (position == DWPOS_STRETCH) { width = area_width; height = area_height; }
  else if (position != DWPOS_CENTER) {
    const float sx = area_width / width, sy = area_height / height;
    const float scale = position == DWPOS_FIT ? std::min(sx, sy) : std::max(sx, sy);
    width *= scale; height *= scale;
  }
  return Gdiplus::RectF(static_cast<float>(monitor.left) + (area_width - width) / 2,
                         static_cast<float>(monitor.top) + (area_height - height) / 2, width, height);
}
}  // namespace

struct DesktopBackdrop::Impl {
  WallpaperState state;
  bool invalid = true;
  std::map<std::wstring, WallpaperImage> images;
  struct Rendered {
    RECT bounds{};
    float scale = 1;
    std::unique_ptr<Bitmap> bitmap;
  };
  std::vector<Rendered> rendered;

  bool Refresh() {
    auto next = ReadWallpaper();
    const auto now = GetTickCount64();
    const bool retry = std::any_of(images.begin(), images.end(), [&](const auto& item) {
      return !item.second.bitmap && item.second.retry_after && now >= item.second.retry_after;
    });
    if (!invalid && next == state && !retry) return false;
    state = std::move(next);
    invalid = false;
    rendered.clear();
    for (auto item = images.begin(); item != images.end();) {
      const bool retained = std::any_of(state.monitors.begin(), state.monitors.end(),
          [&](const auto& monitor) { return monitor.path == item->first &&
              monitor.modified == item->second.modified && monitor.bytes == item->second.bytes; });
      const bool retry_image = !item->second.bitmap && item->second.retry_after && now >= item->second.retry_after;
      if (!retained || retry_image) item = images.erase(item); else ++item;
    }
    return true;
  }

  Bitmap* Image(const MonitorWallpaper& monitor, UINT* width, UINT* height) {
    auto found = images.find(monitor.path);
    if (found == images.end()) {
      auto loaded = LoadImage(monitor);
      // A wallpaper slideshow may briefly lock a file while replacing it.
      // Retry failures without polling large or unsupported images every frame.
      if (!loaded.bitmap && !monitor.path.empty()) loaded.retry_after = GetTickCount64() + 30000;
      found = images.emplace(monitor.path, std::move(loaded)).first;
    }
    *width = found->second.original_width;
    *height = found->second.original_height;
    return found->second.bitmap.get();
  }

  std::unique_ptr<Bitmap> Render(const RECT& bounds, float dpi_scale) {
    if (invalid) Refresh();
    const int64_t wide = static_cast<int64_t>(bounds.right) - bounds.left;
    const int64_t high = static_cast<int64_t>(bounds.bottom) - bounds.top;
    if (wide <= 0 || high <= 0 || wide > 32768 || high > 32768) return nullptr;
    dpi_scale = std::isfinite(dpi_scale) ? std::clamp(dpi_scale, .5f, 8.0f) : 1.0f;
    for (const auto& cached : rendered) {
      if (EqualRect(&cached.bounds, &bounds) && cached.scale == dpi_scale) return Clone(*cached.bitmap);
    }
    // Downsampling is restricted to the wallpaper, never to text or controls.
    const double step = std::max(4.0, static_cast<double>(std::max(wide, high)) / 2048.0);
    const int width = static_cast<int>(std::ceil(static_cast<double>(wide) / step));
    const int height = static_cast<int>(std::ceil(static_cast<double>(high) / step));
    const int radius = std::clamp(static_cast<int>(std::round(12 * dpi_scale / step)), 1, 32);
    const int padding = 3 * radius + 2;
    const int padded_width = width + 2 * padding, padded_height = height + 2 * padding;
    auto canvas = std::make_unique<Bitmap>(padded_width, padded_height, PixelFormat32bppPARGB);
    if (canvas->GetLastStatus() != Gdiplus::Ok) return nullptr;
    const float sx = static_cast<float>(width) / static_cast<float>(wide);
    const float sy = static_cast<float>(height) / static_cast<float>(high);
    const float left = static_cast<float>(bounds.left) - padding / sx;
    const float top = static_cast<float>(bounds.top) - padding / sy;
    const Gdiplus::RectF expanded(left, top, padded_width / sx, padded_height / sy);
    {
      Gdiplus::Graphics graphics(canvas.get());
      graphics.Clear(Gdiplus::Color(255, GetRValue(state.background),
          GetGValue(state.background), GetBValue(state.background)));
      graphics.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
      graphics.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
      Gdiplus::Matrix transform(sx, 0, 0, sy, -left * sx, -top * sy);
      graphics.SetTransform(&transform);
      RECT desktop{};
      for (const auto& monitor : state.monitors) UnionRect(&desktop, &desktop, &monitor.bounds);
      for (const auto& monitor : state.monitors) {
        const Gdiplus::RectF monitor_area(static_cast<float>(monitor.bounds.left),
            static_cast<float>(monitor.bounds.top),
            static_cast<float>(monitor.bounds.right - monitor.bounds.left),
            static_cast<float>(monitor.bounds.bottom - monitor.bounds.top));
        if (!expanded.IntersectsWith(monitor_area)) continue;
        UINT source_width = 0, source_height = 0;
        auto* image = Image(monitor, &source_width, &source_height);
        if (!image) continue;
        const auto saved = graphics.Save();
        graphics.SetClip(Gdiplus::Rect(monitor.bounds.left, monitor.bounds.top,
            monitor.bounds.right - monitor.bounds.left, monitor.bounds.bottom - monitor.bounds.top));
        auto draw = [&](const Gdiplus::RectF& destination) {
          graphics.DrawImage(image, destination, 0, 0,
              static_cast<float>(image->GetWidth()), static_cast<float>(image->GetHeight()), Gdiplus::UnitPixel);
        };
        if (state.position == DWPOS_TILE) {
          // One pixel-aligned tile grid for the whole virtual desktop.
          const float tile_width = static_cast<float>(source_width);
          const float tile_height = static_cast<float>(source_height);
          // Tiny tiles are better represented by a repeating texture, avoiding
          // an unbounded draw loop for a deliberately one-pixel wallpaper.
          Gdiplus::TextureBrush tiles(image, Gdiplus::WrapModeTile);
          tiles.ScaleTransform(tile_width / static_cast<float>(image->GetWidth()),
                               tile_height / static_cast<float>(image->GetHeight()));
          graphics.FillRectangle(&tiles, expanded);
        } else {
          draw(Placement(state.position == DWPOS_SPAN ? desktop : monitor.bounds,
                         source_width, source_height, state.position));
        }
        graphics.Restore(saved);
      }
    }
    Gdiplus::BitmapData pixels{};
    Gdiplus::Rect all(0, 0, padded_width, padded_height);
    if (canvas->LockBits(&all, Gdiplus::ImageLockModeRead, PixelFormat32bppPARGB,
                         &pixels) != Gdiplus::Ok) return nullptr;
    std::vector<uint32_t> input(static_cast<size_t>(padded_width) * padded_height);
    for (int y = 0; y < padded_height; ++y) {
      const auto* row = reinterpret_cast<const uint32_t*>(static_cast<const BYTE*>(pixels.Scan0) + y * pixels.Stride);
      std::copy_n(row, padded_width, input.data() + static_cast<size_t>(y) * padded_width);
    }
    canvas->UnlockBits(&pixels);
    std::vector<uint32_t> scratch(input.size());
    for (int pass = 0; pass < 3; ++pass) {
      BoxPass(input, scratch, padded_width, padded_height, radius, true);
      BoxPass(scratch, input, padded_width, padded_height, radius, false);
    }
    auto output = std::make_unique<Bitmap>(width, height, PixelFormat32bppPARGB);
    Gdiplus::Rect crop(0, 0, width, height);
    if (output->GetLastStatus() != Gdiplus::Ok || output->LockBits(&crop,
        Gdiplus::ImageLockModeWrite, PixelFormat32bppPARGB, &pixels) != Gdiplus::Ok) return nullptr;
    for (int y = 0; y < height; ++y) {
      auto* row = reinterpret_cast<uint32_t*>(static_cast<BYTE*>(pixels.Scan0) + y * pixels.Stride);
      std::copy_n(input.data() + static_cast<size_t>(y + padding) * padded_width + padding, width, row);
    }
    output->UnlockBits(&pixels);
    if (rendered.size() >= 2) rendered.erase(rendered.begin());
    auto copy = Clone(*output);
    rendered.push_back({bounds, dpi_scale, std::move(output)});
    return copy;
  }
};

DesktopBackdrop::DesktopBackdrop() : impl_(std::make_unique<Impl>()) {}
DesktopBackdrop::~DesktopBackdrop() = default;
bool DesktopBackdrop::Refresh() { return impl_->Refresh(); }
void DesktopBackdrop::Invalidate() { impl_->invalid = true; impl_->images.clear(); impl_->rendered.clear(); }
std::unique_ptr<Bitmap> DesktopBackdrop::Render(const RECT& bounds, float dpi_scale) {
  try { return impl_->Render(bounds, dpi_scale); }
  catch (const std::bad_alloc&) { return nullptr; }
}
