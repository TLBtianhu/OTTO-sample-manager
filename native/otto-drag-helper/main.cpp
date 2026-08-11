#include <windows.h>

#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>

#include <cstring>
#include <string>

namespace {

FORMATETC HdropFormat() {
  FORMATETC format{};
  format.cfFormat = CF_HDROP;
  format.dwAspect = DVASPECT_CONTENT;
  format.lindex = -1;
  format.tymed = TYMED_HGLOBAL;
  return format;
}

HRESULT ValidateHdropRequest(const FORMATETC& request) {
  if (request.cfFormat != CF_HDROP) return DV_E_FORMATETC;
  if (request.dwAspect != DVASPECT_CONTENT) return DV_E_DVASPECT;
  if (request.lindex != -1) return DV_E_LINDEX;
  if ((request.tymed & TYMED_HGLOBAL) == 0) return DV_E_TYMED;
  return S_OK;
}

HGLOBAL CreateHdrop(const std::wstring& path) {
  const SIZE_T path_bytes = (path.size() + 2) * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT,
                               sizeof(DROPFILES) + path_bytes);
  if (!memory) return nullptr;

  auto* drop = static_cast<DROPFILES*>(GlobalLock(memory));
  if (!drop) {
    GlobalFree(memory);
    return nullptr;
  }

  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = TRUE;
  auto* destination = reinterpret_cast<wchar_t*>(
      reinterpret_cast<BYTE*>(drop) + sizeof(DROPFILES));
  std::memcpy(destination, path.c_str(), (path.size() + 1) * sizeof(wchar_t));
  GlobalUnlock(memory);
  return memory;
}

class FileDataObject final : public IDataObject {
 public:
  explicit FileDataObject(std::wstring path) : path_(std::move(path)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDataObject) {
      *object = static_cast<IDataObject*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&refs_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const LONG refs = InterlockedDecrement(&refs_);
    if (refs == 0) delete this;
    return static_cast<ULONG>(refs);
  }

  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* request,
                                    STGMEDIUM* medium) override {
    if (!request || !medium) return E_POINTER;
    const HRESULT validation = ValidateHdropRequest(*request);
    if (FAILED(validation)) return validation;

    HGLOBAL memory = CreateHdrop(path_);
    if (!memory) return STG_E_MEDIUMFULL;
    medium->tymed = TYMED_HGLOBAL;
    medium->hGlobal = memory;
    medium->pUnkForRelease = nullptr;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override {
    return DATA_E_FORMATETC;
  }

  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* request) override {
    return request ? ValidateHdropRequest(*request) : E_POINTER;
  }

  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*,
                                                   FORMATETC* output) override {
    if (!output) return E_POINTER;
    output->ptd = nullptr;
    return E_NOTIMPL;
  }

  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override {
    return E_NOTIMPL;
  }

  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction,
                                          IEnumFORMATETC** result) override {
    if (!result) return E_POINTER;
    *result = nullptr;
    if (direction != DATADIR_GET) return E_NOTIMPL;
    const FORMATETC format = HdropFormat();
    return SHCreateStdEnumFmtEtc(1, &format, result);
  }

  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*,
                                    DWORD*) override {
    return OLE_E_ADVISENOTSUPPORTED;
  }

  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override {
    return OLE_E_ADVISENOTSUPPORTED;
  }

  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA** result) override {
    if (result) *result = nullptr;
    return OLE_E_ADVISENOTSUPPORTED;
  }

 private:
  ~FileDataObject() = default;

  LONG refs_ = 1;
  std::wstring path_;
};

class CopyDropSource final : public IDropSource {
 public:
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDropSource) {
      *object = static_cast<IDropSource*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&refs_));
  }

  ULONG STDMETHODCALLTYPE Release() override {
    const LONG refs = InterlockedDecrement(&refs_);
    if (refs == 0) delete this;
    return static_cast<ULONG>(refs);
  }

  HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape_pressed,
                                              DWORD key_state) override {
    if (escape_pressed) return DRAGDROP_S_CANCEL;
    return (key_state & MK_LBUTTON) == 0 ? DRAGDROP_S_DROP : S_OK;
  }

  HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override {
    return DRAGDROP_S_USEDEFAULTCURSORS;
  }

 private:
  ~CopyDropSource() = default;
  LONG refs_ = 1;
};

LRESULT CALLBACK SourceWindowProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  return DefWindowProcW(window, message, wparam, lparam);
}

DWORD g_attached_thread = 0;

HWND CreateSourceWindow(HINSTANCE instance) {
  constexpr wchar_t kClassName[] = L"OttoDragHelperSourceWindow";
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = SourceWindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kClassName;
  if (!RegisterClassW(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return nullptr;
  }

  POINT cursor{};
  GetCursorPos(&cursor);
  HWND window = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_LAYERED, kClassName,
                                L"", WS_POPUP, cursor.x - 8, cursor.y - 8, 16,
                                16,
                                nullptr, nullptr, instance, nullptr);
  if (!window) return nullptr;

  const DWORD current_thread = GetCurrentThreadId();
  const DWORD foreground_thread =
      GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
  if (foreground_thread != 0 && foreground_thread != current_thread) {
    if (!AttachThreadInput(current_thread, foreground_thread, TRUE)) {
      DestroyWindow(window);
      return nullptr;
    }
    g_attached_thread = foreground_thread;
  }

  SetLayeredWindowAttributes(window, 0, 1, LWA_ALPHA);
  ShowWindow(window, SW_SHOW);
  SetWindowPos(window, HWND_TOPMOST, cursor.x - 8, cursor.y - 8, 16, 16,
               SWP_SHOWWINDOW);
  SetForegroundWindow(window);
  SetActiveWindow(window);
  SetFocus(window);
  SetCapture(window);
  if (GetCapture() != window) {
    if (g_attached_thread != 0) {
      AttachThreadInput(current_thread, g_attached_thread, FALSE);
      g_attached_thread = 0;
    }
    DestroyWindow(window);
    return nullptr;
  }
  return window;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  int argument_count = 0;
  LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &argument_count);
  if (!arguments || argument_count != 2 || arguments[1][0] == L'\0') {
    if (arguments) LocalFree(arguments);
    return 2;
  }

  const std::wstring path = arguments[1];
  LocalFree(arguments);

  const HRESULT ole_result = OleInitialize(nullptr);
  if (FAILED(ole_result)) return 1;

  HWND source_window = CreateSourceWindow(instance);
  if (!source_window) {
    OleUninitialize();
    return 1;
  }

  auto* data_object = new FileDataObject(path);
  auto* drop_source = new CopyDropSource();
  DWORD effect = DROPEFFECT_NONE;
  const HRESULT drag_result =
      DoDragDrop(data_object, drop_source, DROPEFFECT_COPY, &effect);
  drop_source->Release();
  data_object->Release();
  if (GetCapture() == source_window) ReleaseCapture();
  if (g_attached_thread != 0) {
    AttachThreadInput(GetCurrentThreadId(), g_attached_thread, FALSE);
    g_attached_thread = 0;
  }
  DestroyWindow(source_window);
  OleUninitialize();

  if (drag_result == DRAGDROP_S_CANCEL) return 3;
  return drag_result == DRAGDROP_S_DROP && (effect & DROPEFFECT_COPY) != 0 ? 0
                                                                         : 1;
}
