#include "pinned_image.h"

#include <windowsx.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>

namespace {
using Microsoft::WRL::ComPtr;
constexpr wchar_t kClass[] = L"IdreamlPinnedScreenshot";

struct Image {
  PinnedImages* host;
  PinnedImages::Copy copy;
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

void Zoom(HWND window, Image& image, POINT point, int delta) {
  RECT old{};
  if (!GetWindowRect(window, &old)) return;
  image.scale = std::clamp(image.scale * std::pow(1.15, static_cast<double>(delta) / WHEEL_DELTA),
                           0.05, 8.0);
  const int width = Scaled(image.width, image.scale);
  const int height = Scaled(image.height, image.scale);
  // Leave the image pixel under the pointer in the same place on screen.
  const int x = point.x - MulDiv(point.x - old.left, width, old.right - old.left);
  const int y = point.y - MulDiv(point.y - old.top, height, old.bottom - old.top);
  SetWindowPos(window, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
}
}  // namespace

PinnedImages::~PinnedImages() {
  while (!windows_.empty()) DestroyWindow(*windows_.begin());
}

bool PinnedImages::Show(const std::vector<uint8_t>& png, POINT origin,
                        const RECT& screen, Copy copy) {
  if (png.empty() || png.size() > 32 * 1024 * 1024) return false;
  auto image = std::make_unique<Image>();
  image->png = png;
  if (!Decode(*image)) return false;
  image->host = this;
  image->copy = std::move(copy);
  image->scale = std::min({1.0, static_cast<double>(screen.right - screen.left) / image->width,
                           static_cast<double>(screen.bottom - screen.top) / image->height});
  const int width = Scaled(image->width, image->scale);
  const int height = Scaled(image->height, image->scale);

  WNDCLASSW cls{};
  cls.lpfnWndProc = WindowProc;
  cls.hInstance = GetModuleHandle(nullptr);
  cls.hCursor = LoadCursor(nullptr, IDC_SIZEALL);
  cls.lpszClassName = kClass;
  if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
  HWND window = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kClass, L"理梦剪藏 · 贴图",
      WS_POPUP, std::min(origin.x, screen.right - width), std::min(origin.y, screen.bottom - height),
      width, height, nullptr, nullptr, cls.hInstance, nullptr);
  if (!window) return false;
  windows_.insert(window);
  SetWindowLongPtr(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(image.release()));
  ShowWindow(window, SW_SHOWNOACTIVATE);
  return true;
}

LRESULT CALLBACK PinnedImages::WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* image = reinterpret_cast<Image*>(GetWindowLongPtr(window, GWLP_USERDATA));
  if (!image) return DefWindowProc(window, message, wparam, lparam);
  switch (message) {
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT bounds{};
      GetClientRect(window, &bounds);
      SetStretchBltMode(dc, HALFTONE);
      SetBrushOrgEx(dc, 0, 0, nullptr);
      StretchDIBits(dc, 0, 0, bounds.right, bounds.bottom, 0, 0, image->width, image->height,
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
      Zoom(window, *image, {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)}, GET_WHEEL_DELTA_WPARAM(wparam));
      return 0;
    case WM_CONTEXTMENU: {
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (point.x == -1 && point.y == -1) GetCursorPos(&point);
      HMENU menu = CreatePopupMenu();
      if (!menu) return 0;
      AppendMenuW(menu, MF_STRING, 1, L"复制图片\tCtrl+C");
      AppendMenuW(menu, MF_STRING, 2, L"关闭贴图\tEsc");
      SetForegroundWindow(window);
      const UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                          point.x, point.y, 0, window, nullptr);
      DestroyMenu(menu);
      if (command == 1 && IsWindow(window)) image->copy(window, image->png);
      if (command == 2) PostMessage(window, WM_CLOSE, 0, 0);
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
