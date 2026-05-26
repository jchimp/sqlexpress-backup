@echo off
REM ------------------------------------------------------------------
REM  Backup-SqlExpressDB.bat
REM  Thin launcher for Windows Task Scheduler.
REM  Points to the JSON config for multi-database backups + email.
REM ------------------------------------------------------------------

SET SCRIPT_PATH=C:\Scripts\Backup-SqlExpressDB.ps1
SET CONFIG_PATH=C:\Scripts\Backup-SqlExpressDB.json

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" ^
    -ConfigFile "%CONFIG_PATH%"
