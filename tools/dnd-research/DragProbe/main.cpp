#include "../common/dnd_common.h"

#include <shellapi.h>
#include <shlobj.h>
#include <windowsx.h>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

using dnd::Logger;

constexpr wchar_t kPreferredDropEffect[] = L"Preferred DropEffect";
constexpr wchar_t kFileNameA[] = L"FileName";
constexpr wchar_t kFileNameW[] = L"FileNameW";
constexpr wchar_t kShellIdList[] = L"Shell IDList Array";
constexpr wchar_t kFileDescriptorA[] = L"FileGroupDescriptor";
constexpr wchar_t kFileDescriptorW[] = L"FileGroupDescriptorW";
constexpr wchar_t kFileContents[] = L"FileContents";

enum class OfferKind {
  kHDrop,
  kPreferredEffect,
  kFileNameA,
  kFileNameW,
  kShellIdList,
  kFileDescriptorA,
  kFileDescriptorW,
  kFileContents,
};

struct Offer {
  OfferKind kind;
  FORMATETC format;
};

struct Config {
  std::wstring file_path;
  std::wstring log_path;
  std::wstring preset = L"A";
  std::wstring hdrop_encoding = L"unicode";
  std::wstring auto_target_title;
  UINT auto_delay_ms = 1200;
  std::vector<std::wstring> format_names;
};

HGLOBAL AllocateGlobal(SIZE_T size) {
  return GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size);
}

std::string WideToAnsi(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_ACP, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0,
                                       "?", nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_ACP, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size, "?", nullptr);
  return result;
}

HRESULT MakeHDrop(const Config& config, STGMEDIUM* medium) {
  const bool wide = _wcsicmp(config.hdrop_encoding.c_str(), L"ansi") != 0;
  const SIZE_T string_bytes = wide
      ? (config.file_path.size() + 2) * sizeof(wchar_t)
      : WideToAnsi(config.file_path).size() + 2;
  HGLOBAL global = AllocateGlobal(sizeof(DROPFILES) + string_bytes);
  if (!global) return E_OUTOFMEMORY;
  auto* drop = static_cast<DROPFILES*>(GlobalLock(global));
  if (!drop) {
    GlobalFree(global);
    return E_OUTOFMEMORY;
  }
  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = wide;
  auto* destination = reinterpret_cast<BYTE*>(drop) + drop->pFiles;
  if (wide) {
    memcpy(destination, config.file_path.c_str(),
           config.file_path.size() * sizeof(wchar_t));
  } else {
    const std::string ansi = WideToAnsi(config.file_path);
    memcpy(destination, ansi.data(), ansi.size());
  }
  GlobalUnlock(global);
  medium->tymed = TYMED_HGLOBAL;
  medium->hGlobal = global;
  return S_OK;
}

HRESULT MakeGlobalStringW(const std::wstring& value, STGMEDIUM* medium) {
  const SIZE_T bytes = (value.size() + 1) * sizeof(wchar_t);
  HGLOBAL global = AllocateGlobal(bytes);
  if (!global) return E_OUTOFMEMORY;
  void* data = GlobalLock(global);
  if (!data) {
    GlobalFree(global);
    return E_OUTOFMEMORY;
  }
  memcpy(data, value.c_str(), bytes);
  GlobalUnlock(global);
  medium->tymed = TYMED_HGLOBAL;
  medium->hGlobal = global;
  return S_OK;
}

HRESULT MakeGlobalStringA(const std::wstring& value, STGMEDIUM* medium) {
  const std::string ansi = WideToAnsi(value);
  HGLOBAL global = AllocateGlobal(ansi.size() + 1);
  if (!global) return E_OUTOFMEMORY;
  void* data = GlobalLock(global);
  if (!data) {
    GlobalFree(global);
    return E_OUTOFMEMORY;
  }
  memcpy(data, ansi.c_str(), ansi.size() + 1);
  GlobalUnlock(global);
  medium->tymed = TYMED_HGLOBAL;
  medium->hGlobal = global;
  return S_OK;
}

HRESULT MakePreferredEffect(STGMEDIUM* medium) {
  HGLOBAL global = AllocateGlobal(sizeof(DWORD));
  if (!global) return E_OUTOFMEMORY;
  auto* effect = static_cast<DWORD*>(GlobalLock(global));
  if (!effect) {
    GlobalFree(global);
    return E_OUTOFMEMORY;
  }
  *effect = DROPEFFECT_COPY;
  GlobalUnlock(global);
  medium->tymed = TYMED_HGLOBAL;
  medium->hGlobal = global;
  return S_OK;
}

HRESULT MakeShellIdList(const std::wstring& path, STGMEDIUM* medium) {
  PIDLIST_ABSOLUTE absolute = nullptr;
  HRESULT hr = SHParseDisplayName(path.c_str(), nullptr, &absolute, 0, nullptr);
  if (FAILED(hr)) return hr;

  IShellFolder* parent_folder = nullptr;
  PCUITEMID_CHILD child_borrowed = nullptr;
  hr = SHBindToParent(absolute, IID_PPV_ARGS(&parent_folder), &child_borrowed);
  if (FAILED(hr)) {
    CoTaskMemFree(absolute);
    return hr;
  }

  PIDLIST_RELATIVE child = ILClone(child_borrowed);
  PIDLIST_ABSOLUTE parent = ILClone(absolute);
  if (parent) ILRemoveLastID(parent);
  parent_folder->Release();
  CoTaskMemFree(absolute);
  if (!parent || !child) {
    if (parent) ILFree(parent);
    if (child) ILFree(child);
    return E_OUTOFMEMORY;
  }

  const UINT parent_size = ILGetSize(parent);
  const UINT child_size = ILGetSize(child);
  const SIZE_T header_size = sizeof(UINT) + 2 * sizeof(UINT);
  HGLOBAL global = AllocateGlobal(header_size + parent_size + child_size);
  if (!global) {
    ILFree(parent);
    ILFree(child);
    return E_OUTOFMEMORY;
  }
  auto* cida = static_cast<CIDA*>(GlobalLock(global));
  if (!cida) {
    GlobalFree(global);
    ILFree(parent);
    ILFree(child);
    return E_OUTOFMEMORY;
  }
  cida->cidl = 1;
  cida->aoffset[0] = static_cast<UINT>(header_size);
  cida->aoffset[1] = static_cast<UINT>(header_size + parent_size);
  auto* bytes = reinterpret_cast<BYTE*>(cida);
  memcpy(bytes + cida->aoffset[0], parent, parent_size);
  memcpy(bytes + cida->aoffset[1], child, child_size);
  GlobalUnlock(global);
  ILFree(parent);
  ILFree(child);

  medium->tymed = TYMED_HGLOBAL;
  medium->hGlobal = global;
  return S_OK;
}

void FillDescriptorMetadata(const Config& config, DWORD* flags,
                            DWORD* attributes, FILETIME* write_time,
                            DWORD* size_high, DWORD* size_low) {
  WIN32_FILE_ATTRIBUTE_DATA data{};
  if (GetFileAttributesExW(config.file_path.c_str(), GetFileExInfoStandard,
                           &data)) {
    *flags = FD_ATTRIBUTES | FD_WRITESTIME | FD_FILESIZE;
    *attributes = data.dwFileAttributes;
    *write_time = data.ftLastWriteTime;
    *size_high = data.nFileSizeHigh;
    *size_low = data.nFileSizeLow;
  }
}

HRESULT MakeFileDescriptorW(const Config& config, STGMEDIUM* medium) {
  HGLOBAL global = AllocateGlobal(sizeof(FILEGROUPDESCRIPTORW));
  if (!global) return E_OUTOFMEMORY;
  auto* group = static_cast<FILEGROUPDESCRIPTORW*>(GlobalLock(global));
  if (!group) {
    GlobalFree(global);
    return E_OUTOFMEMORY;
  }
  group->cItems = 1;
  auto& item = group->fgd[0];
  FillDescriptorMetadata(config, &item.dwFlags, &item.dwFileAttributes,
                         &item.ftLastWriteTime, &item.nFileSizeHigh,
                         &item.nFileSizeLow);
  const std::wstring name = std::filesystem::path(config.file_path).filename();
  wcsncpy_s(item.cFileName, name.c_str(), _TRUNCATE);
  GlobalUnlock(global);
  medium->tymed = TYMED_HGLOBAL;
  medium->hGlobal = global;
  return S_OK;
}

HRESULT MakeFileDescriptorA(const Config& config, STGMEDIUM* medium) {
  HGLOBAL global = AllocateGlobal(sizeof(FILEGROUPDESCRIPTORA));
  if (!global) return E_OUTOFMEMORY;
  auto* group = static_cast<FILEGROUPDESCRIPTORA*>(GlobalLock(global));
  if (!group) {
    GlobalFree(global);
    return E_OUTOFMEMORY;
  }
  group->cItems = 1;
  auto& item = group->fgd[0];
  FillDescriptorMetadata(config, &item.dwFlags, &item.dwFileAttributes,
                         &item.ftLastWriteTime, &item.nFileSizeHigh,
                         &item.nFileSizeLow);
  const std::string name =
      WideToAnsi(std::filesystem::path(config.file_path).filename().wstring());
  strncpy_s(item.cFileName, name.c_str(), _TRUNCATE);
  GlobalUnlock(global);
  medium->tymed = TYMED_HGLOBAL;
  medium->hGlobal = global;
  return S_OK;
}

HRESULT MakeFileContents(const Config& config, STGMEDIUM* medium) {
  HANDLE file = CreateFileW(config.file_path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return HRESULT_FROM_WIN32(GetLastError());
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart > MAXDWORD) {
    CloseHandle(file);
    return STG_E_MEDIUMFULL;
  }
  HGLOBAL global = AllocateGlobal(static_cast<SIZE_T>(size.QuadPart));
  if (!global) {
    CloseHandle(file);
    return E_OUTOFMEMORY;
  }
  void* data = GlobalLock(global);
  DWORD read = 0;
  const BOOL read_ok = ReadFile(file, data, static_cast<DWORD>(size.QuadPart),
                                &read, nullptr);
  GlobalUnlock(global);
  CloseHandle(file);
  if (!read_ok || read != size.QuadPart) {
    GlobalFree(global);
    return STG_E_READFAULT;
  }
  IStream* stream = nullptr;
  const HRESULT hr = CreateStreamOnHGlobal(global, TRUE, &stream);
  if (FAILED(hr)) {
    GlobalFree(global);
    return hr;
  }
  medium->tymed = TYMED_ISTREAM;
  medium->pstm = stream;
  return S_OK;
}

class FormatEnumerator final : public IEnumFORMATETC {
 public:
  explicit FormatEnumerator(std::vector<FORMATETC> formats,
                            ULONG index = 0)
      : formats_(std::move(formats)), index_(index) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (iid == IID_IUnknown || iid == IID_IEnumFORMATETC) {
      *object = static_cast<IEnumFORMATETC*>(this);
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
  HRESULT STDMETHODCALLTYPE Next(ULONG count, FORMATETC* output,
                                 ULONG* fetched) override {
    if (!output || (count != 1 && !fetched)) return E_POINTER;
    ULONG copied = 0;
    while (copied < count && index_ < formats_.size()) {
      output[copied] = formats_[index_];
      output[copied].ptd = nullptr;
      ++copied;
      ++index_;
    }
    if (fetched) *fetched = copied;
    return copied == count ? S_OK : S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE Skip(ULONG count) override {
    index_ = std::min<ULONG>(static_cast<ULONG>(formats_.size()), index_ + count);
    return index_ < formats_.size() ? S_OK : S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE Reset() override {
    index_ = 0;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Clone(IEnumFORMATETC** result) override {
    if (!result) return E_POINTER;
    *result = new FormatEnumerator(formats_, index_);
    return S_OK;
  }

 private:
  ~FormatEnumerator() = default;
  LONG refs_ = 1;
  std::vector<FORMATETC> formats_;
  ULONG index_ = 0;
};

class ProbeDataObject final : public IDataObject {
 public:
  ProbeDataObject(Config config, std::vector<Offer> offers, Logger& log)
      : config_(std::move(config)), offers_(std::move(offers)), log_(log) {}

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
    ZeroMemory(medium, sizeof(*medium));
    log_.Writef(L"IDataObject::GetData request: %ls",
                dnd::FormatEtcText(*request).c_str());
    const Offer* offer = FindOffer(*request);
    HRESULT hr = offer ? CreateMedium(*offer, medium) : DV_E_FORMATETC;
    log_.Writef(L"IDataObject::GetData result: %ls medium.tymed=0x%08lX",
                dnd::HResultText(hr).c_str(), medium->tymed);
    return hr;
  }

  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC* request,
                                        STGMEDIUM*) override {
    log_.Writef(L"IDataObject::GetDataHere request: %ls -> E_NOTIMPL",
                request ? dnd::FormatEtcText(*request).c_str() : L"<null>");
    return E_NOTIMPL;
  }

  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* request) override {
    if (!request) return E_POINTER;
    const HRESULT hr = ValidateRequest(*request);
    log_.Writef(L"IDataObject::QueryGetData request: %ls -> %ls",
                dnd::FormatEtcText(*request).c_str(), dnd::HResultText(hr).c_str());
    return hr;
  }

  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC* request,
                                                   FORMATETC* output) override {
    log_.Writef(L"IDataObject::GetCanonicalFormatEtc request: %ls",
                request ? dnd::FormatEtcText(*request).c_str() : L"<null>");
    if (!output) return E_POINTER;
    output->ptd = nullptr;
    return DATA_S_SAMEFORMATETC;
  }

  HRESULT STDMETHODCALLTYPE SetData(FORMATETC* request, STGMEDIUM*,
                                    BOOL release) override {
    log_.Writef(L"IDataObject::SetData request: %ls release=%d -> E_NOTIMPL",
                request ? dnd::FormatEtcText(*request).c_str() : L"<null>",
                release);
    return E_NOTIMPL;
  }

  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction,
                                          IEnumFORMATETC** result) override {
    log_.Writef(L"IDataObject::EnumFormatEtc direction=%lu", direction);
    if (!result) return E_POINTER;
    *result = nullptr;
    if (direction != DATADIR_GET) {
      log_.Write(L"IDataObject::EnumFormatEtc -> E_NOTIMPL");
      return E_NOTIMPL;
    }
    std::vector<FORMATETC> formats;
    formats.reserve(offers_.size());
    for (const auto& offer : offers_) formats.push_back(offer.format);
    *result = new FormatEnumerator(std::move(formats));
    log_.Writef(L"IDataObject::EnumFormatEtc -> S_OK count=%llu",
                static_cast<unsigned long long>(offers_.size()));
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC* request, DWORD flags,
                                    IAdviseSink*, DWORD* connection) override {
    log_.Writef(L"IDataObject::DAdvise request: %ls flags=0x%08lX -> OLE_E_ADVISENOTSUPPORTED",
                request ? dnd::FormatEtcText(*request).c_str() : L"<null>", flags);
    if (connection) *connection = 0;
    return OLE_E_ADVISENOTSUPPORTED;
  }
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD connection) override {
    log_.Writef(L"IDataObject::DUnadvise connection=%lu -> OLE_E_ADVISENOTSUPPORTED",
                connection);
    return OLE_E_ADVISENOTSUPPORTED;
  }
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA** result) override {
    log_.Write(L"IDataObject::EnumDAdvise -> OLE_E_ADVISENOTSUPPORTED");
    if (result) *result = nullptr;
    return OLE_E_ADVISENOTSUPPORTED;
  }

 private:
  ~ProbeDataObject() = default;

  HRESULT ValidateRequest(const FORMATETC& request) const {
    bool format_found = false;
    bool aspect_found = false;
    bool index_found = false;
    for (const auto& offer : offers_) {
      if (offer.format.cfFormat != request.cfFormat) continue;
      format_found = true;
      if (request.dwAspect != offer.format.dwAspect) continue;
      aspect_found = true;
      if (request.lindex != offer.format.lindex) continue;
      index_found = true;
      if ((request.tymed & offer.format.tymed) == 0) continue;
      return S_OK;
    }
    if (!format_found) return DV_E_FORMATETC;
    if (!aspect_found) return DV_E_DVASPECT;
    if (!index_found) return DV_E_LINDEX;
    return DV_E_TYMED;
  }

  const Offer* FindOffer(const FORMATETC& request) const {
    if (FAILED(ValidateRequest(request))) return nullptr;
    for (const auto& offer : offers_) {
      if (offer.format.cfFormat == request.cfFormat &&
          offer.format.dwAspect == request.dwAspect &&
          offer.format.lindex == request.lindex &&
          (offer.format.tymed & request.tymed) != 0) {
        return &offer;
      }
    }
    return nullptr;
  }

  HRESULT CreateMedium(const Offer& offer, STGMEDIUM* medium) const {
    switch (offer.kind) {
      case OfferKind::kHDrop:
        return MakeHDrop(config_, medium);
      case OfferKind::kPreferredEffect:
        return MakePreferredEffect(medium);
      case OfferKind::kFileNameA:
        return MakeGlobalStringA(config_.file_path, medium);
      case OfferKind::kFileNameW:
        return MakeGlobalStringW(config_.file_path, medium);
      case OfferKind::kShellIdList:
        return MakeShellIdList(config_.file_path, medium);
      case OfferKind::kFileDescriptorA:
        return MakeFileDescriptorA(config_, medium);
      case OfferKind::kFileDescriptorW:
        return MakeFileDescriptorW(config_, medium);
      case OfferKind::kFileContents:
        return MakeFileContents(config_, medium);
    }
    return DV_E_FORMATETC;
  }

  LONG refs_ = 1;
  Config config_;
  std::vector<Offer> offers_;
  Logger& log_;
};

class ProbeDropSource final : public IDropSource {
 public:
  explicit ProbeDropSource(Logger& log) : log_(log) {}
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
    HRESULT hr = S_OK;
    if (escape_pressed) {
      hr = DRAGDROP_S_CANCEL;
    } else if ((key_state & MK_LBUTTON) == 0) {
      hr = DRAGDROP_S_DROP;
    }
    if (hr != last_result_) {
      log_.Writef(L"IDropSource::QueryContinueDrag escape=%d keyState=0x%08lX -> %ls",
                  escape_pressed, key_state, dnd::HResultText(hr).c_str());
      last_result_ = hr;
    }
    return hr;
  }
  HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD effect) override {
    if (effect != last_effect_) {
      log_.Writef(L"IDropSource::GiveFeedback effect=%ls -> DRAGDROP_S_USEDEFAULTCURSORS",
                  dnd::DropEffectText(effect).c_str());
      last_effect_ = effect;
    }
    return DRAGDROP_S_USEDEFAULTCURSORS;
  }

 private:
  ~ProbeDropSource() = default;
  LONG refs_ = 1;
  Logger& log_;
  HRESULT last_result_ = E_UNEXPECTED;
  DWORD last_effect_ = 0xFFFFFFFF;
};

FORMATETC MakeFormat(CLIPFORMAT format, DWORD tymed, LONG index = -1) {
  FORMATETC result{};
  result.cfFormat = format;
  result.dwAspect = DVASPECT_CONTENT;
  result.lindex = index;
  result.tymed = tymed;
  return result;
}

std::vector<std::wstring> PresetFormats(const std::wstring& preset) {
  if (_wcsicmp(preset.c_str(), L"B") == 0)
    return {L"hdrop", L"preferred"};
  if (_wcsicmp(preset.c_str(), L"C") == 0)
    return {L"hdrop", L"preferred", L"filenamea", L"filenamew"};
  if (_wcsicmp(preset.c_str(), L"D") == 0)
    return {L"hdrop", L"preferred", L"filenamea", L"filenamew", L"shellidlist"};
  if (_wcsicmp(preset.c_str(), L"E") == 0)
    return {L"hdrop", L"preferred", L"filenamea", L"filenamew", L"shellidlist",
            L"filedescriptora", L"filedescriptorw", L"filecontents"};
  return {L"hdrop"};
}

std::vector<Offer> BuildOffers(Config& config) {
  if (config.format_names.empty()) config.format_names = PresetFormats(config.preset);
  std::vector<Offer> offers;
  for (const auto& name : config.format_names) {
    if (_wcsicmp(name.c_str(), L"hdrop") == 0) {
      offers.push_back({OfferKind::kHDrop, MakeFormat(CF_HDROP, TYMED_HGLOBAL)});
    } else if (_wcsicmp(name.c_str(), L"preferred") == 0) {
      offers.push_back({OfferKind::kPreferredEffect,
                        MakeFormat(static_cast<CLIPFORMAT>(RegisterClipboardFormatW(kPreferredDropEffect)),
                                   TYMED_HGLOBAL)});
    } else if (_wcsicmp(name.c_str(), L"filenamea") == 0) {
      offers.push_back({OfferKind::kFileNameA,
                        MakeFormat(static_cast<CLIPFORMAT>(RegisterClipboardFormatW(kFileNameA)), TYMED_HGLOBAL)});
    } else if (_wcsicmp(name.c_str(), L"filenamew") == 0) {
      offers.push_back({OfferKind::kFileNameW,
                        MakeFormat(static_cast<CLIPFORMAT>(RegisterClipboardFormatW(kFileNameW)), TYMED_HGLOBAL)});
    } else if (_wcsicmp(name.c_str(), L"shellidlist") == 0) {
      offers.push_back({OfferKind::kShellIdList,
                        MakeFormat(static_cast<CLIPFORMAT>(RegisterClipboardFormatW(kShellIdList)), TYMED_HGLOBAL)});
    } else if (_wcsicmp(name.c_str(), L"filedescriptora") == 0) {
      offers.push_back({OfferKind::kFileDescriptorA,
                        MakeFormat(static_cast<CLIPFORMAT>(RegisterClipboardFormatW(kFileDescriptorA)),
                                   TYMED_HGLOBAL)});
    } else if (_wcsicmp(name.c_str(), L"filedescriptorw") == 0) {
      offers.push_back({OfferKind::kFileDescriptorW,
                        MakeFormat(static_cast<CLIPFORMAT>(RegisterClipboardFormatW(kFileDescriptorW)),
                                   TYMED_HGLOBAL)});
    } else if (_wcsicmp(name.c_str(), L"filecontents") == 0) {
      offers.push_back({OfferKind::kFileContents,
                        MakeFormat(static_cast<CLIPFORMAT>(RegisterClipboardFormatW(kFileContents)), TYMED_ISTREAM,
                                   0)});
    }
  }
  return offers;
}

std::wstring JoinFormatNames(const std::vector<std::wstring>& names) {
  std::wstring result;
  for (const auto& name : names) {
    if (!result.empty()) result += L", ";
    result += name;
  }
  return result;
}

struct AppState {
  Config config;
  std::vector<Offer> offers;
  Logger* log = nullptr;
  POINT drag_start{};
  bool tracking = false;
  bool dragging = false;
};

AppState* g_app = nullptr;

void BeginDrag(HWND window) {
  if (!g_app || g_app->dragging) return;
  g_app->dragging = true;
  g_app->tracking = false;
  ReleaseCapture();
  auto* data_object = new ProbeDataObject(g_app->config, g_app->offers, *g_app->log);
  auto* drop_source = new ProbeDropSource(*g_app->log);
  DWORD effect = DROPEFFECT_NONE;
  g_app->log->Writef(L"DoDragDrop begin file=\"%ls\" formats=%ls hdrop=%ls",
                     g_app->config.file_path.c_str(),
                     JoinFormatNames(g_app->config.format_names).c_str(),
                     g_app->config.hdrop_encoding.c_str());
  const HRESULT hr = DoDragDrop(data_object, drop_source,
                                DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK,
                                &effect);
  g_app->log->Writef(L"DoDragDrop end -> %ls finalEffect=%ls",
                     dnd::HResultText(hr).c_str(), dnd::DropEffectText(effect).c_str());
  drop_source->Release();
  data_object->Release();
  g_app->dragging = false;
  InvalidateRect(window, nullptr, TRUE);
}

struct FindWindowContext {
  HWND source = nullptr;
  std::wstring title;
  HWND result = nullptr;
};

BOOL CALLBACK FindWindowCallback(HWND window, LPARAM parameter) {
  auto* context = reinterpret_cast<FindWindowContext*>(parameter);
  if (window == context->source || !IsWindowVisible(window)) return TRUE;
  wchar_t title[512]{};
  GetWindowTextW(window, title, 512);
  std::wstring candidate = title;
  std::wstring wanted = context->title;
  std::transform(candidate.begin(), candidate.end(), candidate.begin(), towlower);
  std::transform(wanted.begin(), wanted.end(), wanted.begin(), towlower);
  if (!wanted.empty() && candidate.find(wanted) != std::wstring::npos) {
    context->result = window;
    return FALSE;
  }
  return TRUE;
}

void StartAutomatedDrag(HWND source) {
  FindWindowContext context{source, g_app->config.auto_target_title, nullptr};
  EnumWindows(FindWindowCallback, reinterpret_cast<LPARAM>(&context));
  if (!context.result) {
    g_app->log->Writef(L"auto drag target not found titleContains=\"%ls\"",
                       context.title.c_str());
    return;
  }
  RECT source_rect{};
  RECT target_client{};
  GetWindowRect(source, &source_rect);
  GetClientRect(context.result, &target_client);
  POINT target{(target_client.left + target_client.right) / 2,
               (target_client.top + target_client.bottom) / 2};
  ClientToScreen(context.result, &target);
  POINT start{(source_rect.left + source_rect.right) / 2,
              (source_rect.top + source_rect.bottom) / 2};
  g_app->log->Writef(L"auto drag target hwnd=%p start=(%ld,%ld) target=(%ld,%ld)",
                     context.result, start.x, start.y, target.x, target.y);
  SetForegroundWindow(source);
  SetCursorPos(start.x, start.y);
  INPUT input{};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
  SendInput(1, &input, sizeof(input));
  const HWND target_window = context.result;
  std::thread([start, target, target_window]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    SetForegroundWindow(target_window);
    constexpr int steps = 24;
    for (int i = 1; i <= steps; ++i) {
      const int x = start.x + (target.x - start.x) * i / steps;
      const int y = start.y + (target.y - start.y) * i / steps;
      SetCursorPos(x, y);
      std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    INPUT release{};
    release.type = INPUT_MOUSE;
    release.mi.dwFlags = MOUSEEVENTF_LEFTUP;
    SendInput(1, &release, sizeof(release));
  }).detach();
  BeginDrag(source);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                            LPARAM lparam) {
  switch (message) {
    case WM_TIMER:
      KillTimer(window, 1);
      StartAutomatedDrag(window);
      return 0;
    case WM_LBUTTONDOWN:
      if (!g_app->dragging) {
        g_app->drag_start = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        g_app->tracking = true;
        SetCapture(window);
      }
      return 0;
    case WM_MOUSEMOVE:
      if (g_app->tracking && (wparam & MK_LBUTTON)) {
        const int dx = abs(GET_X_LPARAM(lparam) - g_app->drag_start.x);
        const int dy = abs(GET_Y_LPARAM(lparam) - g_app->drag_start.y);
        if (dx >= GetSystemMetrics(SM_CXDRAG) || dy >= GetSystemMetrics(SM_CYDRAG)) {
          BeginDrag(window);
        }
      }
      return 0;
    case WM_LBUTTONUP:
      g_app->tracking = false;
      ReleaseCapture();
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT paint{};
      HDC dc = BeginPaint(window, &paint);
      RECT client{};
      GetClientRect(window, &client);
      SetBkMode(dc, TRANSPARENT);
      const std::wstring status = g_app->dragging ? L"Dragging..." : L"Ready";
      const std::wstring text =
          L"DragProbe - " + status +
          L"\n\nPress and drag anywhere in this window to a target.\n\nFile: " +
          g_app->config.file_path + L"\nPreset: " + g_app->config.preset +
          L"\nFormats: " + JoinFormatNames(g_app->config.format_names) +
          L"\nCF_HDROP encoding: " + g_app->config.hdrop_encoding +
          L"\n\nLog: " + g_app->config.log_path;
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

std::wstring ArgumentValue(int argc, wchar_t** argv, const wchar_t* name) {
  for (int i = 1; i + 1 < argc; ++i) {
    if (_wcsicmp(argv[i], name) == 0) return argv[i + 1];
  }
  return {};
}

std::vector<std::wstring> SplitFormats(const std::wstring& value) {
  std::vector<std::wstring> result;
  std::wstringstream input(value);
  std::wstring item;
  while (std::getline(input, item, L',')) {
    if (!item.empty()) result.push_back(item);
  }
  return result;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show_command) {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  Config config;
  config.file_path = ArgumentValue(argc, argv, L"--file");
  const std::wstring preset = ArgumentValue(argc, argv, L"--preset");
  const std::wstring formats = ArgumentValue(argc, argv, L"--formats");
  const std::wstring encoding = ArgumentValue(argc, argv, L"--hdrop");
  const std::wstring delay = ArgumentValue(argc, argv, L"--delay-ms");
  config.log_path = ArgumentValue(argc, argv, L"--log");
  config.auto_target_title = ArgumentValue(argc, argv, L"--auto-target-title");
  if (!preset.empty()) config.preset = preset;
  if (!formats.empty()) config.format_names = SplitFormats(formats);
  if (!encoding.empty()) config.hdrop_encoding = encoding;
  if (!delay.empty()) config.auto_delay_ms = static_cast<UINT>(_wtoi(delay.c_str()));
  if (config.log_path.empty()) {
    config.log_path = L"logs\\dragprobe-" + config.preset + L"-" +
                      dnd::TimestampForFile() + L".log";
  }
  if (config.file_path.empty() ||
      GetFileAttributesW(config.file_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    MessageBoxW(nullptr,
                L"Usage: DragProbe.exe --file C:\\path\\a.wav [--preset A|B|C|D|E] "
                L"[--hdrop unicode|ansi] [--formats comma,list]",
                L"DragProbe", MB_ICONERROR);
    if (argv) LocalFree(argv);
    return 2;
  }

  Logger log(config.log_path);
  log.Writef(L"DragProbe starting pid=%lu commandLine=%ls", GetCurrentProcessId(),
             GetCommandLineW());
  const HRESULT ole_hr = OleInitialize(nullptr);
  log.Writef(L"OleInitialize -> %ls", dnd::HResultText(ole_hr).c_str());
  if (FAILED(ole_hr)) {
    if (argv) LocalFree(argv);
    return 1;
  }

  AppState app;
  app.config = config;
  app.offers = BuildOffers(app.config);
  app.log = &log;
  g_app = &app;
  log.Writef(L"file=\"%ls\" preset=%ls formats=%ls hdrop=%ls",
             app.config.file_path.c_str(), app.config.preset.c_str(),
             JoinFormatNames(app.config.format_names).c_str(),
             app.config.hdrop_encoding.c_str());
  for (size_t i = 0; i < app.offers.size(); ++i) {
    log.Writef(L"offer[%llu] %ls", static_cast<unsigned long long>(i),
               dnd::FormatEtcText(app.offers[i].format).c_str());
  }

  const wchar_t class_name[] = L"OttoDragProbeWindow";
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = class_name;
  window_class.hCursor = LoadCursorW(nullptr, IDC_HAND);
  window_class.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  RegisterClassW(&window_class);
  HWND window = CreateWindowExW(
      0, class_name, L"OTTO DragProbe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
      CW_USEDEFAULT, CW_USEDEFAULT, 760, 440, nullptr, nullptr, instance, nullptr);
  if (!window) {
    log.Writef(L"CreateWindowExW failed error=%lu", GetLastError());
    OleUninitialize();
    if (argv) LocalFree(argv);
    return 1;
  }
  ShowWindow(window, show_command);
  UpdateWindow(window);
  if (!app.config.auto_target_title.empty()) {
    SetTimer(window, 1, app.config.auto_delay_ms, nullptr);
  }

  MSG message{};
  while (GetMessageW(&message, nullptr, 0, 0) > 0) {
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  OleUninitialize();
  log.Write(L"DragProbe stopped");
  if (argv) LocalFree(argv);
  return 0;
}
