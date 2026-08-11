#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <objidl.h>

#include <string>

namespace dnd {

class Logger {
 public:
  explicit Logger(const std::wstring& path);
  ~Logger();

  Logger(const Logger&) = delete;
  Logger& operator=(const Logger&) = delete;

  bool ok() const;
  const std::wstring& path() const;
  void Write(const std::wstring& message);
  void Writef(const wchar_t* format, ...);

 private:
  HANDLE file_ = INVALID_HANDLE_VALUE;
  CRITICAL_SECTION lock_{};
  std::wstring path_;
};

std::wstring Utf8ToWide(const std::string& value);
std::string WideToUtf8(const std::wstring& value);
std::wstring TimestampForFile();
std::wstring ClipboardFormatName(CLIPFORMAT format);
std::wstring FormatEtcText(const FORMATETC& format);
std::wstring HResultText(HRESULT result);
std::wstring DropEffectText(DWORD effect);
void LogDataObjectSnapshot(Logger& log, IDataObject* data_object,
                           const std::wstring& stage);

}  // namespace dnd
