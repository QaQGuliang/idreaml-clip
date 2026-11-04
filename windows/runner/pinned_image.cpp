#include "pinned_image.h"

#include <windowsx.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <iterator>
#include <memory>
#include <utility>

namespace {
using Microsoft::WRL::ComPtr;
constexpr wchar_t kClass[] = L"IdreamlPinnedScreenshot";
struct BorderStyle {
  const char* value;
  const wchar_t* label;
  COLORREF color;
};
constexpr BorderStyle kBorders[] = {
    {"none", L"无边框", 0}, {"light", L"浅色", RGB(245, 245, 245)},
    {"dark", L"深色", RGB(48, 48, 48)}, {"amber", L"琥珀色", RGB(252, 214, 139)},
};
constexpr int kBorderCount = static_cast<int>(std::size(kBorders));
constexpr int kFollow = -1;
constexpr UINT kCopy = 1, kClose = 2, kLocal = 100, kDefault = 200;
constexpr UINT kUseDefault = kLocal - 1;

int Inset(int border) { return border == 0 ? 0 : 2; }

struct Image {
  PinnedImages* host;
  PinnedImages::Copy copy;
  PinnedImages::SaveBorder save_border;
  int border = kFollow;
  std::vector<uint8_t> png;
  std::vector<uint8_t> pixels;
  BITMAPINFO bitmap{};
  int width = 0;
  int height = 0;
  double scale = 1;
};

bool Decode(Image& image) {
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICFormatConverter> converter;
  UINT width = 0, height = 0;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&factory))) ||
      FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(image.png.data(), static_cast<DWORD>(image.png.size()))) ||
      FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) || FAILED(frame->GetSize(&width, &height)) ||
      !width || !height || static_cast<uint64_t>(width) * height > 40000000 ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom))) {
    return false;
  }
  image.pixels.resize(static_cast<size_t>(width) * height * 4);
  if (FAILED(converter->CopyPixels(nullptr, width * 4, static_cast<UINT>(image.pixels.size()),
                                   image.pixels.data()))) return false;
  image.width = static_cast<int>(width);
  image.height = static_cast<int>(height);
  auto& header = image.bitmap.bmiHeader;
  header.biSize = sizeof(BITMAPINFOHEADER);
  header.biWidth = image.width;
  header.biHeight = -image.height;
  header.biPlanes = 1;
  header.biBitCount = 32;
  header.biCompression = BI_RGB;
  return true;
}

int Scaled(int pixels, double scale) {
  return std::max(1, static_cast<int>(std::lround(pixels * scale)));
}

// Anchor the image (not the decorative frame) at the selected screen pixel.
RECT FramedBounds(const Image& image, POINT origin, int inset, const RECT* screen) {
  double scale = image.scale;
  if (screen) {
    scale = std::min({scale, std::max(1L, screen->right - screen->left - 2 * inset) /
                                 static_cast<double>(image.width),
                      std::max(1L, screen->bottom - screen->top - 2 * inset) /
                                 static_cast<double>(image.height)});
  }
  const int width = Scaled(image.width, scale) + 2 * inset;
  const int height = Scaled(image.height, scale) + 2 * inset;
  LONG x = origin.x - inset, y = origin.y - inset;
  if (screen) {
    x = std::clamp(x, screen->left, std::max(screen->left, screen->right - width));
    y = std::clamp(y, screen->top, std::max(screen->top, screen->bottom - height));
  }
  return {x, y, x + width, y + height};
}

void RefreshBorder(HWND window, const Image& image, int before, int after) {
  RECT old{};
  if (Inset(before) != Inset(after) && GetWindowRect(window, &old)) {
    // Preserve a user's offscreen placement. If previously fully visible, keep
    // the entire frame visible too, including for a full-screen capture.
    MONITORINFO monitor{sizeof(MONITORINFO)};
    RECT overlap{};
    const bool fits = GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor) &&
                      IntersectRect(&overlap, &old, &monitor.rcMonitor) && EqualRect(&overlap, &old);
    auto bounds = FramedBounds(image, {old.left + Inset(before), old.top + Inset(before)},
                               Inset(after), fits ? &monitor.rcMonitor : nullptr);
    SetWindowPos(window, nullptr, bounds.left, bounds.top, bounds.right - bounds.left,
                 bounds.bottom - bounds.top, SWP_NOZORDER | SWP_NOACTIVATE);
  }
  InvalidateRect(window, nullptr, FALSE);
}

void Zoom(HWND window, Image& image, POINT point, int delta, int inset) {
  RECT old{};
  if (!GetWindowRect(window, &old)) return;
  image.scale = std::clamp(image.scale * std::pow(1.15, static_cast<double>(delta) / WHEEL_DELTA),
                           0.05, 8.0);
  const int width = Scaled(image.width, image.scale);
  const int height = Scaled(image.height, image.scale);
  // Leave the image pixel under the pointer in the same place on screen.
  const int x = point.x - inset -
      MulDiv(point.x - old.left - inset, width, std::max(1L, old.right - old.left - 2 * inset));
  const int y = point.y - inset -
      MulDiv(point.y - old.top - inset, height, std::max(1L, old.bottom - old.top - 2 * inset));
  SetWindowPos(window, nullptr, x, y, width + 2 * inset, height + 2 * inset,
               SWP_NOZORDER | SWP_NOACTIVATE);
}

void AppendBorders(HMENU parent, const wchar_t* title, UINT first, int selected, bool local) {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  if (local) AppendMenuW(menu, MF_STRING, kUseDefault, L"跟随全局设置");
  for (int i = 0; i < kBorderCount; ++i) {
    AppendMenuW(menu, MF_STRING, first + i, kBorders[i].label);
  }
  CheckMenuRadioItem(menu, local ? kUseDefault : first, first + kBorderCount - 1,
                     selected == kFollow ? kUseDefault : first + selected, MF_BYCOMMAND);
  if (!AppendMenuW(parent, MF_POPUP, reinterpret_cast<UINT_PTR>(menu), title)) DestroyMenu(menu);
}
}  // namespace

PinnedImages::~PinnedImages() {
  while (!windows_.empty()) DestroyWindow(*windows_.begin());
}

bool PinnedImages::Show(const std::vector<uint8_t>& png, POINT origin,
                        const RECT& screen, Copy copy, SaveBorder save_border) {
  if (png.empty() || png.size() > 32 * 1024 * 1024) return false;
  auto image = std::make_unique<Image>();
  image->png = png;
  if (!Decode(*image)) return false;
  image->host = this;
  image->copy = std::move(copy);
  image->save_border = std::move(save_border);
  image->scale = std::min({1.0, static_cast<double>(screen.right - screen.left) / image->width,
                           static_cast<double>(screen.bottom - screen.top) / image->height});
  const auto bounds = FramedBounds(*image, origin, Inset(default_border_), &screen);

  WNDCLASSW cls{};
  cls.lpfnWndProc = WindowProc;
  cls.hInstance = GetModuleHandle(nullptr);
  cls.hCursor = LoadCursor(nullptr, IDC_SIZEALL);
  cls.lpszClassName = kClass;
  if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
  HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kClass, L"理梦剪藏 · 贴图",
      WS_POPUP, bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top,
      nullptr, nullptr, cls.hInstance, nullptr);
  if (!window) return false;
  windows_.insert(window);
  SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(image.release()));
  ShowWindow(window, SW_SHOWNOACTIVATE);
  return true;
}

bool PinnedImages::SetDefaultBorder(const std::string& value) {
  const auto it = std::find_if(std::begin(kBorders), std::end(kBorders),
                               [&](const BorderStyle& style) { return value == style.value; });
  if (it == std::end(kBorders)) return false;
  const int next = static_cast<int>(it - std::begin(kBorders));
  if (next == default_border_) return true;
  const int previous = std::exchange(default_border_, next);
  for (HWND window : windows_) {
    const auto* image = reinterpret_cast<Image*>(GetWindowLongPtr(window, GWLP_USERDATA));
    if (image && image->border == kFollow) RefreshBorder(window, *image, previous, next);
  }
  return true;
}

LRESULT CALLBACK PinnedImages::WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* image = reinterpret_cast<Image*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (!image) return DefWindowProc(window, message, wparam, lparam);
  const int border = image->border == kFollow ? image->host->default_border_ : image->border;
  switch (message) {
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT bounds{};
      GetClientRect(window, &bounds);
      if (const int inset = Inset(border)) {
        SetDCBrushColor(dc, kBorders[border].color);
        FillRect(dc, &bounds, static_cast<HBRUSH>(GetStockObject(DC_BRUSH)));
        InflateRect(&bounds, -inset, -inset);
      }
      SetStretchBltMode(dc, HALFTONE);
      SetBrushOrgEx(dc, 0, 0, nullptr);
      StretchDIBits(dc, bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top,
                    0, 0, image->width, image->height,
                    image->pixels.data(), &image->bitmap, DIB_RGB_COLORS, SRCCOPY);
      EndPaint(window, &paint);
      return 0;
    }
    case WM_SIZE:
      InvalidateRect(window, nullptr, FALSE);
      return 0;
    case WM_LBUTTONDOWN: {
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      ClientToScreen(window, &point);
      SendMessage(window, WM_NCLBUTTONDOWN, HTCAPTION, MAKELPARAM(point.x, point.y));
      return 0;
    }
    case WM_MOUSEWHEEL:
      Zoom(window, *image, {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)},
           GET_WHEEL_DELTA_WPARAM(wparam), Inset(border));
      return 0;
    case WM_CONTEXTMENU: {
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (point.x == -1 && point.y == -1) GetCursorPos(&point);
      HMENU menu = CreatePopupMenu();
      if (!menu) return 0;
      AppendMenuW(menu, MF_STRING, kCopy, L"复制图片\tCtrl+C");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendBorders(menu, L"当前贴图边框", kLocal, image->border, true);
      AppendBorders(menu, L"全局默认边框", kDefault, image->host->default_border_, false);
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, kClose, L"关闭贴图\tEsc");
      SetForegroundWindow(window);
      const UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                          point.x, point.y, 0, window, nullptr);
      DestroyMenu(menu);
      if (command && IsWindow(window)) SendMessage(window, WM_COMMAND, command, 0);
      return 0;
    }
    case WM_COMMAND: {
      const UINT command = LOWORD(wparam);
      if (command == kCopy) image->copy(window, image->png);
      else if (command == kClose) PostMessage(window, WM_CLOSE, 0, 0);
      else if (command >= kUseDefault && command < kLocal + kBorderCount) {
        image->border = static_cast<int>(command) - static_cast<int>(kLocal);
        const int next = image->border == kFollow ? image->host->default_border_ : image->border;
        if (border != next) RefreshBorder(window, *image, border, next);
      } else if (command >= kDefault && command < kDefault + kBorderCount) {
        image->save_border(window, kBorders[command - kDefault].value);
      }
      return 0;
    }
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) { DestroyWindow(window); return 0; }
      if (wparam == 'C' && (GetKeyState(VK_CONTROL) & 0x8000)) {
        if (!(lparam & (1L << 30))) image->copy(window, image->png);
        return 0;
      }
      break;
    case WM_NCDESTROY:
      image->host->windows_.erase(window);
      SetWindowLongPtr(window, GWLP_USERDATA, 0);
      delete image;
      break;
  }
  return DefWindowProc(window, message, wparam, lparam);
}
