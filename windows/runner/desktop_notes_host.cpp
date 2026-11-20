#include "desktop_notes_host.h"
#include "desktop_backdrop.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gdiplus.h>
#include <dwmapi.h>
#include <shellscalingapi.h>
#include <windowsx.h>
#include <optional>
#include <algorithm>
#include <cmath>
#include <cwchar>
#include <map>
#include <string>
#include <vector>

namespace {
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
using L = flutter::EncodableList;
using R = flutter::MethodResult<V>;
std::map<HWINEVENTHOOK,HWND> desktop_hooks;
const V* Field(const M& map, const char* name) {
  auto i = map.find(V(name)); return i == map.end() ? nullptr : &i->second;
}
std::string S(const M& map, const char* name, std::string fallback = "") {
  const auto* v = Field(map,name); const auto* s = v ? std::get_if<std::string>(v) : nullptr;
  return s ? *s : fallback;
}
double N(const M& map, const char* name, double fallback = 0) {
  const auto* v = Field(map,name); if (!v) return fallback;
  if (const auto* n = std::get_if<double>(v)) return *n;
  if (const auto* n = std::get_if<int32_t>(v)) return *n;
  if (const auto* n = std::get_if<int64_t>(v)) return static_cast<double>(*n);
  return fallback;
}
bool B(const M& map, const char* name) {
  const auto* v = Field(map,name); const auto* b = v ? std::get_if<bool>(v) : nullptr;
  return b && *b;
}
std::optional<UINT32> TextColor(const M& map) {
  const auto* value=Field(map,"textColor");
  if (!value || std::holds_alternative<std::monostate>(*value)) return std::nullopt;
  const double number=N(map,"textColor",-1);
  if (!std::isfinite(number) || number<0 || number>4294967295.0) return std::nullopt;
  return 0xff000000U | (static_cast<UINT32>(number)&0xffffffU);
}
std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  int count = MultiByteToWideChar(CP_UTF8,0,text.data(),static_cast<int>(text.size()),nullptr,0);
  std::wstring out(count,0);
  MultiByteToWideChar(CP_UTF8,0,text.data(),static_cast<int>(text.size()),out.data(),count); return out;
}
std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  int count = WideCharToMultiByte(CP_UTF8,0,text.data(),static_cast<int>(text.size()),nullptr,0,nullptr,nullptr);
  std::string out(count,0);
  WideCharToMultiByte(CP_UTF8,0,text.data(),static_cast<int>(text.size()),out.data(),count,nullptr,nullptr); return out;
}
// Each face is measured and painted at the destination monitor's DPI.
struct DeskFonts {
  std::unique_ptr<Gdiplus::FontFamily> family;
  std::unique_ptr<Gdiplus::Font> normal, heading, task, caption;
  float base;
  DeskFonts(const std::string& name,double size) : base(static_cast<float>(std::clamp(std::isfinite(size) ? size : 12.0,10.0,32.0))) {
    family=std::make_unique<Gdiplus::FontFamily>(name.empty() ? L"Microsoft YaHei UI" : Wide(name).c_str());
    if (family->GetLastStatus()!=Gdiplus::Ok) family=std::make_unique<Gdiplus::FontFamily>(L"Microsoft YaHei UI");
    const int regular=family->IsStyleAvailable(Gdiplus::FontStyleRegular) ? Gdiplus::FontStyleRegular : Gdiplus::FontStyleBold;
    const int bold=family->IsStyleAvailable(Gdiplus::FontStyleBold) ? Gdiplus::FontStyleBold : regular;
    normal=std::make_unique<Gdiplus::Font>(family.get(),base,regular,Gdiplus::UnitPixel);
    heading=std::make_unique<Gdiplus::Font>(family.get(),base+2,bold,Gdiplus::UnitPixel);
    task=std::make_unique<Gdiplus::Font>(family.get(),base+1,bold,Gdiplus::UnitPixel);
    caption=std::make_unique<Gdiplus::Font>(family.get(),std::max(10.0f,base-1),regular,Gdiplus::UnitPixel);
  }
};
struct Monitor {
  std::string id, label; RECT work{}; bool primary = false; float scale=1.0f;
};
std::vector<Monitor> Monitors() {
  std::vector<Monitor> values;
  EnumDisplayMonitors(nullptr,nullptr,[](HMONITOR monitor,HDC,LPRECT,LPARAM arg)->BOOL {
    auto* out = reinterpret_cast<std::vector<Monitor>*>(arg);
    MONITORINFOEXW info{}; info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor,&info)) return TRUE;
    DISPLAY_DEVICEW device{}; device.cb = sizeof(device);
    EnumDisplayDevicesW(info.szDevice,0,&device,EDD_GET_DEVICE_INTERFACE_NAME);
    std::string id = Utf8(device.DeviceID[0] ? device.DeviceID : info.szDevice);
    std::string label = Utf8(info.szDevice);
    label += " · " + std::to_string(info.rcWork.right-info.rcWork.left) + " × " + std::to_string(info.rcWork.bottom-info.rcWork.top);
    UINT dx=96,dy=96; GetDpiForMonitor(monitor,MDT_EFFECTIVE_DPI,&dx,&dy);
    out->push_back({id,label,info.rcWork,(info.dwFlags & MONITORINFOF_PRIMARY) != 0,dx/96.0f});
    return TRUE;
  },reinterpret_cast<LPARAM>(&values));
  return values;
}
Monitor SelectMonitor(const std::string& id) {
  auto values = Monitors();
  for (const auto& m : values) if (m.id == id) return m;
  for (const auto& m : values) if (m.primary) return m;
  return values.empty() ? Monitor{"","",{0,0,1280,720},true} : values.front();
}
HWND BottomApplication() {
  HWND found = HWND_NOTOPMOST;
  EnumWindows([](HWND window, LPARAM out)->BOOL {
    if (!IsWindowVisible(window) || IsIconic(window) ||
        (GetWindowLongPtrW(window,GWL_EXSTYLE)&WS_EX_TOPMOST)) return TRUE;
    DWORD cloaked=0;
    DwmGetWindowAttribute(window,DWMWA_CLOAKED,&cloaked,sizeof(cloaked));
    if (cloaked) return TRUE;
    wchar_t cls[128]{}; GetClassNameW(window,cls,128);
    if (wcscmp(cls,L"IdreamlDeskRail")==0 || wcscmp(cls,L"Progman")==0 ||
        wcscmp(cls,L"WorkerW")==0 || wcscmp(cls,L"Shell_TrayWnd")==0 ||
        wcscmp(cls,L"Shell_SecondaryTrayWnd")==0) return TRUE;
    RECT rect{}; GetWindowRect(window,&rect);
    if (IsRectEmpty(&rect)) return TRUE;
    *reinterpret_cast<HWND*>(out)=window;
    return TRUE;
  },reinterpret_cast<LPARAM>(&found));
  return found;
}
void Register(const wchar_t* name, WNDPROC proc, HBRUSH brush = nullptr) {
  WNDCLASSEXW wc{}; wc.cbSize=sizeof(wc); wc.hInstance=GetModuleHandle(nullptr);
  wc.lpfnWndProc=proc; wc.lpszClassName=name; wc.hCursor=LoadCursor(nullptr,IDC_ARROW); wc.hbrBackground=brush;
  RegisterClassExW(&wc);
}
void RoundPath(Gdiplus::GraphicsPath& path, Gdiplus::RectF r, float radius) {
  const float d=radius*2;
  path.AddArc(r.X,r.Y,d,d,180,90); path.AddArc(r.GetRight()-d,r.Y,d,d,270,90);
  path.AddArc(r.GetRight()-d,r.GetBottom()-d,d,d,0,90); path.AddArc(r.X,r.GetBottom()-d,d,d,90,90);
  path.CloseFigure();
}
}

struct DesktopNotesHost::Impl {
  struct Hit { RECT rect; std::string id; bool todo=false, conflict=false; };
  struct Rail {
    Impl* owner; std::string kind; HWND window=nullptr; M config;
    std::vector<M> rows; std::vector<Hit> hits;
    bool enabled=false, raised=false; int scroll=0, max_scroll=0;
    bool dirty=true; float scale=1.0f;
    bool backdrop_dirty=true;
    std::unique_ptr<Gdiplus::Bitmap> backdrop;
    DWORD paint_error=0,parent_error=0; int painted_pixels=0;
    RECT bounds{};
    #ifdef _DEBUG
    std::wstring export_path;
    Gdiplus::Status export_status=Gdiplus::Ok;
    #endif
  };
  std::unique_ptr<flutter::MethodChannel<V>> channel;
  std::function<bool()> blocked;
  std::shared_ptr<bool> alive=std::make_shared<bool>(true);
  HWND host=nullptr;
  HWND selector=nullptr;
  HFONT font=nullptr;
  ULONG_PTR graphics=0;
  std::unique_ptr<DesktopBackdrop> desktop_backdrop;
  HWINEVENTHOOK foreground_hook=nullptr;
  Rail note{this,"note"}, todo{this,"todo"};
  std::string select_kind;
  Monitor select_monitor;
  POINT anchor{}, cursor{};
  bool selecting=false, suspended=false, registered=false;
  bool flutter_editing=false;
  bool inspect_windows=false;
  DWORD ignored_clipboard=0;
  std::unique_ptr<R> selection_result;
  static constexpr int kHotkey=0x6D31;
  static constexpr UINT_PTR kDouble=17, kRefresh=18, kReveal=19;

  Impl(flutter::BinaryMessenger* messenger,std::function<bool()> check) : blocked(std::move(check)) {
    Gdiplus::GdiplusStartupInput input; Gdiplus::GdiplusStartup(&graphics,&input,nullptr);
    desktop_backdrop=std::make_unique<DesktopBackdrop>();
    desktop_backdrop->Refresh();
    Register(L"IdreamlDeskHost",HostProc);
    Register(L"IdreamlDeskRail",RailProc);
    Register(L"IdreamlDeskSelector",SelectProc);
    host=CreateWindowExW(WS_EX_TOOLWINDOW,L"IdreamlDeskHost",L"",WS_POPUP,0,0,0,0,nullptr,nullptr,GetModuleHandle(nullptr),this);
    font=CreateFontW(-15,0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,0,0,CLEARTYPE_QUALITY,0,L"Microsoft YaHei UI");
    channel=std::make_unique<flutter::MethodChannel<V>>(messenger,"idreaml_clip/desktop_notes",&flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const auto& call,auto result) { Handle(call,std::move(result)); });
    SetTimer(host,kRefresh,1500,nullptr);
    AddClipboardFormatListener(host);
    foreground_hook=SetWinEventHook(EVENT_SYSTEM_FOREGROUND,EVENT_SYSTEM_FOREGROUND,nullptr,
      [](HWINEVENTHOOK hook,DWORD,HWND,LONG,LONG,DWORD,DWORD) {
        const auto found=desktop_hooks.find(hook);
        if (found!=desktop_hooks.end()) PostMessage(found->second,WM_APP+6,0,0);
      },0,0,WINEVENT_OUTOFCONTEXT);
    if (foreground_hook) desktop_hooks[foreground_hook]=host;
  }
  ~Impl() {
    *alive=false; channel->SetMethodCallHandler(nullptr);
    RemoveClipboardFormatListener(host);
    if (foreground_hook) { desktop_hooks.erase(foreground_hook); UnhookWinEvent(foreground_hook); }
    Shutdown(); if (host) DestroyWindow(host);
    if (font) DeleteObject(font);
    note.backdrop.reset(); todo.backdrop.reset(); desktop_backdrop.reset();
    Gdiplus::GdiplusShutdown(graphics);
  }
  bool DeskClipboardOwner() {
    HWND owner=GetClipboardOwner();
    if (!owner) return false;
    DWORD process=0; GetWindowThreadProcessId(owner,&process);
    return flutter_editing && process==GetCurrentProcessId();
  }
  void RememberClipboard() {
    if (!DeskClipboardOwner()) return;
    ignored_clipboard=GetClipboardSequenceNumber();
    channel->InvokeMethod("suppressClipboard",std::make_unique<V>(static_cast<int64_t>(ignored_clipboard)));
  }
  void Emit(const char* method,M args) { if (*alive) channel->InvokeMethod(method,std::make_unique<V>(args)); }
  void Shutdown() {
    KillTimer(host,kDouble); KillTimer(host,kRefresh); KillTimer(host,kReveal);
    if (registered) { UnregisterHotKey(host,kHotkey); registered=false; }
    FinishSelection(false);
    for (Rail* rail : {&note,&todo}) {
      rail->enabled=false; if (IsWindow(rail->window)) DestroyWindow(rail->window);
      rail->window=nullptr;
    }
  }
  std::string UpdateHotkey() {
    bool wanted=(note.enabled || todo.enabled) && !suspended;
    if (!wanted && registered) { UnregisterHotKey(host,kHotkey); registered=false; KillTimer(host,kDouble); }
    if (wanted && !registered) {
      registered=RegisterHotKey(host,kHotkey,MOD_NOREPEAT,VK_F3)!=FALSE;
      if (!registered) return "F3 被其他快捷键占用，便签/待办仍可通过按钮添加，请释放 F3 后重试";
    }
    return {};
  }
  void Handle(const flutter::MethodCall<V>& call,std::unique_ptr<R> result) {
    const auto* args=call.arguments() ? std::get_if<M>(call.arguments()) : nullptr;
    const std::string& method=call.method_name();
    #ifdef _DEBUG
    if (method=="inspectWindows") { inspect_windows=true; result->Success(); return; }
    // Offscreen regression fixtures exercise the exact production renderer.
    // They never attach a window, register a shortcut, or capture the screen.
    if (method=="renderFixture" && args) {
      Rail fixture{this,S(*args,"kind","note")}; fixture.config=*args;
      if (const auto* rows=Field(*args,"rows")) if (const auto* list=std::get_if<L>(rows))
        for (const auto& row : *list) if (const auto* item=std::get_if<M>(&row)) fixture.rows.push_back(*item);
      const auto monitor=SelectMonitor(S(*args,"monitor"));
      fixture.scale=static_cast<float>(N(*args,"scale",monitor.scale));
      const int w=static_cast<int>(320*fixture.scale),h=static_cast<int>(500*fixture.scale);
      fixture.bounds={monitor.work.left+24,monitor.work.top+24,monitor.work.left+24+w,monitor.work.top+24+h};
      fixture.export_path=Wide(S(*args,"path"));
      desktop_backdrop->Refresh(); PaintRail(fixture);
      if (fixture.export_status==Gdiplus::Ok) result->Success();
      else result->Error("render","离屏绘制输出失败");
      return;
    }
    #endif
    if (method=="configure" && args) {
      for (Rail* rail : {&note,&todo}) {
        const auto* value=Field(*args,rail->kind.c_str());
        const auto* map=value ? std::get_if<M>(value) : nullptr;
        if (!map) continue;
        rail->config=*map; rail->enabled=B(*map,"enabled"); rail->rows.clear(); rail->dirty=true;
        if (const auto* rows=Field(*map,"rows")) if (const auto* list=std::get_if<L>(rows))
          for (const auto& row : *list) if (const auto* item=std::get_if<M>(&row)) rail->rows.push_back(*item);
        Refresh(*rail);
      }
      auto error=UpdateHotkey();
      if (error.empty()) result->Success(); else result->Success(V(error));
    } else if (method=="diagnostics") {
      L values;
      for (Rail* rail : {&note,&todo}) {
        L ancestors;
        for (HWND w=rail->window; w; w=GetParent(w)) {
          wchar_t cls[128]{}; GetClassNameW(w,cls,128); RECT rect{}; GetWindowRect(w,&rect);
          DWORD cloaked=0; DwmGetWindowAttribute(w,DWMWA_CLOAKED,&cloaked,sizeof(cloaked));
          ancestors.emplace_back(M{{V("class"),V(Utf8(cls))},{V("visible"),V(IsWindowVisible(w)!=FALSE)},
            {V("cloaked"),V(static_cast<int64_t>(cloaked))},{V("x"),V(rect.left)},{V("y"),V(rect.top)},
            {V("width"),V(rect.right-rect.left)},{V("height"),V(rect.bottom-rect.top)}});
        }
        values.emplace_back(M{{V("kind"),V(rail->kind)},{V("enabled"),V(rail->enabled)},
          {V("paintError"),V(static_cast<int64_t>(rail->paint_error))},{V("parentError"),V(static_cast<int64_t>(rail->parent_error))},
          {V("paintedPixels"),V(rail->painted_pixels)},
          {V("topmost"),V((GetWindowLongPtrW(rail->window,GWL_EXSTYLE)&WS_EX_TOPMOST)!=0)},
          {V("raised"),V(rail->raised)},{V("windows"),V(ancestors)}});
      }
      result->Success(V(M{{V("registered"),V(registered)},{V("rails"),V(values)}}));
    } else if (method=="monitors") {
      L values;
      for (const auto& monitor : Monitors()) values.emplace_back(M{{V("id"),V(monitor.id)},{V("label"),V(monitor.label)},
        {V("primary"),V(monitor.primary)},
        {V("workX"),V(static_cast<double>(monitor.work.left))},{V("workY"),V(static_cast<double>(monitor.work.top))},
        {V("workWidth"),V(static_cast<double>(monitor.work.right-monitor.work.left))},
        {V("workHeight"),V(static_cast<double>(monitor.work.bottom-monitor.work.top))}});
      result->Success(V(values));
    } else if (method=="selectRegion" && args) {
      if (selector || blocked()) { result->Error("busy","请先结束当前截图操作"); return; }
      select_kind=S(*args,"kind"); select_monitor=SelectMonitor(S(*args,"monitor"));
      selection_result=std::move(result); selecting=false;
      const auto r=select_monitor.work;
      selector=CreateWindowExW(WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_LAYERED,L"IdreamlDeskSelector",L"选取桌面展示区域",WS_POPUP,
        r.left,r.top,r.right-r.left,r.bottom-r.top,nullptr,nullptr,GetModuleHandle(nullptr),this);
      if (!selector) { selection_result->Error("window","区域选择窗口创建失败"); selection_result.reset(); return; }
      SetLayeredWindowAttributes(selector,0,190,LWA_ALPHA); ShowWindow(selector,SW_SHOW); SetForegroundWindow(selector); SetFocus(selector);
    } else if (method=="editing") {
      RememberClipboard();
      const auto* value=call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      flutter_editing=value && *value;
      suspended=flutter_editing; UpdateHotkey(); result->Success();
    } else if (method=="ignoreClipboard") {
      int64_t seq=0;
      if (call.arguments()) {
        if (const auto* n=std::get_if<int32_t>(call.arguments())) seq=*n;
        if (const auto* n=std::get_if<int64_t>(call.arguments())) seq=*n;
      }
      if (DeskClipboardOwner()) RememberClipboard();
      result->Success(V(seq!=0 && seq==ignored_clipboard && seq==GetClipboardSequenceNumber()));
    } else if (method=="suspend") {
      const auto* value=call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      suspended=value && *value; UpdateHotkey(); result->Success();
    } else if (method=="shutdown") { Shutdown(); result->Success(); }
    else result->NotImplemented();
  }
  void Refresh(Rail& rail) {
    if (!rail.enabled) { if (rail.window) ShowWindow(rail.window,SW_HIDE); return; }
    if (!IsWindow(rail.window)) {
      rail.dirty=true;
      rail.window=CreateWindowExW(WS_EX_LAYERED|(inspect_windows ? WS_EX_APPWINDOW : WS_EX_TOOLWINDOW)|WS_EX_NOACTIVATE,L"IdreamlDeskRail",rail.kind=="note" ? L"理梦剪藏桌面便签" : L"理梦剪藏桌面待办",WS_POPUP,
        0,0,320,600,nullptr,nullptr,GetModuleHandle(nullptr),&rail);
    }
    if (!rail.window) return;
    const auto desired=S(rail.config,"monitor");
    const auto monitor=SelectMonitor(desired);
    if (rail.scale!=monitor.scale) { rail.scale=monitor.scale; rail.dirty=true; rail.backdrop_dirty=true; }
    bool fallback=!desired.empty() && monitor.id!=desired;
    const auto work=monitor.work;
    int aw=work.right-work.left, ah=work.bottom-work.top;
    const bool default_size=N(rail.config,"height")==0 || fallback;
    const int width=std::clamp(static_cast<int>(default_size ? 320*rail.scale : N(rail.config,"width",320)),100,aw);
    const int margin=static_cast<int>(24*rail.scale);
    const int default_height=rail.kind=="todo" ? ah : std::max(100,ah-2*margin);
    int height=static_cast<int>(N(rail.config,"height"));
    if (!height || fallback) height=default_height;
    height=std::clamp(height,100,ah);
    int x=static_cast<int>(N(rail.config,"x",-1)),y=static_cast<int>(N(rail.config,"y",-1));
    if (x<0 || fallback) x=rail.kind=="todo" ? aw-width : margin;
    if (y<0 || fallback) y=rail.kind=="todo" ? 0 : margin;
    x=work.left+std::clamp(x,0,aw-width); y=work.top+std::clamp(y,0,ah-height);
    RECT next{x,y,x+width,y+height};
    if (!EqualRect(&rail.bounds,&next)) { rail.dirty=true; rail.backdrop_dirty=true; }
    rail.bounds=next;
    // Keep a top-level surface. Cross-process SetParent can reset the child's
    // DPI awareness and desktop composition may cover layered child windows.
    // Anchor below every visible application, not to Explorer's predecessor:
    // Show Desktop can reorder Explorer beside topmost windows, and inserting
    // after such a window would silently make the rail topmost too.
    HWND after=HWND_TOPMOST;
    UINT flags=SWP_NOACTIVATE|SWP_SHOWWINDOW;
    if (!rail.raised) {
      if (GetWindowLongPtrW(rail.window,GWL_EXSTYLE)&WS_EX_TOPMOST) {
        SetWindowPos(rail.window,HWND_NOTOPMOST,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE);
      }
      after=BottomApplication();
    }
    if (IsIconic(rail.window)) ShowWindow(rail.window,SW_SHOWNOACTIVATE);
    SetWindowPos(rail.window,after,x,y,width,height,flags);
    if (rail.dirty) { PaintRail(rail); rail.dirty=false; }
  }
  void PaintRail(Rail& rail) {
    using namespace Gdiplus;
    const int pixel_width=rail.bounds.right-rail.bounds.left,pixel_height=rail.bounds.bottom-rail.bounds.top;
    if (pixel_width<=0 || pixel_height<=0) return;
    const float width=pixel_width/rail.scale,height=pixel_height/rail.scale;
    const int original_scroll=rail.scroll;
    if (rail.backdrop_dirty || !rail.backdrop) {
      rail.backdrop=desktop_backdrop->Render(rail.bounds,rail.scale);
      rail.backdrop_dirty=false;
    }
    HDC screen=GetDC(nullptr), mem=CreateCompatibleDC(screen);
    BITMAPINFO info{}; info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth=pixel_width; info.bmiHeader.biHeight=-pixel_height; info.bmiHeader.biPlanes=1;
    info.bmiHeader.biBitCount=32; info.bmiHeader.biCompression=BI_RGB;
    void* bits=nullptr;
    HBITMAP dib=CreateDIBSection(screen,&info,DIB_RGB_COLORS,&bits,nullptr,0);
    if (!dib) { DeleteDC(mem); ReleaseDC(nullptr,screen); return; }
    auto old=SelectObject(mem,dib); memset(bits,0,static_cast<size_t>(pixel_width)*pixel_height*4);
    {
      Bitmap bitmap(pixel_width,pixel_height,pixel_width*4,PixelFormat32bppPARGB,static_cast<BYTE*>(bits));
      Graphics g(&bitmap); g.SetSmoothingMode(SmoothingModeAntiAlias); g.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
      g.ScaleTransform(rail.scale,rail.scale);
      const auto default_family=S(rail.config,"fontFamily");
      const auto default_size=N(rail.config,"fontSize",12);
      const auto default_color=TextColor(rail.config);
      auto active_color=default_color;
      DeskFonts defaults(default_family,default_size);
      const float header_line=std::ceil(std::max(defaults.heading->GetHeight(&g)+2,(defaults.base+2)*1.6f));
      const float header_meta_line=std::ceil(std::max(defaults.caption->GetHeight(&g)+2,(defaults.base-1)*1.6f));
      StringFormat format; format.SetTrimming(StringTrimmingEllipsisCharacter);
      StringFormat single; single.SetFormatFlags(StringFormatFlagsNoWrap); single.SetTrimming(StringTrimmingEllipsisCharacter);
      const UINT32 c1=static_cast<UINT32>(N(rail.config,"color",4294967295.0));
      const UINT32 c2=static_cast<UINT32>(N(rail.config,"color2",4292399352.0));
      const bool transparent=B(rail.config,"transparent");
      // The slider controls the material tint, never the final card or glyph
      // opacity. Even at full transparency a thin tint keeps text readable.
      const double tint_alpha=transparent ? std::max(.10,std::clamp(N(rail.config,"opacity",.24),0.0,1.0)) : 1.0;
      const BYTE alpha=static_cast<BYTE>(std::lround(255*tint_alpha));
      const Color background(alpha,(c1>>16)&255,(c1>>8)&255,c1&255), end(alpha,(c2>>16)&255,(c2>>8)&255,c2&255);
      const auto mode=S(rail.config,"gradient","none");
      auto wallpaperColor=[&](RectF area) {
        double red=0,green=0,blue=0; int count=0;
        if (rail.backdrop && rail.backdrop->GetWidth() && rail.backdrop->GetHeight()) {
          for (int yy=0;yy<3;yy++) for (int xx=0;xx<5;xx++) {
            const int x=std::clamp(static_cast<int>((area.X+area.Width*(xx+.5f)/5)/width*rail.backdrop->GetWidth()),0,static_cast<int>(rail.backdrop->GetWidth())-1);
            const int y=std::clamp(static_cast<int>((area.Y+area.Height*(yy+.5f)/3)/height*rail.backdrop->GetHeight()),0,static_cast<int>(rail.backdrop->GetHeight())-1);
            Color pixel;
            if (rail.backdrop->GetPixel(x,y,&pixel)==Ok) { red+=pixel.GetR(); green+=pixel.GetG(); blue+=pixel.GetB(); count++; }
          }
        }
        return count ? Color(255,static_cast<BYTE>(red/count),static_cast<BYTE>(green/count),static_cast<BYTE>(blue/count)) : Color(255,235,233,241);
      };
      auto isDark=[](Color color) {
        auto linear=[](double c) { c/=255; return c<=.04045 ? c/12.92 : std::pow((c+.055)/1.055,2.4); };
        return .2126*linear(color.GetR())+.7152*linear(color.GetG())+.0722*linear(color.GetB())<.20;
      };
      auto cardDark=[&](RectF area,RectF card_area) {
        const auto base=wallpaperColor(area);
        const double u=std::clamp(static_cast<double>((area.X+area.Width/2-card_area.X)/card_area.Width),0.0,1.0);
        const double v=std::clamp(static_cast<double>((area.Y+area.Height/2-card_area.Y)/card_area.Height),0.0,1.0);
        const double weight=mode=="none" ? 0 : mode=="horizontal" ? u : mode=="vertical" ? v :
          mode=="radial" ? std::clamp(std::hypot((u-.5)*card_area.Width,(v-.5)*card_area.Height)/(std::hypot(card_area.Width,card_area.Height)/2),0.0,1.0) : (u+v)/2;
        const auto mix=[&](BYTE a,BYTE z,BYTE under) { return static_cast<BYTE>((a*(1-weight)+z*weight)*tint_alpha+under*(1-tint_alpha)); };
        return isDark(Color(255,mix(background.GetR(),end.GetR(),base.GetR()),mix(background.GetG(),end.GetG(),base.GetG()),mix(background.GetB(),end.GetB(),base.GetB())));
      };
      Color ink(255,48,43,60);
      SolidBrush text(ink), paragraph(ink), muted(ink);
      auto setInk=[&](bool dark) {
        ink=active_color ? Color(*active_color) : dark ? Color(255,244,240,250) : Color(255,48,43,60);
        text.SetColor(ink);
        paragraph.SetColor(active_color ? ink : dark ? Color(255,231,226,240) : Color(255,68,60,81));
        muted.SetColor(active_color ? ink : dark ? Color(255,211,198,228) : Color(255,98,87,111));
      };
      const Color header_ink=default_color ? Color(*default_color) : isDark(wallpaperColor(RectF(15,15,width-30,header_line))) ? Color(255,244,240,250) : Color(255,48,43,60);
      SolidBrush header(header_ink), accent(Color(255,108,87,229));
      RectF current_card;
      auto drawText=[&](const wchar_t* value,Font* font,RectF bounds,StringFormat* layout,SolidBrush* brush) {
        if (current_card.Width>0) {
          RectF measured;
          g.MeasureString(value,-1,font,bounds,layout,&measured);
          setInk(cardDark(RectF(bounds.X,bounds.Y,std::min(bounds.Width,measured.Width),std::min(bounds.Height,measured.Height)),current_card));
        }
        // Draw exactly once on the current monitor's physical pixel grid.
        // Multi-offset outlines made small glyphs hollow and soft.
        bounds.X=std::round(bounds.X*rail.scale)/rail.scale;
        bounds.Y=std::round(bounds.Y*rail.scale)/rail.scale;
        g.DrawString(value,-1,font,bounds,layout,brush);
      };
      const float inset=15, card_width=width-2*inset;
      const float content_top=std::max(53.0f,16+std::max(header_line,header_meta_line)+13);
      auto card=[&](RectF rect) {
        GraphicsPath path; RoundPath(path,rect,18);
        if (transparent) {
          if (rail.backdrop) {
            TextureBrush glass(rail.backdrop.get(),WrapModeTileFlipXY);
            Matrix placement(width/rail.backdrop->GetWidth(),0,0,height/rail.backdrop->GetHeight(),0,0);
            glass.SetTransform(&placement); g.FillPath(&glass,&path);
          } else {
            SolidBrush fallback(Color(255,235,233,241)); g.FillPath(&fallback,&path);
          }
        }
        if (mode=="none") { SolidBrush fill(background); g.FillPath(&fill,&path); }
        else if (mode=="radial") {
          const float radius=std::sqrt(rect.Width*rect.Width+rect.Height*rect.Height)/2;
          const PointF center(rect.X+rect.Width/2,rect.Y+rect.Height/2);
          GraphicsPath radial; radial.AddEllipse(RectF(center.X-radius,center.Y-radius,radius*2,radius*2));
          PathGradientBrush fill(&radial); fill.SetCenterPoint(center); fill.SetCenterColor(background);
          Color surround[]{end}; INT color_count=1; fill.SetSurroundColors(surround,&color_count);
          g.FillPath(&fill,&path);
        } else { LinearGradientBrush fill(rect,background,end,mode=="horizontal" ? LinearGradientModeHorizontal : mode=="vertical" ? LinearGradientModeVertical : LinearGradientModeForwardDiagonal); g.FillPath(&fill,&path); }
        current_card=rect; setInk(cardDark(RectF(rect.X+18,rect.Y+18,20,24),rect));
      };
      // The header is a light label row, not another filled card.
      rail.hits.clear();
      Pen icon(header_ink,1.4f);
      icon.SetStartCap(LineCapRound); icon.SetEndCap(LineCapRound); icon.SetLineJoin(LineJoinRound);
      if (rail.kind=="note") {
        GraphicsPath outline;
        outline.AddLine(19,18,31,18); outline.AddLine(31,18,31,29);
        outline.AddLine(31,29,26,34); outline.AddLine(26,34,19,34); outline.CloseFigure();
        g.DrawPath(&icon,&outline); g.DrawLine(&icon,26,34,26,29); g.DrawLine(&icon,26,29,31,29);
      } else {
        for (int i=0;i<3;i++) {
          const float y=19.0f+i*6.0f;
          g.DrawLine(&icon,18.0f,y,20.0f,y+2); g.DrawLine(&icon,20.0f,y+2,23.0f,y-1);
          g.DrawLine(&icon,27.0f,y+1,34.0f,y+1);
        }
      }
      const float header_title_width=std::max(42.0f,std::min(width*.47f-42,header_line*2.8f));
      drawText(rail.kind=="note" ? L"便签" : L"待办",defaults.heading.get(),RectF(42,16,header_title_width,header_line),&single,&header);
      const auto count=std::to_wstring(rail.rows.size())+(rail.kind=="note" ? L" 条" : L" 项待完成");
      StringFormat right; right.SetAlignment(StringAlignmentFar); right.SetFormatFlags(StringFormatFlagsNoWrap); right.SetTrimming(StringTrimmingEllipsisCharacter);
      const float count_left=42+header_title_width+8;
      drawText(count.c_str(),defaults.caption.get(),RectF(count_left,16+(header_line-header_meta_line)/2,std::max(1.0f,width-inset-count_left),header_meta_line),&right,&header);
      rail.hits.push_back({{15,15,static_cast<LONG>(width-15),static_cast<LONG>(content_top-10)},"",false,false});

      // Wrap with GDI+'s actual font metrics, then draw at the prototype's
      // explicit line height. Limit visible lines and keep full text in manager.
      auto lines=[&](const std::wstring& source,Font& font,float available,int limit) {
        std::vector<std::wstring> values;
        StringFormat wrap; wrap.SetFormatFlags(StringFormatFlagsLineLimit);
        size_t start=0;
        while (start<source.size() && static_cast<int>(values.size())<limit) {
          const size_t newline=source.find(L'\n',start);
          const size_t stop=newline==std::wstring::npos ? source.size() : newline;
          if (stop==start) { values.push_back(L""); start++; continue; }
          INT fitted=0,line_count=0; RectF measured;
          g.MeasureString(source.c_str()+start,static_cast<INT>(stop-start),&font,
            RectF(0,0,available,font.GetHeight(&g)+2),&wrap,&measured,&fitted,&line_count);
          size_t length=std::min(stop-start,static_cast<size_t>(std::max(1,fitted)));
          if (length>1 && source[start+length-1]>=0xD800 && source[start+length-1]<=0xDBFF) length--;
          if (length==1 && start+1<stop && source[start]>=0xD800 && source[start]<=0xDBFF &&
              source[start+1]>=0xDC00 && source[start+1]<=0xDFFF) length=2;
          // Keep variation selectors, combining marks and joined emoji with
          // their preceding glyph instead of splitting them between lines.
          while (start+length<stop) {
            const auto next=source[start+length];
            if ((next>=0x0300 && next<=0x036F) || (next>=0xFE00 && next<=0xFE0F)) { length++; continue; }
            if (next==0x200D && start+length+1<stop) {
              length+=2;
              if (start+length<stop && source[start+length-1]>=0xD800 && source[start+length-1]<=0xDBFF &&
                  source[start+length]>=0xDC00 && source[start+length]<=0xDFFF) length++;
              continue;
            }
            if (next==0xD83C && start+length+1<stop && source[start+length+1]>=0xDFFB && source[start+length+1]<=0xDFFF) { length+=2; continue; }
            break;
          }
          auto line=source.substr(start,length);
          if (!line.empty() && line.back()==L'\r') line.pop_back();
          start+=length;
          if (start==stop && newline!=std::wstring::npos) start++;
          if (static_cast<int>(values.size())==limit-1 && start<source.size()) line+=L"…";
          values.push_back(std::move(line));
        }
        if (values.empty()) values.push_back(L"");
        return values;
      };
      auto date=[](double milliseconds) {
        if (milliseconds<=0) return std::wstring(L"便签");
        const ULONGLONG ticks=static_cast<ULONGLONG>(milliseconds)*10000ULL+116444736000000000ULL;
        FILETIME utc{static_cast<DWORD>(ticks),static_cast<DWORD>(ticks>>32)}, local{}, now{};
        GetSystemTimeAsFileTime(&now);
        const ULONGLONG now_ticks=(static_cast<ULONGLONG>(now.dwHighDateTime)<<32)|now.dwLowDateTime;
        if (now_ticks>=ticks && now_ticks-ticks<600000000ULL) return std::wstring(L"刚刚");
        SYSTEMTIME value{}; FileTimeToLocalFileTime(&utc,&local); FileTimeToSystemTime(&local,&value);
        const auto minute=(value.wMinute<10 ? L"0" : L"")+std::to_wstring(value.wMinute);
        return std::to_wstring(value.wMonth)+L"月"+std::to_wstring(value.wDay)+L"日 · "+std::to_wstring(value.wHour)+L":"+minute;
      };
      // 待办卡片的时间行：有开始/结束时间才绘制，逾期用错误色。
      struct Schedule { std::wstring text; bool overdue=false; };
      auto schedule=[&](const M& row) {
        Schedule result;
        const double start=N(row,"startAt",0), end=N(row,"endAt",0);
        if (!(start>0) && !(end>0)) return result;
        // 行 JSON 的数字可能是 int32/int64/double，统一按毫秒转本地时间。
        auto local=[&](double milliseconds,SYSTEMTIME& out) {
          if (!(milliseconds>0)) return false;
          const ULONGLONG ticks=static_cast<ULONGLONG>(milliseconds)*10000ULL+116444736000000000ULL;
          FILETIME utc{static_cast<DWORD>(ticks),static_cast<DWORD>(ticks>>32)}, value{};
          if (!FileTimeToLocalFileTime(&utc,&value)) return false;
          return FileTimeToSystemTime(&value,&out)!=FALSE;
        };
        auto clock=[&](const SYSTEMTIME& value) {
          return std::to_wstring(value.wHour)+L":"
            +((value.wMinute<10) ? L"0" : L"")+std::to_wstring(value.wMinute);
        };
        auto day=[&](const SYSTEMTIME& value) {
          return std::to_wstring(value.wMonth)+L"/"+std::to_wstring(value.wDay);
        };
        SYSTEMTIME first{}, last{};
        const bool has_start=local(start,first), has_end=local(end,last);
        if (has_start && has_end) {
          result.text = first.wYear==last.wYear && first.wMonth==last.wMonth && first.wDay==last.wDay
            ? day(first)+L" "+clock(first)+L"–"+clock(last)
            : day(first)+L" "+clock(first)+L" – "+day(last)+L" "+clock(last);
        } else if (has_start) result.text=day(first)+L" "+clock(first);
        else if (has_end) result.text=L"截止 "+day(last)+L" "+clock(last);
        if (result.text.empty() || B(row,"done")) return result;
        FILETIME now_file{}; GetSystemTimeAsFileTime(&now_file);
        const ULONGLONG now_ticks=(static_cast<ULONGLONG>(now_file.dwHighDateTime)<<32)|now_file.dwLowDateTime;
        const double now_ms=(static_cast<double>(now_ticks)-116444736000000000.0)/10000.0;
        const double due=end>0 ? end : start;
        result.overdue=due>0 && due<=now_ms;
        return result;
      };
      g.SetClip(RectF(0,content_top,width,std::max(0.0f,height-content_top)));
      float y=content_top-static_cast<float>(rail.scroll);
      for (const auto& row : rail.rows) {
        const bool is_todo=rail.kind=="todo", conflict=B(row,"conflict");
        const auto row_family=S(row,"fontFamily");
        DeskFonts fonts(row_family.empty() ? default_family : row_family,N(row,"fontSize",default_size));
        active_color=TextColor(row); if (!active_color) active_color=default_color;
        const float body_line=std::ceil(std::max((is_todo ? fonts.task : fonts.normal)->GetHeight(&g)+2,(fonts.base+(is_todo ? 1 : 0))*1.8f));
        const float title_line=std::ceil(std::max(fonts.heading->GetHeight(&g)+2,(fonts.base+2)*1.6f));
        const float caption_line=std::ceil(std::max(fonts.caption->GetHeight(&g)+2,std::max(10.0f,fonts.base-1)*1.6f));
        auto content=Wide(S(row,"body"));
        if (content.size()>150) content=content.substr(0,150)+L"…";
        const auto heading_text=Wide(S(row,"title"));
        const float left=inset+18+(is_todo ? 27 : 0), text_width=std::max(1.0f,width-inset-18-left);
        const auto body_lines=lines(content,*(is_todo ? fonts.task : fonts.normal),text_width,is_todo ? 8 : 10);
        const auto title_lines=heading_text.empty() ? std::vector<std::wstring>{} : lines(heading_text,*fonts.heading,text_width,2);
        const float title_height=is_todo || title_lines.empty() ? 0 : static_cast<float>(title_lines.size())*title_line+7;
        const float body_height=static_cast<float>(body_lines.size())*body_line;
        const auto time_line=is_todo ? schedule(row) : Schedule{};
        const float schedule_height=time_line.text.empty() ? 0 : caption_line+5;
        const float h=is_todo ? 18+body_height+4+caption_line+schedule_height+18 : 18+caption_line+7+title_height+body_height+18;
        if (y+h>content_top && y<height) {
          card(RectF(inset,y,card_width,h));
          const auto clipped=g.Save();
          g.SetClip(RectF(inset+1,y+1,card_width-2,h-2),CombineModeIntersect);
          float text_y=y+18;
          if (is_todo) {
            GraphicsPath checkbox; RoundPath(checkbox,RectF(inset+18,y+18+(body_line-16)/2,16,16),5);
            Pen outline(Color(255,ink.GetR(),ink.GetG(),ink.GetB()),1.5f); g.DrawPath(&outline,&checkbox);
          } else {
            const auto timestamp=date(N(row,"updated"));
            drawText(timestamp.c_str(),fonts.caption.get(),RectF(left,text_y,text_width,caption_line),&single,&muted);
            text_y+=caption_line+7;
            for (const auto& line : title_lines) {
              drawText(line.c_str(),fonts.heading.get(),RectF(left,text_y,text_width,title_line),&single,&text);
              text_y+=title_line;
            }
            if (!title_lines.empty()) text_y+=7;
          }
          for (const auto& line : body_lines) {
            drawText(line.c_str(),(is_todo ? fonts.task : fonts.normal).get(),RectF(left,text_y,text_width,body_line),&single,is_todo ? &text : &paragraph);
            text_y+=body_line;
          }
          if (is_todo) {
            const auto meta=conflict ? std::wstring(L"有同步冲突 · 点击查看") : date(N(row,"updated"));
            drawText(meta.c_str(),fonts.caption.get(),RectF(left,text_y+4,text_width,caption_line),&single,&muted);
            if (!time_line.text.empty()) {
              SolidBrush overdue(Color(255,216,68,97));
              drawText(time_line.text.c_str(),fonts.caption.get(),
                RectF(left,text_y+4+caption_line+5,text_width,caption_line),&single,
                time_line.overdue ? &overdue : &muted);
            }
          }
          if (conflict) g.FillEllipse(&accent,width-inset-14,y+12,5.0f,5.0f);
          g.Restore(clipped);
          rail.hits.push_back({{static_cast<LONG>(inset),static_cast<LONG>(std::max(content_top,y)),
            static_cast<LONG>(width-inset),static_cast<LONG>(std::min(height,y+h))},S(row,"id"),is_todo,conflict});
        }
        y+=h+12;
      }
      if (rail.rows.empty()) {
        active_color=default_color;
        const bool all_done=rail.kind=="todo" && N(rail.config,"doneCount",0)>0;
        const float normal_line=std::ceil(std::max(defaults.normal->GetHeight(&g)+2,defaults.base*1.8f));
        const float empty_height=18+header_line+12+normal_line*2+18;
        card(RectF(inset,y,card_width,empty_height));
        drawText(all_done ? L"今天的待办已完成" : rail.kind=="note" ? L"给想法一个落脚点" : L"把计划变成行动",defaults.heading.get(),
          RectF(inset+18,y+18,card_width-36,header_line),&single,&text);
        drawText(all_done ? L"双按 F3，记录新的事项" : rail.kind=="note" ? L"单按 F3，记下此刻的灵感" : L"双按 F3，添加一项待办",defaults.normal.get(),
          RectF(inset+18,y+18+header_line+12,card_width-36,normal_line*2),&format,&muted);
        rail.hits.push_back({{15,static_cast<LONG>(std::max(content_top,y)),static_cast<LONG>(width-15),static_cast<LONG>(std::min(height,y+empty_height))},"",false,false});
        y+=empty_height+12;
      }
      rail.max_scroll=std::max(0,static_cast<int>(y)+rail.scroll-static_cast<int>(height)+3);
      rail.scroll=std::min(rail.scroll,rail.max_scroll);
    }
    SIZE size{pixel_width,pixel_height}; POINT source{}; BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
    rail.painted_pixels=0;
    auto* pixels=static_cast<UINT32*>(bits);
    for (int i=0;i<pixel_width*pixel_height;i++) if (pixels[i]>>24) rail.painted_pixels++;
    SetLastError(0);
    if (rail.window) rail.paint_error=UpdateLayeredWindow(rail.window,screen,nullptr,&size,mem,&source,0,&blend,ULW_ALPHA) ? 0 : GetLastError();
    #ifdef _DEBUG
    if (!rail.export_path.empty()) {
      UINT count=0,bytes=0; GetImageEncodersSize(&count,&bytes);
      std::vector<BYTE> storage(bytes);
      auto* encoders=reinterpret_cast<ImageCodecInfo*>(storage.data());
      rail.export_status=GenericError;
      if (bytes && GetImageEncoders(count,bytes,encoders)==Ok) {
        for (UINT i=0;i<count;i++) if (wcscmp(encoders[i].MimeType,L"image/png")==0) {
          Bitmap output(pixel_width,pixel_height,pixel_width*4,PixelFormat32bppPARGB,static_cast<BYTE*>(bits));
          rail.export_status=output.Save(rail.export_path.c_str(),&encoders[i].Clsid,nullptr); break;
        }
      }
    }
    #endif
    SelectObject(mem,old); DeleteObject(dib); DeleteDC(mem); ReleaseDC(nullptr,screen);
    if (original_scroll!=rail.scroll) PaintRail(rail);
  }

  void FinishSelection(bool accept) {
    if (!selection_result) return;
    auto result=std::move(selection_result);
    HWND window=selector; selector=nullptr;
    ReleaseCapture(); if (window) DestroyWindow(window);
    if (!accept) { result->Success(); return; }
    int x=std::min(anchor.x,cursor.x),y=std::min(anchor.y,cursor.y);
    int w=std::abs(anchor.x-cursor.x),h=std::abs(anchor.y-cursor.y);
    if (w<180 || h<120) { result->Error("region","展示区域至少需要 180 × 120 像素，请重新选取"); return; }
    result->Success(V(M{{V("monitor"),V(select_monitor.id)},{V("x"),V(static_cast<double>(x))},
      {V("y"),V(static_cast<double>(y))},{V("width"),V(static_cast<double>(w))},{V("height"),V(static_cast<double>(h))}}));
  }
  bool HandleMessage(const MSG& msg) {
    if (selector && msg.message==WM_KEYDOWN && msg.wParam==VK_ESCAPE) { FinishSelection(false); return true; }
    return false;
  }
  static LRESULT CALLBACK HostProc(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    auto* self=reinterpret_cast<Impl*>(GetWindowLongPtr(window,GWLP_USERDATA));
    if (message==WM_NCCREATE) { self=static_cast<Impl*>(reinterpret_cast<CREATESTRUCT*>(lp)->lpCreateParams); SetWindowLongPtr(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self)); }
    if (self) {
      if (message==WM_APP+6) { SetTimer(window,kReveal,100,nullptr); return 0; }
      if (message==WM_SETTINGCHANGE || message==WM_DISPLAYCHANGE || message==WM_THEMECHANGED) {
        self->desktop_backdrop->Invalidate();
        for (Rail* rail : {&self->note,&self->todo}) { rail->dirty=true; rail->backdrop_dirty=true; }
        SetTimer(window,kReveal,100,nullptr); return 0;
      }
      if (message==WM_CLIPBOARDUPDATE) { self->RememberClipboard(); return 0; }
      if (message==WM_HOTKEY && wp==kHotkey) {
        if (self->suspended || self->selector || self->blocked()) { KillTimer(window,kDouble); self->waiting=false; return 0; }
        if (self->note.enabled && !self->todo.enabled) self->Emit("hotkey",{{V("kind"),V("note")}});
        else if (self->waiting) { KillTimer(window,kDouble); self->waiting=false; if (self->todo.enabled) self->Emit("hotkey",{{V("kind"),V("todo")}}); }
        else { self->waiting=true; SetTimer(window,kDouble,330,nullptr); }
        return 0;
      }
      if (message==WM_TIMER && wp==kDouble) {
        KillTimer(window,kDouble); self->waiting=false;
        if (self->note.enabled && !self->selector && !self->suspended && !self->blocked()) self->Emit("hotkey",{{V("kind"),V("note")}});
        return 0;
      }
      if (message==WM_TIMER && (wp==kRefresh || wp==kReveal)) {
        if (wp==kReveal) KillTimer(window,kReveal);
        if ((self->note.enabled || self->todo.enabled) && self->desktop_backdrop->Refresh()) {
          for (Rail* rail : {&self->note,&self->todo}) { rail->dirty=true; rail->backdrop_dirty=true; }
        }
        for (Rail* rail : {&self->note,&self->todo}) if (rail->enabled) self->Refresh(*rail);
        return 0;
      }
    }
    return DefWindowProc(window,message,wp,lp);
  }
  bool waiting=false;
  static LRESULT CALLBACK RailProc(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    auto* rail=reinterpret_cast<Rail*>(GetWindowLongPtr(window,GWLP_USERDATA));
    if (message==WM_NCCREATE) { rail=static_cast<Rail*>(reinterpret_cast<CREATESTRUCT*>(lp)->lpCreateParams); SetWindowLongPtr(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(rail)); }
    if (rail) {
      if (message==WM_DPICHANGED) {
        rail->dirty=true; rail->backdrop_dirty=true;
        SetTimer(rail->owner->host,kReveal,100,nullptr); return 0;
      }
      if (message==WM_MOUSEACTIVATE) return MA_NOACTIVATE;
      if (message==WM_NCHITTEST) {
        POINT pt{GET_X_LPARAM(lp),GET_Y_LPARAM(lp)}; ScreenToClient(window,&pt);
        pt.x=static_cast<LONG>(pt.x/rail->scale); pt.y=static_cast<LONG>(pt.y/rail->scale);
        for (const auto& hit : rail->hits) if (PtInRect(&hit.rect,pt)) return HTCLIENT;
        return HTTRANSPARENT;
      }
      if (message==WM_MOUSEWHEEL) {
        rail->scroll=std::clamp(rail->scroll-GET_WHEEL_DELTA_WPARAM(wp)/WHEEL_DELTA*70,0,rail->max_scroll);
        rail->owner->PaintRail(*rail); return 0;
      }
      if (message==WM_LBUTTONUP) {
        POINT pt{GET_X_LPARAM(lp),GET_Y_LPARAM(lp)};
        pt.x=static_cast<LONG>(pt.x/rail->scale); pt.y=static_cast<LONG>(pt.y/rail->scale);
        for (const auto& hit : rail->hits) if (PtInRect(&hit.rect,pt)) {
          const bool toggle=hit.todo && pt.x<60 && !hit.conflict;
          rail->owner->Emit(toggle ? "toggle" : "view",{{V("kind"),V(rail->kind)},{V("id"),V(hit.id)}}); break;
        }
        return 0;
      }
      if (message==WM_DESTROY) { rail->window=nullptr; return 0; }
    }
    return DefWindowProc(window,message,wp,lp);
  }
  static LRESULT CALLBACK SelectProc(HWND window,UINT message,WPARAM wp,LPARAM lp) {
    auto* self=reinterpret_cast<Impl*>(GetWindowLongPtr(window,GWLP_USERDATA));
    if (message==WM_NCCREATE) { self=static_cast<Impl*>(reinterpret_cast<CREATESTRUCT*>(lp)->lpCreateParams); SetWindowLongPtr(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self)); }
    if (self) {
      if (message==WM_LBUTTONDOWN) { self->anchor={GET_X_LPARAM(lp),GET_Y_LPARAM(lp)}; self->cursor=self->anchor; self->selecting=true; SetCapture(window); return 0; }
      if (message==WM_MOUSEMOVE && self->selecting) {
        RECT r{}; GetClientRect(window,&r);
        self->cursor={std::clamp(GET_X_LPARAM(lp),0,static_cast<int>(r.right)),std::clamp(GET_Y_LPARAM(lp),0,static_cast<int>(r.bottom))};
        InvalidateRect(window,nullptr,FALSE); return 0;
      }
      if (message==WM_LBUTTONUP && self->selecting) { self->FinishSelection(true); return 0; }
      if (message==WM_PAINT) {
        PAINTSTRUCT ps; HDC dc=BeginPaint(window,&ps); RECT r{}; GetClientRect(window,&r);
        HBRUSH bg=CreateSolidBrush(RGB(36,33,52)); FillRect(dc,&r,bg); DeleteObject(bg);
        SetBkMode(dc,TRANSPARENT); SetTextColor(dc,RGB(255,255,255)); SelectObject(dc,self->font);
        const wchar_t* help=L"拖动选取展示区域 · Esc 取消 · 选区至少 180 × 120";
        TextOutW(dc,24,24,help,static_cast<int>(wcslen(help)));
        if (self->selecting) {
          HPEN pen=CreatePen(PS_SOLID,3,RGB(160,140,255)); auto old=SelectObject(dc,pen);
          auto brush=SelectObject(dc,GetStockObject(HOLLOW_BRUSH));
          Rectangle(dc,std::min(self->anchor.x,self->cursor.x),std::min(self->anchor.y,self->cursor.y),std::max(self->anchor.x,self->cursor.x),std::max(self->anchor.y,self->cursor.y));
          SelectObject(dc,old); SelectObject(dc,brush); DeleteObject(pen);
        }
        EndPaint(window,&ps); return 0;
      }
      if (message==WM_CLOSE) { self->FinishSelection(false); return 0; }
    }
    return DefWindowProc(window,message,wp,lp);
  }
};

DesktopNotesHost::DesktopNotesHost(flutter::BinaryMessenger* messenger,std::function<bool()> blocked)
  : impl_(std::make_unique<Impl>(messenger,std::move(blocked))) {}
DesktopNotesHost::~DesktopNotesHost() = default;
bool DesktopNotesHost::HandleMessage(const MSG& message) { return impl_->HandleMessage(message); }
