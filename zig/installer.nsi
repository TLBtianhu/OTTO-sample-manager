; OTTO Lite 的 NSIS 安装包脚本。
;
; 由 `package.ps1` 调用，版本号与所有路径都从命令行 /D 传入，脚本里没有第二份副本：
;
;   makensis /DVERSION=<x.y.z> /DSOURCE_DIR=<exe + README> /DOUT_FILE=<setup.exe> \
;            /DICON_FILE=<resources/icon.ico> /DLICENSE_FILE=<LICENSE> installer.nsi
;
; 规矩（CHARTER 九）：
;   * 程序装进 $PROGRAMFILES64\OTTO Lite，**安装目录不写任何数据**；
;   * 用户数据在 %APPDATA%\OTTO，卸载时保留（确认页与完成页都会说明）；
;   * 不生成 otto-portable.flag——安装版不是便携版，标记只在便携 zip 里。

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
InstallDir "$PROGRAMFILES64\OTTO Lite"
RequestExecutionLevel admin

!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\OTTO Lite"
!define APP_KEY "Software\OTTO\OTTO Lite"

!include "MUI2.nsh"
!include "LogicLib.nsh"

; 版本资源：装出来的 setup.exe 在资源管理器属性里也能看到版本。
VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName" "OTTO Lite"
VIAddVersionKey /LANG=2052 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "FileDescription" "OTTO Lite 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${VERSION}.0"
VIAddVersionKey /LANG=2052 "CompanyName" "CandaceZcc"
VIAddVersionKey /LANG=2052 "LegalCopyright" "MIT License"
VIAddVersionKey /LANG=2052 "OriginalFilename" "otto-lite-${VERSION}-setup.exe"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\otto-lite.exe"
!define MUI_FINISHPAGE_RUN_TEXT "$(OTTO_RUN_TEXT)"

; 卸载确认页：这里就说清楚"数据会保留"，而不是卸完才让用户找。
!define MUI_UNCONFIRMPAGE_TEXT_TOP "$(OTTO_UNCONFIRM_TOP)"

!ifdef ICON_FILE
  !define MUI_ICON "${ICON_FILE}"
  !define MUI_UNICON "${ICON_FILE}"
!endif

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
; 卸载完成页也说明一次：程序没了，库还在。
!define MUI_FINISHPAGE_TEXT "$(OTTO_UNINSTALL_DONE)"
!insertmacro MUI_UNPAGE_FINISH

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

LangString OTTO_RUN_TEXT ${LANG_SIMPCHINESE} "运行 OTTO Lite"
LangString OTTO_RUN_TEXT ${LANG_ENGLISH} "Run OTTO Lite"

LangString OTTO_UNCONFIRM_TOP ${LANG_SIMPCHINESE} \
  "将删除 OTTO Lite 的程序文件与快捷方式。$\r$\n$\r$\n用户数据（库、分组、标签）保留在 %APPDATA%\OTTO，不会被删除；如需彻底清理，请在卸载后手动删除该目录。"
LangString OTTO_UNCONFIRM_TOP ${LANG_ENGLISH} \
  "OTTO Lite's program files and shortcuts will be removed.$\r$\n$\r$\nYour user data (library, groups, tags) stays in %APPDATA%\OTTO and is not deleted. Delete that folder manually for a clean wipe."

LangString OTTO_UNINSTALL_DONE ${LANG_SIMPCHINESE} \
  "OTTO Lite 已卸载。$\r$\n$\r$\n用户数据仍保留在 %APPDATA%\OTTO。"
LangString OTTO_UNINSTALL_DONE ${LANG_ENGLISH} \
  "OTTO Lite has been removed.$\r$\n$\r$\nYour user data is still in %APPDATA%\OTTO."

Section "OTTO Lite" SecMain
  SectionIn RO
  SetShellVarContext all
  SetRegView 64

  ; 程序文件。安装目录只放可执行文件与说明/许可证，不创建 data\。
  SetOutPath "$INSTDIR"
  File "${SOURCE_DIR}\otto-lite.exe"
  File "${SOURCE_DIR}\otto-thumb-host.exe"
  File "${SOURCE_DIR}\README.txt"
!ifdef LICENSE_FILE
  File "${LICENSE_FILE}"
!endif
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; 开始菜单 + 桌面快捷方式（所有用户；安装需要管理员，和 Program Files 一致）。
  CreateDirectory "$SMPROGRAMS\OTTO Lite"
  CreateShortcut "$SMPROGRAMS\OTTO Lite\OTTO Lite.lnk" "$INSTDIR\otto-lite.exe"
  CreateShortcut "$SMPROGRAMS\OTTO Lite\Uninstall OTTO Lite.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\OTTO Lite.lnk" "$INSTDIR\otto-lite.exe"

  ; 控制面板"程序和功能"里的卸载项；DisplayVersion 必须与 exe 的 --version 一致。
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "OTTO Lite"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "CandaceZcc"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\otto-lite.exe,0"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1

  ; 供安装程序下次记住目录（InstallDir 不用 InstallDirRegKey：那是默认视图）。
  WriteRegStr HKLM "${APP_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${APP_KEY}" "Version" "${VERSION}"
SectionEnd

Section "Uninstall"
  SetShellVarContext all
  SetRegView 64

  ; 先删程序和快捷方式；安装目录里没有用户数据。
  Delete "$INSTDIR\otto-thumb-host.exe"
  Delete "$INSTDIR\otto-lite.exe"
  Delete "$INSTDIR\README.txt"
!ifdef LICENSE_FILE
  Delete "$INSTDIR\LICENSE"
!endif
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\OTTO Lite\OTTO Lite.lnk"
  Delete "$SMPROGRAMS\OTTO Lite\Uninstall OTTO Lite.lnk"
  RMDir "$SMPROGRAMS\OTTO Lite"
  Delete "$DESKTOP\OTTO Lite.lnk"

  DeleteRegKey HKLM "${UNINST_KEY}"
  DeleteRegKey HKLM "${APP_KEY}"

  ; 刻意不碰 %APPDATA%\OTTO：用户数据不随卸载消失（CHARTER 九）。
  ; 这里没有 Delete/ RMDir 指向 $APPDATA，请不要"顺手补上"。
SectionEnd
