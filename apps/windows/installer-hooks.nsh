; Uninstalling Dango also takes away its two login items (src/autostart.rs);
; an update (which runs the old uninstaller first) keeps them. The data in
; %USERPROFILE%\.dango stays, as on a Mac.
!macro NSIS_HOOK_POSTUNINSTALL
  ${If} $UpdateMode <> 1
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Dango"
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Dango Daemon"
  ${EndIf}
!macroend
