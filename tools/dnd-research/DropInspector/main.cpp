#include "../common/dnd_common.h"

#include <shellapi.h>
#include <shlobj.h>

#include <memory>
#include <string>

namespace {

using dnd::Logger;

Logger* g_log = nullptr;
std::wstring g_mode = L"both";

DWORD AcceptedEffect(DWORD allowed) {
  if (allowed & DROPEFFECT_COPY) return DROPEFFECT_COPY;
  if (allowed & DROPEFFECT_MOVE) return DROPEFFECT_MOVE;
  if (allowed & DROPEFFECT_LINK) return DROPEFFECT_LINK;
  return DROPEFFECT_NONE;
}

class DropTarget final : public IDropTarget {
 public:
  explicit DropTarget(Logger& log) : log_(log) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (iid == IID_IUnknown || iid == IID_IDropTarget) {
      *object = static_cast<IDropTarget*>(this);
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

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data_object, DWORD key_state,
                                      POINTL point, DWORD* effect) override {
    ReplaceDataObject(data_object);
    drag_over_logged_ = false;
    log_.Writef(L"DragEnter keyState=0x%08lX point=(%ld,%ld) incomingEffect=%ls",
                key_state, point.x, point.y,
                effect ? dnd::DropEffectText(*effect).c_str() : L"<null>");
    dnd::LogDataObjectSnapshot(log_, data_object, L"DragEnter");
    if (effect) *effect = AcceptedEffect(*effect);
    log_.Writef(L"DragEnter returnedEffect=%ls",
                effect ? dnd::DropEffectText(*effect).c_str() : L"<null>");
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state, POINTL point,
                                     DWORD* effect) override {
    if (!drag_over_logged_) {
      log_.Writef(L"DragOver keyState=0x%08lX point=(%ld,%ld) incomingEffect=%ls",
                  key_state, point.x, point.y,
                  effect ? dnd::DropEffectText(*effect).c_str() : L"<null>");
      dnd::LogDataObjectSnapshot(log_, data_object_, L"first DragOver");
      drag_over_logged_ = true;
    }
    if (effect) *effect = AcceptedEffect(*effect);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DragLeave() override {
    log_.Write(L"DragLeave");
    ReplaceDataObject(nullptr);
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data_object, DWORD key_state,
                                 POINTL point, DWORD* effect) override {
    log_.Writef(L"Drop keyState=0x%08lX point=(%ld,%ld) incomingEffect=%ls",
                key_state, point.x, point.y,
                effect ? dnd::DropEffectText(*effect).c_str() : L"<null>");
    dnd::LogDataObjectSnapshot(log_, data_object, L"Drop");
    if (effect) *effect = AcceptedEffect(*effect);
    log_.Writef(L"Drop returnedEffect=%ls",
                effect ? dnd::DropEffectText(*effect).c_str() : L"<null>");
    ReplaceDataObject(nullptr);
    return S_OK;
  }

 private:
  ~DropTarget() { ReplaceDataObject(nullptr); }

  void ReplaceDataObject(IDataObject* next) {
    if (next) next->AddRef();
    if (data_object_) data_object_->Release();
    data_object_ = next;
  }

  LONG refs_ = 1;
  Logger& log_;
  IDataObject* data_object_ = nullptr;
  bool drag_over_logged_ = false;
};

void LogLegacyDrop(HDROP drop) {
  if (!g_log) return;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  g_log->Writef(L"WM_DROPFILES received fileCount=%u", count);
  for (UINT index = 0; index < count; ++index) {
    const UINT length = DragQueryFileW(drop, index, nullptr, 0);
    std::wstring path(length + 1, L'\0');
    DragQueryFileW(drop, index, path.data(), length + 1);
    path.resize(length);
    g_log->Writef(L"  [%u] \"%ls\"", index, path.c_str());
  }
  DragFinish(drop);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  switch (message) {
    case WM_DROPFILES:
      LogLegacyDrop(reinterpret_cast<HDROP>(wparam));
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT client{};
      GetClientRect(window, &client);
      SetBkMode(dc, TRANSPARENT);
      const std::wstring text =
          L"DropInspector\n\nDrop a file anywhere in this window.\n"
          L"Mode: " +
          g_mode + L"\n\nLog: " + (g_log ? g_log->path() : L"<unavailable>");
      DrawTextW(dc, text.c_str(), -1, &client,
                DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX);
      EndPaint(window, &paint);
      return 0;
    }
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

HRESULT CreateShellDataObject(HWND owner, const std::wstring& path,
                              IDataObject** result) {
  if (!result) return E_POINTER;
  *result = nullptr;
  PIDLIST_ABSOLUTE absolute = nullptr;
  HRESULT hr = SHParseDisplayName(path.c_str(), nullptr, &absolute, 0, nullptr);
  if (FAILED(hr)) return hr;

  IShellFolder* parent = nullptr;
  PCUITEMID_CHILD child = nullptr;
  hr = SHBindToParent(absolute, IID_PPV_ARGS(&parent), &child);
  if (SUCCEEDED(hr)) {
    hr = parent->GetUIObjectOf(owner, 1, &child, IID_IDataObject, nullptr,
                               reinterpret_cast<void**>(result));
    parent->Release();
  }
  CoTaskMemFree(absolute);
  return hr;
}

std::wstring ArgumentValue(int argc, wchar_t** argv, const wchar_t* name) {
  for (int i = 1; i + 1 < argc; ++i) {
    if (_wcsicmp(argv[i], name) == 0) return argv[i + 1];
  }
  return {};
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show_command) {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  std::wstring log_path = ArgumentValue(argc, argv, L"--log");
  const std::wstring requested_mode = ArgumentValue(argc, argv, L"--mode");
  const std::wstring shell_file = ArgumentValue(argc, argv, L"--inspect-shell-file");
  if (!requested_mode.empty()) g_mode = requested_mode;
  if (log_path.empty()) {
    log_path = L"logs\\dropinspector-" + dnd::TimestampForFile() + L".log";
  }

  Logger log(log_path);
  g_log = &log;
  log.Writef(L"DropInspector starting pid=%lu mode=%ls", GetCurrentProcessId(),
             g_mode.c_str());
  log.Writef(L"commandLine=%ls", GetCommandLineW());

  const HRESULT ole_hr = OleInitialize(nullptr);
  log.Writef(L"OleInitialize -> %ls", dnd::HResultText(ole_hr).c_str());
  if (FAILED(ole_hr)) {
    MessageBoxW(nullptr, L"OleInitialize failed. See log.", L"DropInspector",
                MB_ICONERROR);
    if (argv) LocalFree(argv);
    return 1;
  }

  const wchar_t class_name[] = L"OttoDropInspectorWindow";
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = class_name;
  window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  window_class.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  RegisterClassW(&window_class);

  HWND window = CreateWindowExW(
      0, class_name, L"OTTO DropInspector", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
      CW_USEDEFAULT, CW_USEDEFAULT, 720, 420, nullptr, nullptr, instance, nullptr);
  if (!window) {
    log.Writef(L"CreateWindowExW failed error=%lu", GetLastError());
    OleUninitialize();
    if (argv) LocalFree(argv);
    return 1;
  }
  ShowWindow(window, show_command);
  UpdateWindow(window);

  DropTarget* drop_target = nullptr;
  bool ole_registered = false;
  if (_wcsicmp(g_mode.c_str(), L"legacy") != 0) {
    drop_target = new DropTarget(log);
    const HRESULT register_hr = RegisterDragDrop(window, drop_target);
    log.Writef(L"RegisterDragDrop -> %ls", dnd::HResultText(register_hr).c_str());
    ole_registered = SUCCEEDED(register_hr);
  }
  if (_wcsicmp(g_mode.c_str(), L"ole") != 0) {
    DragAcceptFiles(window, TRUE);
    log.Write(L"DragAcceptFiles(TRUE)");
  }

  if (!shell_file.empty()) {
    IDataObject* shell_data = nullptr;
    const HRESULT shell_hr = CreateShellDataObject(window, shell_file, &shell_data);
    log.Writef(L"ShellFolder::GetUIObjectOf(\"%ls\") -> %ls", shell_file.c_str(),
               dnd::HResultText(shell_hr).c_str());
    if (SUCCEEDED(shell_hr) && shell_data) {
      dnd::LogDataObjectSnapshot(log, shell_data,
                                 L"ShellFolder.GetUIObjectOf baseline");
      shell_data->Release();
    }
  }

  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }

  if (ole_registered) {
    const HRESULT revoke_hr = RevokeDragDrop(window);
    log.Writef(L"RevokeDragDrop -> %ls", dnd::HResultText(revoke_hr).c_str());
  }
  if (drop_target) drop_target->Release();
  OleUninitialize();
  log.Write(L"DropInspector stopped");
  if (argv) LocalFree(argv);
  return 0;
}
