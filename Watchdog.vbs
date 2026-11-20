' Local-only watchdog: no console, no network, no process termination.
' Existing monitor is checked by PID and exact script path before any launch.
Option Explicit
Dim sh, fs, root, data, status, flag, monitor, text, rx, matches, monitorPid, svc, rows, proc, live, stm
Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
root = fs.GetParentFolderName(WScript.ScriptFullName)
data = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\CodexTrafficMonitor"
status = data & "\status.json"
flag = data & "\stop.flag"
monitor = root & "\Monitor.ps1"
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "start" Then
        If fs.FileExists(flag) Then fs.DeleteFile flag, True
    End If
End If
If fs.FileExists(flag) Then WScript.Quit 0
live = False
If fs.FileExists(status) Then
    Set stm = CreateObject("ADODB.Stream")
    stm.Type = 2 : stm.Charset = "utf-8" : stm.Open
    stm.LoadFromFile status : text = stm.ReadText : stm.Close
    Set rx = New RegExp
    rx.Pattern = """pid""\s*:\s*(\d+)"
    Set matches = rx.Execute(text)
    If matches.Count > 0 Then
        monitorPid = CLng(matches(0).SubMatches(0))
        Set svc = GetObject("winmgmts:\\.\root\cimv2")
        Set rows = svc.ExecQuery("SELECT Name,CommandLine FROM Win32_Process WHERE ProcessId=" & monitorPid)
        For Each proc In rows
            If LCase(proc.Name) = "powershell.exe" And Not IsNull(proc.CommandLine) Then
                If InStr(1, proc.CommandLine, monitor, vbTextCompare) > 0 Then live = True
            End If
        Next
    End If
End If
If Not live Then
    sh.Run """" & sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & monitor & """", 0, False
End If
