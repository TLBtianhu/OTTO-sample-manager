#include "dnd_common.h"

#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <vector>

namespace dnd {
namespace {

std::wstring HexValue(unsigned long long value, int width = 0) {
  std::wostringstream out;
  out << L"0x" << std::uppercase << std::hex << std::setfill(L'0');
  if (width > 0) out << std::setw(width);
  out << value;
  return out.str();
}

std::wstring JoinBits(DWORD value,
                      const std::vector<std::pair<DWORD, const wchar_t*>>& bits) {
  std::wstring result;
  for (const auto& bit : bits) {
    if ((value & bit.first) == 0) continue;
    if (!result.empty()) result += L"|";
    result += bit.second;
  }
  return result.empty() ? L"0" : result;
}

std::wstring TymedText(DWORD tymed) {
  return JoinBits(tymed, {{TYMED_HGLOBAL, L"HGLOBAL"},
                          {TYMED_FILE, L"FILE"},
                          {TYMED_ISTREAM, L"ISTREAM"},
                          {TYMED_ISTORAGE, L"ISTORAGE"},
                          {TYMED_GDI, L"GDI"},
                          {TYMED_MFPICT, L"MFPICT"},
                          {TYMED_ENHMF, L"ENHMF"},
                          {TYMED_NULL, L"NULL"}});
}

std::wstring AspectText(DWORD aspect) {
  return JoinBits(aspect, {{DVASPECT_CONTENT, L"CONTENT"},
                           {DVASPECT_THUMBNAIL, L"THUMBNAIL"},
                           {DVASPECT_ICON, L"ICON"},
                           {DVASPECT_DOCPRINT, L"DOCPRINT"}});
}

std::wstring GlobalStringW(HGLOBAL global) {
  const SIZE_T size = GlobalSize(global);
  const wchar_t* data = static_cast<const wchar_t*>(GlobalLock(global));
  if (!data || size < sizeof(wchar_t)) return L"<invalid>";
  const size_t capacity = size / sizeof(wchar_t);
  size_t length = 0;
  while (length < capacity && data[length] != L'\0') ++length;
  std::wstring result(data, length);
  GlobalUnlock(global);
  return result;
}

std::wstring GlobalStringA(HGLOBAL global) {
  const SIZE_T size = GlobalSize(global);
  const char* data = static_cast<const char*>(GlobalLock(global));
  if (!data || size == 0) return L"<invalid>";
  size_t length = 0;
  while (length < size && data[length] != '\0') ++length;
  const int wide_length = MultiByteToWideChar(CP_ACP, 0, data,
                                               static_cast<int>(length), nullptr, 0);
  std::wstring result(wide_length, L'\0');
  if (wide_length > 0) {
    MultiByteToWideChar(CP_ACP, 0, data, static_cast<int>(length), result.data(),
                        wide_length);
  }
  GlobalUnlock(global);
  return result;
}

std::wstring HexPreview(HGLOBAL global, SIZE_T limit = 96) {
  const SIZE_T size = GlobalSize(global);
  const auto* data = static_cast<const unsigned char*>(GlobalLock(global));
  if (!data || size == 0) return L"<empty>";
  std::wostringstream out;
  const SIZE_T count = std::min(size, limit);
  out << std::uppercase << std::hex << std::setfill(L'0');
  for (SIZE_T i = 0; i < count; ++i) {
    if (i != 0) out << L' ';
    out << std::setw(2) << static_cast<unsigned int>(data[i]);
  }
  if (count < size) out << L" ...";
  GlobalUnlock(global);
  return out.str();
}

void LogHDrop(Logger& log, HGLOBAL global) {
  const SIZE_T size = GlobalSize(global);
  const auto* drop = static_cast<const DROPFILES*>(GlobalLock(global));
  if (!drop || size < sizeof(DROPFILES)) {
    log.Write(L"    CF_HDROP: invalid DROPFILES");
    return;
  }
  log.Writef(L"    CF_HDROP: bytes=%llu pFiles=%lu pt=(%ld,%ld) fNC=%d fWide=%d",
             static_cast<unsigned long long>(size), drop->pFiles, drop->pt.x,
             drop->pt.y, drop->fNC, drop->fWide);
  GlobalUnlock(global);

  const UINT count = DragQueryFileW(reinterpret_cast<HDROP>(global), 0xFFFFFFFF,
                                    nullptr, 0);
  log.Writef(L"    CF_HDROP: fileCount=%u", count);
  for (UINT index = 0; index < count; ++index) {
    const UINT wide_size =
        DragQueryFileW(reinterpret_cast<HDROP>(global), index, nullptr, 0);
    std::wstring wide_path(wide_size + 1, L'\0');
    DragQueryFileW(reinterpret_cast<HDROP>(global), index, wide_path.data(),
                   wide_size + 1);
    wide_path.resize(wide_size);

    const UINT ansi_size =
        DragQueryFileA(reinterpret_cast<HDROP>(global), index, nullptr, 0);
    std::string ansi_path(ansi_size + 1, '\0');
    DragQueryFileA(reinterpret_cast<HDROP>(global), index, ansi_path.data(),
                   ansi_size + 1);
    ansi_path.resize(ansi_size);
    const int converted_size = MultiByteToWideChar(
        CP_ACP, 0, ansi_path.data(), static_cast<int>(ansi_path.size()), nullptr, 0);
    std::wstring converted(converted_size, L'\0');
    if (converted_size > 0) {
      MultiByteToWideChar(CP_ACP, 0, ansi_path.data(),
                          static_cast<int>(ansi_path.size()), converted.data(),
                          converted_size);
    }
    log.Writef(L"      [%u] W=\"%ls\" ANSI view=\"%ls\"", index,
               wide_path.c_str(), converted.c_str());
  }
  log.Writef(L"    CF_HDROP raw: %ls", HexPreview(global).c_str());
}

void LogPreferredEffect(Logger& log, HGLOBAL global) {
  const SIZE_T size = GlobalSize(global);
  const auto* effect = static_cast<const DWORD*>(GlobalLock(global));
  if (!effect || size < sizeof(DWORD)) {
    log.Write(L"    Preferred DropEffect: invalid DWORD");
    return;
  }
  log.Writef(L"    Preferred DropEffect: %ls (%ls)",
             HexValue(*effect, 8).c_str(), DropEffectText(*effect).c_str());
  GlobalUnlock(global);
}

void LogFileGroupDescriptorW(Logger& log, HGLOBAL global) {
  const SIZE_T size = GlobalSize(global);
  const auto* group =
      static_cast<const FILEGROUPDESCRIPTORW*>(GlobalLock(global));
  if (!group || size < sizeof(UINT)) {
    log.Write(L"    FileGroupDescriptorW: invalid");
    return;
  }
  const SIZE_T required = sizeof(UINT) +
                          static_cast<SIZE_T>(group->cItems) * sizeof(FILEDESCRIPTORW);
  log.Writef(L"    FileGroupDescriptorW: items=%u bytes=%llu required=%llu",
             group->cItems, static_cast<unsigned long long>(size),
             static_cast<unsigned long long>(required));
  if (required <= size) {
    for (UINT i = 0; i < group->cItems; ++i) {
      const auto& item = group->fgd[i];
      const ULONGLONG file_size =
          (static_cast<ULONGLONG>(item.nFileSizeHigh) << 32) | item.nFileSizeLow;
      log.Writef(L"      [%u] name=\"%ls\" flags=%ls size=%llu", i,
                 item.cFileName, HexValue(item.dwFlags, 8).c_str(), file_size);
    }
  }
  GlobalUnlock(global);
}

void LogFileGroupDescriptorA(Logger& log, HGLOBAL global) {
  const SIZE_T size = GlobalSize(global);
  const auto* group =
      static_cast<const FILEGROUPDESCRIPTORA*>(GlobalLock(global));
  if (!group || size < sizeof(UINT)) {
    log.Write(L"    FileGroupDescriptor: invalid");
    return;
  }
  const SIZE_T required = sizeof(UINT) +
                          static_cast<SIZE_T>(group->cItems) * sizeof(FILEDESCRIPTORA);
  log.Writef(L"    FileGroupDescriptor: items=%u bytes=%llu required=%llu",
             group->cItems, static_cast<unsigned long long>(size),
             static_cast<unsigned long long>(required));
  if (required <= size) {
    for (UINT i = 0; i < group->cItems; ++i) {
      const auto& item = group->fgd[i];
      const int wide_size = MultiByteToWideChar(CP_ACP, 0, item.cFileName, -1,
                                                nullptr, 0);
      std::wstring name(wide_size > 0 ? wide_size : 0, L'\0');
      if (wide_size > 0) {
        MultiByteToWideChar(CP_ACP, 0, item.cFileName, -1, name.data(), wide_size);
        if (!name.empty() && name.back() == L'\0') name.pop_back();
      }
      const ULONGLONG file_size =
          (static_cast<ULONGLONG>(item.nFileSizeHigh) << 32) | item.nFileSizeLow;
      log.Writef(L"      [%u] name=\"%ls\" flags=%ls size=%llu", i,
                 name.c_str(), HexValue(item.dwFlags, 8).c_str(), file_size);
    }
  }
  GlobalUnlock(global);
}

void LogShellIdList(Logger& log, HGLOBAL global) {
  const SIZE_T size = GlobalSize(global);
  const auto* cida = static_cast<const CIDA*>(GlobalLock(global));
  if (!cida || size < sizeof(UINT) * 2) {
    log.Write(L"    Shell IDList Array: invalid CIDA");
    return;
  }
  const SIZE_T offset_bytes =
      sizeof(UINT) + static_cast<SIZE_T>(cida->cidl + 1) * sizeof(UINT);
  log.Writef(L"    Shell IDList Array: children=%u bytes=%llu", cida->cidl,
             static_cast<unsigned long long>(size));
  if (offset_bytes > size || cida->aoffset[0] >= size) {
    log.Write(L"    Shell IDList Array: invalid offsets");
    GlobalUnlock(global);
    return;
  }
  const auto* base = reinterpret_cast<const BYTE*>(cida);
  auto parent = reinterpret_cast<PCIDLIST_ABSOLUTE>(base + cida->aoffset[0]);
  wchar_t parent_path[MAX_PATH]{};
  SHGetPathFromIDListW(parent, parent_path);
  log.Writef(L"      parent=\"%ls\"", parent_path);
  for (UINT i = 0; i < cida->cidl; ++i) {
    if (cida->aoffset[i + 1] >= size) {
      log.Writef(L"      [%u] invalid offset=%u", i, cida->aoffset[i + 1]);
      continue;
    }
    auto child = reinterpret_cast<PCUIDLIST_RELATIVE>(base + cida->aoffset[i + 1]);
    PIDLIST_ABSOLUTE combined = ILCombine(parent, child);
    wchar_t child_path[MAX_PATH]{};
    const BOOL resolved = combined ? SHGetPathFromIDListW(combined, child_path) : FALSE;
    log.Writef(L"      [%u] offset=%u path=\"%ls\" resolved=%d", i,
               cida->aoffset[i + 1], child_path, resolved);
    if (combined) ILFree(combined);
  }
  GlobalUnlock(global);
}

void LogKnownData(Logger& log, CLIPFORMAT format, const std::wstring& name,
                  const STGMEDIUM& medium) {
  if (medium.tymed == TYMED_HGLOBAL && !medium.hGlobal) {
    log.Write(L"    HGLOBAL is null");
    return;
  }
  if (format == CF_HDROP && medium.tymed == TYMED_HGLOBAL) {
    LogHDrop(log, medium.hGlobal);
  } else if (name == L"Preferred DropEffect" &&
             medium.tymed == TYMED_HGLOBAL) {
    LogPreferredEffect(log, medium.hGlobal);
  } else if ((name == L"FileNameW" || name == L"UniformResourceLocatorW") &&
             medium.tymed == TYMED_HGLOBAL) {
    log.Writef(L"    value(W)=\"%ls\"", GlobalStringW(medium.hGlobal).c_str());
  } else if ((name == L"FileName" || name == L"UniformResourceLocator") &&
             medium.tymed == TYMED_HGLOBAL) {
    log.Writef(L"    value(A)=\"%ls\"", GlobalStringA(medium.hGlobal).c_str());
  } else if (name == L"FileGroupDescriptorW" && medium.tymed == TYMED_HGLOBAL) {
    LogFileGroupDescriptorW(log, medium.hGlobal);
  } else if (name == L"FileGroupDescriptor" && medium.tymed == TYMED_HGLOBAL) {
    LogFileGroupDescriptorA(log, medium.hGlobal);
  } else if (name == L"Shell IDList Array" && medium.tymed == TYMED_HGLOBAL) {
    LogShellIdList(log, medium.hGlobal);
  } else if (medium.tymed == TYMED_HGLOBAL) {
    log.Writef(L"    HGLOBAL bytes=%llu raw=%ls",
               static_cast<unsigned long long>(GlobalSize(medium.hGlobal)),
               HexPreview(medium.hGlobal).c_str());
  } else if (medium.tymed == TYMED_ISTREAM && medium.pstm) {
    STATSTG stat{};
    const HRESULT hr = medium.pstm->Stat(&stat, STATFLAG_NONAME);
    log.Writef(L"    IStream::Stat=%ls size=%llu", HResultText(hr).c_str(),
               SUCCEEDED(hr) ? stat.cbSize.QuadPart : 0);
  } else if (medium.tymed == TYMED_ISTORAGE && medium.pstg) {
    STATSTG stat{};
    const HRESULT hr = medium.pstg->Stat(&stat, STATFLAG_NONAME);
    log.Writef(L"    IStorage::Stat=%ls", HResultText(hr).c_str());
  }
}

}  // namespace

Logger::Logger(const std::wstring& path) : path_(path) {
  InitializeCriticalSection(&lock_);
  std::error_code error;
  const std::filesystem::path file_path(path);
  if (file_path.has_parent_path()) {
    std::filesystem::create_directories(file_path.parent_path(), error);
  }
  file_ = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file_ != INVALID_HANDLE_VALUE) {
    const BYTE bom[] = {0xEF, 0xBB, 0xBF};
    DWORD written = 0;
    WriteFile(file_, bom, sizeof(bom), &written, nullptr);
  }
}

Logger::~Logger() {
  if (file_ != INVALID_HANDLE_VALUE) CloseHandle(file_);
  DeleteCriticalSection(&lock_);
}

bool Logger::ok() const { return file_ != INVALID_HANDLE_VALUE; }

const std::wstring& Logger::path() const { return path_; }

void Logger::Write(const std::wstring& message) {
  SYSTEMTIME time{};
  GetLocalTime(&time);
  wchar_t prefix[64]{};
  swprintf_s(prefix, L"[%04u-%02u-%02u %02u:%02u:%02u.%03u] ", time.wYear,
             time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond,
             time.wMilliseconds);
  const std::string bytes = WideToUtf8(std::wstring(prefix) + message + L"\r\n");
  EnterCriticalSection(&lock_);
  if (file_ != INVALID_HANDLE_VALUE) {
    DWORD written = 0;
    WriteFile(file_, bytes.data(), static_cast<DWORD>(bytes.size()), &written,
              nullptr);
    FlushFileBuffers(file_);
  }
  LeaveCriticalSection(&lock_);
}

void Logger::Writef(const wchar_t* format, ...) {
  va_list args;
  va_start(args, format);
  va_list copy;
  va_copy(copy, args);
  const int length = _vscwprintf(format, copy);
  va_end(copy);
  std::wstring message(length > 0 ? length + 1 : 0, L'\0');
  if (length > 0) {
    vswprintf_s(message.data(), message.size(), format, args);
    message.resize(length);
  }
  va_end(args);
  Write(message);
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                       static_cast<int>(value.size()), nullptr, 0,
                                       nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring TimestampForFile() {
  SYSTEMTIME time{};
  GetLocalTime(&time);
  wchar_t result[32]{};
  swprintf_s(result, L"%04u%02u%02u-%02u%02u%02u", time.wYear, time.wMonth,
             time.wDay, time.wHour, time.wMinute, time.wSecond);
  return result;
}

std::wstring ClipboardFormatName(CLIPFORMAT format) {
  switch (format) {
    case CF_TEXT:
      return L"CF_TEXT";
    case CF_BITMAP:
      return L"CF_BITMAP";
    case CF_METAFILEPICT:
      return L"CF_METAFILEPICT";
    case CF_SYLK:
      return L"CF_SYLK";
    case CF_DIF:
      return L"CF_DIF";
    case CF_TIFF:
      return L"CF_TIFF";
    case CF_OEMTEXT:
      return L"CF_OEMTEXT";
    case CF_DIB:
      return L"CF_DIB";
    case CF_PALETTE:
      return L"CF_PALETTE";
    case CF_PENDATA:
      return L"CF_PENDATA";
    case CF_RIFF:
      return L"CF_RIFF";
    case CF_WAVE:
      return L"CF_WAVE";
    case CF_UNICODETEXT:
      return L"CF_UNICODETEXT";
    case CF_ENHMETAFILE:
      return L"CF_ENHMETAFILE";
    case CF_HDROP:
      return L"CF_HDROP";
    case CF_LOCALE:
      return L"CF_LOCALE";
    case CF_DIBV5:
      return L"CF_DIBV5";
    default:
      break;
  }
  wchar_t name[256]{};
  const int length = GetClipboardFormatNameW(format, name, 256);
  if (length > 0) return std::wstring(name, length);
  return L"<unnamed>";
}

std::wstring FormatEtcText(const FORMATETC& format) {
  std::wostringstream out;
  out << L"cf=" << format.cfFormat << L" ("
      << ClipboardFormatName(format.cfFormat) << L") tymed="
      << HexValue(format.tymed, 8) << L" (" << TymedText(format.tymed)
      << L") aspect=" << HexValue(format.dwAspect, 8) << L" ("
      << AspectText(format.dwAspect) << L") lindex=" << format.lindex
      << L" ptd=" << format.ptd;
  return out.str();
}

std::wstring HResultText(HRESULT result) {
  LPWSTR buffer = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, result, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  std::wstring message;
  if (length && buffer) {
    message.assign(buffer, length);
    while (!message.empty() &&
           (message.back() == L'\r' || message.back() == L'\n' ||
            message.back() == L' ')) {
      message.pop_back();
    }
    LocalFree(buffer);
  }
  return HexValue(static_cast<unsigned long>(result), 8) +
         (message.empty() ? L"" : L" (" + message + L")");
}

std::wstring DropEffectText(DWORD effect) {
  return JoinBits(effect, {{DROPEFFECT_COPY, L"COPY"},
                           {DROPEFFECT_MOVE, L"MOVE"},
                           {DROPEFFECT_LINK, L"LINK"},
                           {DROPEFFECT_SCROLL, L"SCROLL"}});
}

void LogDataObjectSnapshot(Logger& log, IDataObject* data_object,
                           const std::wstring& stage) {
  log.Write(L"=== IDataObject snapshot: " + stage + L" ===");
  if (!data_object) {
    log.Write(L"  dataObject=<null>");
    return;
  }
  IEnumFORMATETC* enumerator = nullptr;
  const HRESULT enum_hr =
      data_object->EnumFormatEtc(DATADIR_GET, &enumerator);
  log.Writef(L"  EnumFormatEtc(DATADIR_GET) -> %ls",
             HResultText(enum_hr).c_str());
  if (FAILED(enum_hr) || !enumerator) return;

  ULONG index = 0;
  FORMATETC format{};
  ULONG fetched = 0;
  while (enumerator->Next(1, &format, &fetched) == S_OK && fetched == 1) {
    log.Writef(L"  [%lu] %ls", index, FormatEtcText(format).c_str());
    const HRESULT query_hr = data_object->QueryGetData(&format);
    log.Writef(L"    QueryGetData -> %ls", HResultText(query_hr).c_str());
    STGMEDIUM medium{};
    const HRESULT get_hr = data_object->GetData(&format, &medium);
    log.Writef(L"    GetData -> %ls; medium.tymed=%ls",
               HResultText(get_hr).c_str(), TymedText(medium.tymed).c_str());
    if (SUCCEEDED(get_hr)) {
      LogKnownData(log, format.cfFormat,
                   ClipboardFormatName(format.cfFormat), medium);
      ReleaseStgMedium(&medium);
    }
    if (format.ptd) CoTaskMemFree(format.ptd);
    format = {};
    fetched = 0;
    ++index;
  }
  log.Writef(L"  formatCount=%lu", index);
  enumerator->Release();
}

}  // namespace dnd
