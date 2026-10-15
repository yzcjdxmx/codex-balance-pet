@echo off
setlocal
rem Compatibility entry. Double-click the matching .vbs for no console window.
"%SystemRoot%\System32\wscript.exe" //nologo "%~dpn0.vbs" %*
endlocal
