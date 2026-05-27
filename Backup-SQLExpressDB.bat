@echo off
REM ------------------------------------------------------------------
REM Backup-SqlExpressDB.bat
REM Launcher for Windows Task Scheduler.
REM Points to JSON config and script being in the same folder as this script.
REM If you need to place the .PS1 and .JSON elsewhere, just specify the full path below. 
REM ------------------------------------------------------------------

SET SCRIPT_PATH=%~dp0Backup-SqlExpressDB.ps1
SET CONFIG_PATH=%~dp0Backup-SqlExpressDB.json

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" ^
    -ConfigFile "%CONFIG_PATH%"
