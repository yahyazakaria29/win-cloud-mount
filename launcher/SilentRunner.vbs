' =========================================================================
' WinCloudMount - Silent Background Launcher (VBScript)
' Runs PowerShell Mount-Manager without flashing CMD or console windows.
' =========================================================================

Option Explicit

Dim objShell, objFSO, strScriptDir, strProjectRoot, strPsScript, strCommand

Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")

' Resolve relative paths
strScriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
strProjectRoot = objFSO.GetParentFolderName(strScriptDir)
strPsScript = objFSO.BuildPath(strProjectRoot, "scripts\Mount-Manager.ps1")

If Not objFSO.FileExists(strPsScript) Then
    MsgBox "Error: Mount-Manager.ps1 not found at: " & strPsScript, 16, "WinCloudMount Error"
    WScript.Quit 1
End If

' Execute PowerShell in hidden window mode (0 = Hide)
strCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & strPsScript & """ -Action start"
objShell.Run strCommand, 0, False

Set objShell = Nothing
Set objFSO = Nothing
