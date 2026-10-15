Option Explicit

Dim shell, files, environment, scriptDirectory, powershell, commandLine, argument, result
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
Set environment = shell.Environment("PROCESS")
scriptDirectory = files.GetParentFolderName(WScript.ScriptFullName)
shell.CurrentDirectory = scriptDirectory
powershell = FindPowerShell()

If Len(powershell) = 0 Then
    MsgBox "PowerShell 7 was not found. Install PowerShell 7 or use the Codex bundled runtime.", vbExclamation, "Balance Pet"
    WScript.Quit 1
End If

commandLine = QuoteArgument(powershell) & " -NoProfile -NonInteractive -WindowStyle Hidden -File " & QuoteArgument(files.BuildPath(scriptDirectory, "start-pet.ps1"))
For Each argument In WScript.Arguments
    commandLine = commandLine & " " & QuoteArgument(CStr(argument))
Next

' Run directly invokes PowerShell, without cmd.exe or shell evaluation.
' ExpandEnvironmentStrings performs one pass: this indirection also preserves
' literal percent expressions in paths/arguments instead of expanding them.
environment("BALANCE_PET_VBS_COMMAND") = commandLine
result = shell.Run("%BALANCE_PET_VBS_COMMAND%", 0, True)
environment.Remove "BALANCE_PET_VBS_COMMAND"
WScript.Quit result

Function FindPowerShell()
    Dim candidate, directory, paths
    FindPowerShell = ""
    candidate = files.BuildPath(environment("USERPROFILE"), ".cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe")
    If files.FileExists(candidate) Then
        FindPowerShell = candidate
        Exit Function
    End If
    For Each directory In Array(environment("ProgramW6432"), environment("ProgramFiles"))
        If Len(directory) > 0 Then
            candidate = files.BuildPath(directory, "PowerShell\7\pwsh.exe")
            If files.FileExists(candidate) Then
                FindPowerShell = candidate
                Exit Function
            End If
        End If
    Next
    paths = Split(environment("PATH"), ";")
    For Each directory In paths
        directory = Trim(directory)
        If Left(directory, 1) = Chr(34) And Right(directory, 1) = Chr(34) Then
            directory = Mid(directory, 2, Len(directory) - 2)
        End If
        If Len(directory) > 0 Then
            candidate = files.BuildPath(shell.ExpandEnvironmentStrings(directory), "pwsh.exe")
            If files.FileExists(candidate) Then
                FindPowerShell = candidate
                Exit Function
            End If
        End If
    Next
End Function

' Windows argv quoting: escape quotes and the backslashes immediately before
' them, and double trailing backslashes before the closing quote.
Function QuoteArgument(value)
    Dim quoted, index, character, backslashes
    quoted = Chr(34)
    backslashes = 0
    For index = 1 To Len(value)
        character = Mid(value, index, 1)
        If character = "\" Then
            backslashes = backslashes + 1
        ElseIf character = Chr(34) Then
            quoted = quoted & String(backslashes * 2 + 1, "\") & Chr(34)
            backslashes = 0
        Else
            quoted = quoted & String(backslashes, "\") & character
            backslashes = 0
        End If
    Next
    QuoteArgument = quoted & String(backslashes * 2, "\") & Chr(34)
End Function
