; OTTO 卸载范围页与测试专用的无界面选择入口。
; 生产包没有 OTTO_TEST：/S 永远只删 app，data/cache 只能由选项页明确勾选。

Var OttoRoot
Var OttoCleanData
Var OttoCleanCache
Var OttoOptionsDialog
Var OttoMainCheck
Var OttoDataCheck
Var OttoCacheCheck
Var OttoAllCheck

Function un.onInit
  ; /S 会从临时副本运行，$EXEDIR 不是原安装位置；$INSTDIR 才保存安装根。
  StrCpy $OttoRoot "$INSTDIR"
  ${GetFileName} "$INSTDIR" $0
  ${If} $0 == "app"
    ${GetParent} "$INSTDIR" $OttoRoot
  ${EndIf}
  StrCpy $OttoCleanData "0"
  StrCpy $OttoCleanCache "0"
!ifdef OTTO_TEST
  ; 仅验收构建认识这个参数。生产卸载器不存在命令行清数据入口。
  ${GetOptions} $CMDLINE "/OTTO_TEST_CLEAN=" $0
  StrCmp $0 "data" 0 +3
    StrCpy $OttoCleanData "1"
    Return
  StrCmp $0 "cache" 0 +3
    StrCpy $OttoCleanCache "1"
    Return
  StrCmp $0 "all" 0 +4
    StrCpy $OttoCleanData "1"
    StrCpy $OttoCleanCache "1"
    Return
!endif
FunctionEnd

Function un.OttoSelectAll
  ${NSD_GetState} $OttoAllCheck $0
  ${If} $0 == ${BST_CHECKED}
    ${NSD_Check} $OttoMainCheck
    ${NSD_Check} $OttoDataCheck
    ${NSD_Check} $OttoCacheCheck
  ${Else}
    ${NSD_Uncheck} $OttoDataCheck
    ${NSD_Uncheck} $OttoCacheCheck
  ${EndIf}
FunctionEnd

Function un.OttoOptionsPage
  ; 双保险：静默卸载即使页面序列变化也不会创建对话框。
  ${If} ${Silent}
    Abort
  ${EndIf}

  nsDialogs::Create 1018
  Pop $OttoOptionsDialog
  ${If} $OttoOptionsDialog == error
    Abort
  ${EndIf}

  ${NSD_CreateLabel} 0 0 100% 24u "$(OTTO_UN_OPTIONS_TEXT)"
  ${NSD_CreateCheckbox} 0 34u 100% 12u "$(OTTO_UN_MAIN)"
  Pop $OttoMainCheck
  ${NSD_Check} $OttoMainCheck
  ; 卸载必须有主程序这一项；数据范围才是用户可选部分。
  EnableWindow $OttoMainCheck 0

  ${NSD_CreateCheckbox} 0 52u 100% 20u "$(OTTO_UN_DATA)"
  Pop $OttoDataCheck
  ${NSD_Uncheck} $OttoDataCheck
  ${NSD_CreateCheckbox} 0 78u 100% 20u "$(OTTO_UN_CACHE)"
  Pop $OttoCacheCheck
  ${NSD_Uncheck} $OttoCacheCheck
  ${NSD_CreateCheckbox} 0 104u 100% 16u "$(OTTO_UN_ALL)"
  Pop $OttoAllCheck
  ${NSD_Uncheck} $OttoAllCheck
  ${NSD_OnClick} $OttoAllCheck un.OttoSelectAll
  nsDialogs::Show
FunctionEnd

Function un.OttoOptionsLeave
  ${NSD_GetState} $OttoDataCheck $0
  StrCpy $OttoCleanData "0"
  ${If} $0 == ${BST_CHECKED}
    StrCpy $OttoCleanData "1"
  ${EndIf}
  ${NSD_GetState} $OttoCacheCheck $0
  StrCpy $OttoCleanCache "0"
  ${If} $0 == ${BST_CHECKED}
    StrCpy $OttoCleanCache "1"
  ${EndIf}

  ${NSD_GetState} $OttoAllCheck $0
  ${If} $0 == ${BST_CHECKED}
    ; 全选是破坏性操作，必须再确认；静默模式有安全默认值，绝不等待。
    MessageBox MB_YESNO|MB_ICONEXCLAMATION "$(OTTO_UN_ALL_CONFIRM)" /SD IDNO IDNO OttoCancelAll
    Goto OttoAllConfirmed
    OttoCancelAll:
      Abort
    OttoAllConfirmed:
  ${EndIf}
FunctionEnd
