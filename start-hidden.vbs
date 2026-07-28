' Start the Riah To-Do board with no console window left open.
' The tray note does not need this -- it reads the file directly. This is only
' for the full page.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = dir
cmd = "cmd /c ""set ""PATH=%ProgramFiles%\nodejs;%LocalAppData%\Programs\node;C:\nvm4w\nodejs;%PATH%"" && node server.mjs"""
sh.Run cmd, 0, False
