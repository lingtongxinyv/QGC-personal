; ============================================================================
; Custom-QGroundControl Windows NSIS installer
; Based on upstream deploy/windows/nullsoft_installer.nsi with three deltas
; required for side-by-side coexistence with stock QGroundControl:
;
;  1. Uninstall removes ONLY this app's own data (Custom-QGroundControl*.ini
;     and its %LOCALAPPDATA% app-data dir). Upstream deletes the whole shared
;     %APPDATA%\%ORGNAME% tree, which would wipe stock QGC settings too.
;  2. Bundled VC++ x64 runtime (bin\vc_redist.x64.exe) is installed silently
;     when absent, so the package is self-contained on clean machines.
;  3. Adds Simplified Chinese installer language.
;
; The app identity itself (APPNAME/EXENAME = Custom-QGroundControl) already
; differs from stock QGroundControl in: install dir, Start Menu folder,
; ARP uninstall key, WER LocalDumps key and RunGuard single-instance key.
; ============================================================================

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "Win\COM.nsh"
!include "Win\Propkey.nsh"
!include "FileFunc.nsh"

RequestExecutionLevel admin

!macro DemoteShortCut target
    !insertmacro ComHlpr_CreateInProcInstance ${CLSID_ShellLink} ${IID_IShellLink} r0 ""
    ${If} $0 <> 0
        ${IUnknown::QueryInterface} $0 '("${IID_IPersistFile}",.r1)'
        ${If} $1 P<> 0
            ${IPersistFile::Load} $1 '("${target}",1)'
            ${IUnknown::Release} $1 ""
        ${EndIf}
        ${IUnknown::QueryInterface} $0 '("${IID_IPropertyStore}",.r1)'
        ${If} $1 P<> 0
            System::Call '*${SYSSTRUCT_PROPERTYKEY}(${PKEY_AppUserModel_StartPinOption})p.r2'
            System::Call '*${SYSSTRUCT_PROPVARIANT}(${VT_UI4},,&i4 ${APPUSERMODEL_STARTPINOPTION_NOPINONINSTALL})p.r3'
            ${IPropertyStore::SetValue} $1 '($2,$3)'

            System::Call '*$2${SYSSTRUCT_PROPERTYKEY}(${PKEY_AppUserModel_ExcludeFromShowInNewInstall})'
            System::Call '*$3${SYSSTRUCT_PROPVARIANT}(${VT_BOOL},,&i2 ${VARIANT_TRUE})'
            ${IPropertyStore::SetValue} $1 '($2,$3)'

            System::Free $2
            System::Free $3
            ${IPropertyStore::Commit} $1 ""
            ${IUnknown::Release} $1 ""
        ${EndIf}
        ${IUnknown::QueryInterface} $0 '("${IID_IPersistFile}",.r1)'
        ${If} $1 P<> 0
            ${IPersistFile::Save} $1 '("${target}",1)'
            ${IUnknown::Release} $1 ""
        ${EndIf}
        ${IUnknown::Release} $0 ""
    ${EndIf}
!macroend

Name "${APPNAME}"
Var StartMenuFolder

InstallDir "$PROGRAMFILES64\${APPNAME}"
SetCompressor /SOLID /FINAL lzma

!define MUI_HEADERIMAGE
!define MUI_HEADERIMAGE_BITMAP "${HEADER_BITMAP}"
!define MUI_ICON "${INSTALLER_ICON}"
!define MUI_UNICON "${INSTALLER_ICON}"

!insertmacro MUI_PAGE_STARTMENU Application $StartMenuFolder
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "Install" SecMain
    SectionIn RO
    DetailPrint "Checking for 64 bit uninstaller"
    SetRegView 64
    ReadRegStr $R0 HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "UninstallString"
    StrCmp $R0 "" doInstall checkUninstaller

checkUninstaller:
    ; Remove quotes from uninstaller path to check if file exists
    StrCpy $R1 $R0 "" 1  ; Skip first quote
    StrLen $R2 $R1
    IntOp $R2 $R2 - 1    ; Remove last quote
    StrCpy $R1 $R1 $R2

    DetailPrint "Checking if uninstaller exists: $R1"
    IfFileExists "$R1" doUninstall cleanupOrphanedRegistry

cleanupOrphanedRegistry:
    DetailPrint "Previous uninstaller not found, cleaning up orphaned registry keys..."
    SetRegView 64
    DeleteRegKey HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
    DeleteRegKey HKLM "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\${EXENAME}.exe"
    Goto doInstall

doUninstall:
    DetailPrint "Uninstalling previous version..."
    ClearErrors
    ExecWait "$R0 /S -LEAVE_DATA=1 _?=$INSTDIR"
    ${If} ${Errors}
        MessageBox MB_OK|MB_ICONEXCLAMATION "Failed to start previous uninstaller."
        Abort
    ${EndIf}
    IntCmp $0 0 doInstall
    MessageBox MB_OK|MB_ICONEXCLAMATION "Could not remove a previously installed ${APPNAME} version.$\n$\nPlease remove it before continuing."
    Abort

doInstall:
    SetRegView 64
    SetOutPath $INSTDIR
    ; Install payload (skip dev-only artifacts)
    File /r /x ${EXENAME}.pdb /x ${EXENAME}.lib /x ${EXENAME}.exp /x qgc-run.err.log /x qgc-run.out.log ${DESTDIR}\*.*

    ; Bundled VC++ x64 runtime: install silently when not already present so the
    ; package runs on clean machines. vc_redist is idempotent; exit 1638 (newer
    ; version present) is also fine, so no exit-code check.
    ClearErrors
    ReadRegDWORD $0 HKLM "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" "Installed"
    ${If} ${Errors}
    ${OrIf} $0 != 1
        DetailPrint "Installing VC++ runtime..."
        SetOutPath $INSTDIR\bin
        ExecWait '"$INSTDIR\bin\vc_redist.x64.exe" /install /quiet /norestart'
    ${EndIf}

    ; Create uninstaller and ARP data
    WriteUninstaller "$INSTDIR\${EXENAME}-Uninstall.exe"
    WriteRegStr   HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayName"    "${APPNAME}"
    WriteRegStr   HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "UninstallString" "$\"$INSTDIR\${EXENAME}-Uninstall.exe$\""
    WriteRegStr   HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayIcon"     "$INSTDIR\bin\${EXENAME}.exe"
    WriteRegStr   HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "InstallLocation" "$INSTDIR"
    WriteRegDWORD HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "NoModify" 1
    WriteRegDWORD HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "NoRepair" 1
    !ifdef ORGNAME
        WriteRegStr HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "Publisher" "${ORGNAME}"
    !endif
    !ifdef APPVERSION
        WriteRegStr HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}" "DisplayVersion" "${APPVERSION}"
    !endif

    ; WER dumps for crash triage
    WriteRegDWORD    HKLM "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\${EXENAME}.exe" "DumpCount" 5
    WriteRegDWORD    HKLM "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\${EXENAME}.exe" "DumpType" 1
    WriteRegExpandStr HKLM "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\${EXENAME}.exe" "DumpFolder" "%LOCALAPPDATA%\QGCCrashDumps"

done:
    SetRegView lastused
SectionEnd

Section "Uninstall"
    SetRegView 64
    ${GetParameters} $R0
    ${GetOptions} $R0 "-LEAVE_DATA=" $R1
    !insertmacro MUI_STARTMENU_GETFOLDER Application $StartMenuFolder

    ; Remove files and shortcuts
    SetShellVarContext all
    RMDir /r /REBOOTOK "$INSTDIR"
    RMDir /r /REBOOTOK "$SMPROGRAMS\$StartMenuFolder\"
    SetShellVarContext current

    ${If} $R1 != 1
        ; Coexistence fix: stock QGC shares the %APPDATA%\${ORGNAME} tree, so
        ; only remove THIS app's own settings and per-user app data.
        Delete "$APPDATA\${ORGNAME}\${EXENAME}*.ini"
        ; Long-path safe delete: embedded DSH session dir names encode the
        ; workspace path and can exceed MAX_PATH (260), which plain RMDir /r
        ; cannot remove (fails silently). Mirror an empty dir over the target
        ; (robocopy handles long paths), then rmdir the emptied shell.
        ; /R:1 /W:1 avoids long stalls on locked files.
        CreateDirectory "$TEMP\qgc-robodel"
        nsExec::ExecToLog 'robocopy "$TEMP\qgc-robodel" "$LOCALAPPDATA\${ORGNAME}\${EXENAME}" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP'
        Pop $R2
        nsExec::ExecToLog 'robocopy "$TEMP\qgc-robodel" "$LOCALAPPDATA\${ORGNAME}\${EXENAME} Daily" /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP'
        Pop $R2
        RMDir "$LOCALAPPDATA\${ORGNAME}\${EXENAME}"
        RMDir "$LOCALAPPDATA\${ORGNAME}\${EXENAME} Daily"
        RMDir "$TEMP\qgc-robodel"
    ${EndIf}

    ; Remove ARP + WER
    DeleteRegKey HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APPNAME}"
    DeleteRegKey HKLM "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\${EXENAME}.exe"
SectionEnd

Section "Create Start Menu Shortcuts"
    SetRegView 64
    SetShellVarContext all

    ; Silent installs never show the Start Menu page, so the variable stays
    ; empty; MUI_STARTMENU_WRITE_BEGIN would fill it from the default, but pin
    ; it explicitly so shortcut creation is deterministic in /S mode.
    ${If} $StartMenuFolder == ""
        StrCpy $StartMenuFolder "${APPNAME}"
    ${EndIf}
    CreateDirectory "$SMPROGRAMS\$StartMenuFolder"

    !insertmacro MUI_STARTMENU_WRITE_BEGIN Application
        CreateShortCut "$SMPROGRAMS\$StartMenuFolder\${APPNAME}.lnk" "$INSTDIR\bin\${EXENAME}.exe" "" "$INSTDIR\bin\${EXENAME}.exe" 0
        CreateShortCut "$SMPROGRAMS\$StartMenuFolder\${APPNAME} (GPU Safe Mode).lnk" "$INSTDIR\bin\${EXENAME}.exe" "-swrast" "$INSTDIR\bin\${EXENAME}.exe" 0
        !insertmacro DemoteShortCut "$SMPROGRAMS\$StartMenuFolder\${APPNAME} (GPU Safe Mode).lnk"
    !insertmacro MUI_STARTMENU_WRITE_END
SectionEnd
