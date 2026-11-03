; OTTO Lite 单根目录 NSIS 安装包。
; 用户只选安装根；安装器只写 <根>\app，绝不创建、读取或覆盖 data/cache。

!ifndef VERSION
  !error "缺少 /DVERSION=<x.y.z>"
!endif
!ifndef SOURCE_DIR
  !error "缺少 /DSOURCE_DIR=<含 otto-lite.exe 与 README.txt 的目录>"
!endif
!ifndef OUT_FILE
  !error "缺少 /DOUT_FILE=<输出 setup.exe>"
!endif

Unicode true
SetCompressor /SOLID lzma
Name "OTTO Lite ${VERSION}"
BrandingText "OTTO Lite ${VERSION}"
OutFile "${OUT_FILE}"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\OTTO Lite"
!define APP_KEY "Software\OTTO\OTTO Lite"
InstallDir "$LOCALAPPDATA\Programs\OTTO"
InstallDirRegKey HKCU "${APP_KEY}" "InstallDir"
RequestExecutionLevel user

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "nsDialogs.nsh"

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName" "OTTO Lite"
VIAddVersionKey /LANG=2052 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "FileDescription" "OTTO Lite 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${VERSION}.0"
VIAddVersionKey /LANG=2052 "CompanyName" "CandaceZcc"
VIAddVersionKey /LANG=2052 "LegalCopyright" "MIT License"
VIAddVersionKey /LANG=2052 "OriginalFilename" "otto-lite-${VERSION}-setup.exe"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\app\otto-lite.exe"
!define MUI_FINISHPAGE_RUN_TEXT "$(OTTO_RUN_TEXT)"
!define MUI_UNCONFIRMPAGE_TEXT_TOP "$(OTTO_UNCONFIRM_TOP)"
!define MUI_UNFINISHPAGE_TEXT "$(OTTO_UNINSTALL_DONE)"
!ifdef ICON_FILE
  !define MUI_ICON "${ICON_FILE}"
  !define MUI_UNICON "${ICON_FILE}"
!endif

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
UninstPage custom un.OttoOptionsPage un.OttoOptionsLeave
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

LangString OTTO_RUN_TEXT ${LANG_SIMPCHINESE} "运行 OTTO Lite"
LangString OTTO_RUN_TEXT ${LANG_ENGLISH} "Run OTTO Lite"
LangString OTTO_UNCONFIRM_TOP ${LANG_SIMPCHINESE} \
  "下一步可选择清理范围。默认只删除主程序；配置、素材库与缓存都会保留。"
LangString OTTO_UNCONFIRM_TOP ${LANG_ENGLISH} \
  "Choose the cleanup scope next. By default only the app is removed; data and cache stay."
LangString OTTO_UNINSTALL_DONE ${LANG_SIMPCHINESE} \
  "OTTO Lite 已按你选择的范围卸载。未勾选的数据与缓存未被删除。"
LangString OTTO_UNINSTALL_DONE ${LANG_ENGLISH} \
  "OTTO Lite was removed using your selected scope. Unselected data and cache were kept."
LangString OTTO_UN_OPTIONS_TEXT ${LANG_SIMPCHINESE} \
  "选择卸载范围。主程序固定勾选；data 与 cache 默认保留。"
LangString OTTO_UN_OPTIONS_TEXT ${LANG_ENGLISH} \
  "Select a cleanup scope. The app is required; data and cache are kept by default."
LangString OTTO_UN_MAIN ${LANG_SIMPCHINESE} "主程序（app，默认）"
LangString OTTO_UN_MAIN ${LANG_ENGLISH} "Application (app, default)"
LangString OTTO_UN_DATA ${LANG_SIMPCHINESE} "配置与素材库（data，默认保留）"
LangString OTTO_UN_DATA ${LANG_ENGLISH} "Settings and library (data, kept by default)"
LangString OTTO_UN_CACHE ${LANG_SIMPCHINESE} "缓存（cache，默认保留）"
LangString OTTO_UN_CACHE ${LANG_ENGLISH} "Cache (cache, kept by default)"
LangString OTTO_UN_ALL ${LANG_SIMPCHINESE} "全选（需要再次确认）"
LangString OTTO_UN_ALL ${LANG_ENGLISH} "Select all (requires confirmation)"
LangString OTTO_UN_ALL_CONFIRM ${LANG_SIMPCHINESE} \
  "全选会永久删除配置、素材库和缓存，且无法撤销。确定继续吗？"
LangString OTTO_UN_ALL_CONFIRM ${LANG_ENGLISH} \
  "Select all permanently deletes settings, the library, and cache. Continue?"

!include "installer-uninstall.nsh"

Section "OTTO Lite" SecMain
  SectionIn RO
  SetShellVarContext current
  SetRegView 64

  ; app 是可整体替换的资产；data/cache 没有任何安装器指令指向它们。
  RMDir /r "$INSTDIR\app"
  SetOutPath "$INSTDIR\app"
  File "${SOURCE_DIR}\otto-lite.exe"
  File "${SOURCE_DIR}\otto-thumb-host.exe"
  File "${SOURCE_DIR}\README.txt"
!ifdef LICENSE_FILE
  File "${LICENSE_FILE}"
!endif
  WriteUninstaller "$INSTDIR\app\Uninstall.exe"

!ifndef OTTO_TEST
  CreateDirectory "$SMPROGRAMS\OTTO Lite"
  CreateShortcut "$SMPROGRAMS\OTTO Lite\OTTO Lite.lnk" "$INSTDIR\app\otto-lite.exe"
  CreateShortcut "$SMPROGRAMS\OTTO Lite\Uninstall OTTO Lite.lnk" "$INSTDIR\app\Uninstall.exe"
  CreateShortcut "$DESKTOP\OTTO Lite.lnk" "$INSTDIR\app\otto-lite.exe"

  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "OTTO Lite"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "CandaceZcc"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\app\otto-lite.exe,0"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\app\Uninstall.exe"'
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\app\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  WriteRegStr HKCU "${APP_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${APP_KEY}" "Version" "${VERSION}"
!endif
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  SetRegView 64
  SetOutPath "$TEMP"

  ; /S 下两个变量在 un.onInit 固定为 0，所以这里只删除 app。
  ; NSIS 的卸载器自删除由 Delete 触发；仅 RMDir /r 会留下正在运行的 Uninstall.exe。
  Delete "$OttoRoot\app\Uninstall.exe"
  RMDir /r "$OttoRoot\app"
  ${If} $OttoCleanData == "1"
    RMDir /r "$OttoRoot\data"
  ${EndIf}
  ${If} $OttoCleanCache == "1"
    RMDir /r "$OttoRoot\cache"
  ${EndIf}
  ; 根里可能有用户自己的文件：只尝试移除空根，不递归删除整个根。
  RMDir "$OttoRoot"

!ifndef OTTO_TEST
  Delete "$SMPROGRAMS\OTTO Lite\OTTO Lite.lnk"
  Delete "$SMPROGRAMS\OTTO Lite\Uninstall OTTO Lite.lnk"
  RMDir "$SMPROGRAMS\OTTO Lite"
  Delete "$DESKTOP\OTTO Lite.lnk"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "${APP_KEY}"
!endif
SectionEnd
