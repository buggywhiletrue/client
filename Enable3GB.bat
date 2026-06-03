@echo off
setlocal

if defined ProgramW6432 goto exit

if not exist %SystemRoot%\system32\bcdedit.exe goto exit

:withbcdedit
bcdedit /set increaseUserVa 2560

:exit
exit /b