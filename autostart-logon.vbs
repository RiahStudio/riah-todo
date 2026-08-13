' Riah To-Do — silent logon start (tray by the clock).
' Safe to re-run; tray script should no-op / replace cleanly.
Option Explicit
Dim fso, sh, dir, script, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = dir
script = dir & "\tray\tray-hidden.vbs"
If fso.FileExists(script) Then
  sh.Run "wscript.exe //B //Nologo """ & script & """", 0, False
End If
