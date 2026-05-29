<#
.SYNOPSIS
    Backs up SQL Express databases with retention, and email reporting.

.DESCRIPTION
    Reads a JSON config file to back up one or more SQL Express databases using sqlcmd.
    Features: checksum verification, retention cleanup, HTML email report.
    Also supports single-database mode via command-line parameters for one-off runs.
    If Backup-SQLExpressDB.json exists in the same directory as the script, it is loaded automatically.
    Use -DryRun to simulate the entire process without executing sqlcmd or deleting files.

.PARAMETER ConfigFile
    Path to a JSON configuration file defining databases and SMTP settings.
    Default: Backup-SQLExpressDB.json in the same directory as the script.

.PARAMETER DatabaseName
    (Single mode) Name of the database to back up.

.PARAMETER BackupPath
    (Single mode) Folder where .bak files will be stored.

.PARAMETER RetainCount
    Number of most recent backups to keep. Default: 5.

.PARAMETER ServerInstance
    SQL Server instance name. Default: .\SQLEXPRESS

.PARAMETER LogFile
    Optional path to a log file.

.PARAMETER DryRun
    Simulates the backup process without running sqlcmd or deleting files.

.EXAMPLE
    # Auto-detect config file from same folder
    .\Backup-SQLExpressDB.ps1

.EXAMPLE
    # Dry run with auto-detected config file
    .\Backup-SQLExpressDB.ps1 -DryRun

.EXAMPLE
    # Use an explicit config file
    .\Backup-SQLExpressDB.ps1 -ConfigFile "C:\Scripts\Backup-SQLExpressDB.json"

.EXAMPLE
    # Single database mode - parameterized
    .\Backup-SQLExpressDB.ps1 -DatabaseName "WebTrack" -BackupPath "D:\Backups\WebTrack" -RetainCount 7
#>

param(
    [string]$ConfigFile = (Join-Path $PSScriptRoot 'Backup-SQLExpressDB.json'),
    [string]$DatabaseName,
    [string]$BackupPath,
    [int]$RetainCount = 0,
    [string]$ServerInstance = ".\SQLEXPRESS",
    [string]$LogFile,
    [switch]$DryRun
)

#------------------------------------------------------------------------------
# Helpers
#------------------------------------------------------------------------------
function Convert-ToSqlNLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "NULL" }
    return "N'" + ($Value -replace "'", "''") + "'"
}

function Convert-ToSqlBracketIdentifier {
    param([Parameter(Mandatory)][string]$Name)
    return "[" + ($Name -replace "]", "]]") + "]"
}

function Convert-ToSafeFileName {
    param([Parameter(Mandatory)][string]$Name)

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder

    foreach ($ch in $Name.ToCharArray()) {
        if ($invalidChars -contains $ch) {
            [void]$sb.Append('_')
        }
        else {
            [void]$sb.Append($ch)
        }
    }

    return $sb.ToString()
}

function Get-BackupFilesForDatabase {
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$DbFileStem
    )

    if (-not (Test-Path -LiteralPath $BackupPath)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $BackupPath -Filter ("{0}_*.bak" -f $DbFileStem) -File |
        Sort-Object LastWriteTime -Descending)
}

function Get-UserDatabases {
    param([string]$Instance)

    $sql = "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE' AND name NOT IN ('master','tempdb','model','msdb') ORDER BY name;"

    $output = sqlcmd -S $Instance -Q $sql -h -1 -W 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Log "Failed to query databases on $Instance" "ERROR"
        return @()
    }

    # Filter empty lines and return clean array
    return @($output | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Test-JsonConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Config file not found: $Path" "ERROR"
        return $false
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    }
    catch {
        Write-Log "Cannot read config file: $_" "ERROR"
        return $false
    }
    
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Log "Config file is empty: $Path" "ERROR"
        return $false
    }

    try {
        $null = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $errMsg = $_.Exception.Message

        # Try to extract character position and convert to line number
        if ($errMsg -match '\((\d+)\)') {
            $charPos = [int]$Matches[1]
            if ($charPos -le $raw.Length) {
                $upToError  = $raw.Substring(0, [Math]::Min($charPos, $raw.Length))
                $lineNum    = ($upToError | Measure-Object -Line).Lines + 1
                $lineStart  = $upToError.LastIndexOf("`n") + 1
                $colNum     = $charPos - $lineStart + 1
                $errorLine  = ($raw -split "`n")[$lineNum - 1].Trim()

                Write-Log "Invalid JSON in config file:" "ERROR"
                Write-Log "  Line $lineNum, Column $colNum" "ERROR"
                Write-Log "  Content: $errorLine" "ERROR"
                Write-Log "  Error:   $errMsg" "ERROR"
            }
            else {
                Write-Log "Invalid JSON in config file: $errMsg" "ERROR"
            }
        }
        else {
            Write-Log "Invalid JSON in config file: $errMsg" "ERROR"
        }

        return $false
    }

    return $true
}

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
function Rotate-LogFile {
    param(
        [string]$LogPath,
        [int]$KeepCount = 5
    )

    if (-not $LogPath -or -not (Test-Path $LogPath)) {
        return
    }

    # Work backwards: delete oldest, then shift each file up by 1
    # .5 → deleted, .4 → .5, .3 → .4, .2 → .3, .1 → .2, current → .1
    for ($i = $KeepCount; $i -ge 1; $i--) {
        $source = if ($i -eq 1) { $LogPath } else { "${LogPath}.$($i - 1)" }
        $dest   = "${LogPath}.$i"

        if (Test-Path $source) {
            if ($i -eq $KeepCount -and (Test-Path $dest)) {
                Remove-Item $dest -Force
            }
            Rename-Item $source $dest -Force
        }
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")

    $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $tag   = if ($script:DryRunMode) { "[DRY-RUN] " } else { "" }
    $entry = "[$ts] [$Level] ${tag}$Message"

    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        "DRYRUN"  { Write-Host $entry -ForegroundColor Cyan }
        default   { Write-Host $entry }
    }

    if ($script:ActiveLogFile) {
        try {
            $logDir = Split-Path -Path $script:ActiveLogFile -Parent
            if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            $entry | Out-File -FilePath $script:ActiveLogFile -Append -Encoding UTF8
        } catch {
            Write-Host "[$ts] [WARN] Failed to write to log file $script:ActiveLogFile : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

#------------------------------------------------------------------------------
# Retention policy - clean up old backups
#------------------------------------------------------------------------------
function Remove-BackupFileSafely {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 2
    )

    if ($script:DryRunMode) {
        return @{
            Success = $true
            Message = "Dry run - no deletion performed"
        }
    }

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            if (-not (Test-Path -LiteralPath $File.FullName)) {
                return @{
                    Success = $true
                    Message = "File already absent"
                }
            }

            # Refresh file info
            $fileItem = Get-Item -LiteralPath $File.FullName -Force

            # Clear common restrictive attributes if present
            try {
                [System.IO.File]::SetAttributes($fileItem.FullName, [System.IO.FileAttributes]::Normal)
            }
            catch {
                Write-Log "  Attempt $attempt/$RetryCount - Could not reset attributes on $($fileItem.Name): $($_.Exception.Message)" "WARN"
            }

            # Remove file
            Remove-Item -LiteralPath $fileItem.FullName -Force -ErrorAction Stop
            return @{
                Success = $true
                Message = "Deleted successfully"
            }
        }
        catch {
            $msg = $_.Exception.Message
            Write-Log "  Attempt $attempt/$RetryCount - Failed to delete $($File.FullName): $msg" "ERROR"

            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    try {
        $acl = Get-Acl -LiteralPath $File.FullName -ErrorAction Stop
        $owner = $acl.Owner
    }
    catch {
        $owner = "Unavailable"
    }

    return @{
        Success = $false
        Message = "Access denied or file locked after $RetryCount attempts. Owner: $owner"
    }
}

#------------------------------------------------------------------------------
# Backup single database
#------------------------------------------------------------------------------
function Backup-SingleDatabase {
    param(
        [string]$DbName,
        [string]$BkPath,
        [int]$Retain,
        [string]$Instance
    )

    $result = @{
        Database   = $DbName
        Status     = "UNKNOWN"
        BackupFile = ""
        SizeMB     = 0
        Duration   = ""
        Retained   = 0
        Deleted    = 0
        Notes      = ""
    }

    # Check DBName and backup path amd retention
    if ([string]::IsNullOrWhiteSpace($DbName)) {
        $result.Status = "FAILED"
        $result.Notes  = "Database name is blank"
        Write-Log $result.Notes "ERROR"
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($BkPath)) {
        $result.Status = "FAILED"
        $result.Notes  = "Backup path is blank"
        Write-Log $result.Notes "ERROR"
        return $result
    }
    if ($Retain -lt 0) {
        $result.Status = "FAILED"
        $result.Notes  = "Retain count cannot be negative"
        Write-Log $result.Notes "ERROR"
        return $result
    }

    # Get safe DB name
    $dbFileStem = Convert-ToSafeFileName $DbName

    # Check sqlcmd is available
    if (-not $script:DryRunMode -and -not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        $result.Status = "FAILED"
        $result.Notes  = "sqlcmd.exe not found in PATH"
        Write-Log $result.Notes "ERROR"
        return $result
    }

    if ($script:DryRunMode) {
        Write-Log "Would check for sqlcmd in PATH" "DRYRUN"
    }

    # Create backup directory if needed
    if (-not (Test-Path -LiteralPath $BkPath)) {
        if ($script:DryRunMode) {
            Write-Log "Would create directory: $BkPath" "DRYRUN"
        }
        else {
            Write-Log "Creating backup directory: $BkPath"
            try {
                New-Item -ItemType Directory -Path $BkPath -Force | Out-Null
            }
            catch {
                $result.Status = "FAILED"
                $result.Notes  = "Failed to create directory: $($_.Exception.Message)"
                Write-Log $result.Notes "ERROR"
                return $result
            }
        }
    }

    # Safe SQL values
    $dbNameLiteral    = Convert-ToSqlNLiteral $DbName
    $dbNameIdentifier = Convert-ToSqlBracketIdentifier $DbName

    # Verify database exists
    if ($script:DryRunMode) {
        Write-Log "Would verify database [$DbName] exists on $Instance" "DRYRUN"
    } 
    else {
        Write-Log "Verifying database [$DbName] on $Instance ..."
        $checkSql = "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name = $dbNameLiteral;"
        $dbCheck  = sqlcmd -S $Instance -Q $checkSql -h -1 -W 2>&1

        if ($LASTEXITCODE -ne 0 -or -not (($dbCheck | Out-String).Trim() -match [regex]::Escape($DbName))) {
            $result.Status = "FAILED"
            $result.Notes  = "Database not found on $Instance"
            Write-Log $result.Notes "ERROR"
            return $result
        }

        Write-Log "Database [$DbName] verified." "SUCCESS"
    }

    # Build backup filename
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $BkPath ("{0}_{1}.bak" -f $dbFileStem, $ts)

    # Get safe backup and filenames
    $backupFileLiteral = Convert-ToSqlNLiteral $backupFile
    $backupNameLiteral = Convert-ToSqlNLiteral ("{0}-Full-{1}" -f $DbName, $ts)

    # Backup sqlcmd
    $backupSql = @"
BACKUP DATABASE $dbNameIdentifier
TO DISK = $backupFileLiteral
WITH
				
    INIT,
    CHECKSUM,
    STATS = 10,
    NAME = $backupNameLiteral;
"@

    # Check for dry run mode and report or run backup
    if ($script:DryRunMode) {
        Write-Log "Would execute backup:" "DRYRUN"
        Write-Log "  Target file: $backupFile" "DRYRUN"
        Write-Log "  SQL: BACKUP DATABASE [$DbName] TO DISK ... WITH INIT, CHECKSUM, STATS = 10" "DRYRUN"
        Write-Log "Would verify backup with RESTORE VERIFYONLY ... WITH CHECKSUM" "DRYRUN"

        $result.BackupFile = $backupFile
        $result.SizeMB     = 0
        $result.Duration   = "00:00"
    } else {
        Write-Log "Starting backup -> $backupFile"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Backup Database
        $sqlOut = sqlcmd -S $Instance -Q $backupSql -b 2>&1

        if ($LASTEXITCODE -ne 0) {
            $sw.Stop()
            $result.Status   = "FAILED"
            $result.Duration = $sw.Elapsed.ToString("mm\:ss")
            $result.Notes    = ($sqlOut | Out-String).Trim()
            Write-Log "Backup FAILED for [$DbName]!" "ERROR"
            $sqlOut | ForEach-Object { Write-Log "  $_" "ERROR" }
            return $result
        }

        $sw.Stop()
        $result.Duration   = $sw.Elapsed.ToString("mm\:ss")
        $result.BackupFile = $backupFile
																				  
        if (-not (Test-Path -LiteralPath $backupFile)) {
            $result.Status = "FAILED"
            $result.Notes  = "Backup command completed but file was not found: $backupFile"
            Write-Log $result.Notes "ERROR"
            return $result
        }

        try {
            $result.SizeMB = [Math]::Round((Get-Item -LiteralPath $backupFile).Length / 1MB, 2)
        }
        catch {
            $result.SizeMB = 0
        }

        Write-Log "Backup completed in $($result.Duration) - Size: $($result.SizeMB) MB" "SUCCESS"

        Write-Log "Verifying backup checksum ..."
        $verifySql    = "RESTORE VERIFYONLY FROM DISK = $backupFileLiteral WITH CHECKSUM;"
        
        # Verify backup
        $verifyResult = sqlcmd -S $Instance -Q $verifySql -b 2>&1

        if ($LASTEXITCODE -ne 0) {
            $result.Status = "VERIFY_FAILED"
            $result.Notes  = ($verifyResult | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($result.Notes)) {
                $result.Notes = "Backup file created but integrity check failed"
            }
            Write-Log $result.Notes "ERROR"
            return $result
        }

        Write-Log "Backup integrity verified." "SUCCESS"
    }

    # Retention cleanup
    Write-Log "Applying retention policy (keep newest $Retain) ..."

    $allBackups = Get-BackupFilesForDatabase -BackupPath $BkPath -DbFileStem $dbFileStem
    $cleanupErrors = @()

    if ($allBackups.Count -gt $Retain) {
        $toDelete = $allBackups | Select-Object -Skip $Retain
										 
        if ($script:DryRunMode) {
            Write-Log "Would delete $($toDelete.Count) old backup(s):" "DRYRUN"
            foreach ($f in $toDelete) {
                Write-Log "  Would delete: $($f.Name)  ($([Math]::Round($f.Length / 1MB, 2)) MB, $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" "DRYRUN"
            }
        }
        else {
            foreach ($f in $toDelete) {

                # Remove backup file
                $deleteResult = Remove-BackupFileSafely -File $f -RetryCount 3 -RetryDelaySeconds 2
                if ($deleteResult.Success) {
                    $result.Deleted++
                    Write-Log "  Deleted: $($f.Name)" "WARN"
                }
                else {
                    $cleanupErrors += "$($f.Name): $($deleteResult.Message)"
                    Write-Log "  Failed to delete $($f.Name): $($deleteResult.Message)" "ERROR"
                }

            }

            if ($result.Deleted -gt 0) {
                Write-Log "Cleanup complete - removed $($result.Deleted) old backup(s)."
            }
        }
    }
    else {
        $msg = "No cleanup needed ($($allBackups.Count) backups <= $Retain retention limit)."
        if ($script:DryRunMode) { Write-Log $msg "DRYRUN" } else { Write-Log $msg }
    }

    # Refresh retained count after cleanup
    $remainingBackups = Get-BackupFilesForDatabase -BackupPath $BkPath -DbFileStem $dbFileStem
    $result.Retained = [Math]::Min($remainingBackups.Count, $Retain)

    if ($script:DryRunMode) {
        $result.Status = "DRY-RUN OK"
        $result.Notes  = "Simulated - no changes made"
    }
    else {
        if ($cleanupErrors.Count -gt 0) {
            $result.Status = "SUCCESS_WITH_WARNINGS"
            $result.Notes  = "Backup verified OK, but cleanup had issues: " + ($cleanupErrors -join "; ")
        }
        else {
            $result.Status = "SUCCESS"
            $result.Notes  = "Verified OK, $($result.Retained) kept / $($result.Deleted) purged"
        }
    }

    return $result
}

#------------------------------------------------------------------------------
# Send HTML email 
#------------------------------------------------------------------------------
function Send-Report {
    param(
        [hashtable]$SmtpConfig,
        [array]$Results,
        [string]$ServerName,
        $Config
    )

    # Calculate success and failure counts
    $totalCount   = $Results.Count
    $successCount = @($Results | Where-Object { $_.Status -in @("SUCCESS", "DRY-RUN OK") }).Count
    $warningCount = @($Results | Where-Object { $_.Status -eq "SUCCESS_WITH_WARNINGS" }).Count
    $failCount    = @($Results | Where-Object { $_.Status -notin @("SUCCESS", "DRY-RUN OK", "SUCCESS_WITH_WARNINGS") }).Count

    $hasIssues = ($warningCount -gt 0 -or $failCount -gt 0)
    $allPassed = ($warningCount -eq 0 -and $failCount -eq 0)

    if ($allPassed -and -not $SmtpConfig.SendOnSuccess) {
        Write-Log "All backups succeeded - email suppressed (SendOnSuccess = false)."
        return
    }
    if ($hasIssues -and -not $SmtpConfig.SendOnFailure) {
        Write-Log "Warnings or failures detected - email suppressed (SendOnFailure = false)."
        return
    }

    $dryTag = if ($script:DryRunMode) { " [DRY-RUN]" } else { "" }

    if ($failCount -gt 0) {
        $subjectLine = "[FAILED] SQL Express Backup on $ServerName$dryTag ($failCount failed, $warningCount warnings)"
        $statusEmoji = "&#10060;"
        $statusText  = "$failCount failed, $warningCount warnings, $successCount succeeded"
															   
    }
    elseif ($warningCount -gt 0) {
        $subjectLine = "[WARNING] SQL Express Backup on $ServerName$dryTag ($warningCount warnings)"
        $statusEmoji = "&#9888;"
        $statusText  = "$warningCount warning(s), $successCount succeeded"
    }
    else {
        $subjectLine = "[Success] SQL Express Backup on $ServerName$dryTag ($successCount/$totalCount)"
        $statusEmoji = "&#9989;"
        $statusText  = "All backups succeeded"
    }

    # --- Config summary section ------------------------------------------------
    $configSummaryHtml = ""
    if ($Config) {
        $backupAllFlag = if ($Config.BackupAllUserDatabases -eq $true) {
            "<span style='color:#2e7d32;font-weight:bold;'>&#9989; Yes - all user databases</span>"
        } else {
            "<span style='color:#0277bd;font-weight:bold;'>&#9776; No - selective (config list only)</span>"
        }

        $globalInstance   = if ($Config.ServerInstance)    { $Config.ServerInstance }    else { ".\SQLEXPRESS" }
        $globalRetain     = if ($Config.RetainCount)       { $Config.RetainCount }       else { 5 }
        $defaultPath      = if ($Config.DefaultBackupPath) { $Config.DefaultBackupPath } else { "N/A" }

        $configSummaryHtml = @"
    <h3 style="margin-bottom:4px;color:#333;">Configuration</h3>
    <table style="border-collapse:collapse;margin-bottom:10px;">
        <tr>
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;">Backup All User DBs:</td>
            <td style="padding:4px 0;">$backupAllFlag</td>
        </tr>
        <tr>
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;">Server Instance:</td>
            <td style="padding:4px 0;">$globalInstance</td>
        </tr>
        <tr>
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;">Default Backup Path:</td>
            <td style="padding:4px 0;">$defaultPath</td>
        </tr>
        <tr>
            <td style="padding:4px 12px 4px 0;color:#555;font-weight:bold;">Default Retention:</td>
            <td style="padding:4px 0;">$globalRetain copies</td>
        </tr>
    </table>
"@

        # Per-database overrides table (only if Databases array has entries)
        if ($Config.Databases -and $Config.Databases.Count -gt 0) {
            $overrideRows = ""
            foreach ($db in $Config.Databases) {
                $dbPath     = if ($db.BackupPath)     { $db.BackupPath }     else { "<em>default</em>" }
                $dbRetain   = if ($db.RetainCount -and $db.RetainCount -gt 0) { "$($db.RetainCount) copies" } else { "<em>default</em>" }
                $dbInstance = if ($db.ServerInstance)  { $db.ServerInstance }  else { "<em>default</em>" }

                $overrideRows += @"
            <tr>
                <td style="padding:4px 8px;border:1px solid #ddd;">$($db.Name)</td>
                <td style="padding:4px 8px;border:1px solid #ddd;">$dbPath</td>
                <td style="padding:4px 8px;border:1px solid #ddd;text-align:center;">$dbRetain</td>
                <td style="padding:4px 8px;border:1px solid #ddd;">$dbInstance</td>
            </tr>
"@
            }

            $configSummaryHtml += @"
    <h3 style="margin-bottom:4px;color:#333;">Per-Database Overrides</h3>
    <table style="border-collapse:collapse;margin-bottom:16px;">
        <tr style="background:#455a64;color:#fff;">
            <th style="padding:6px 8px;border:1px solid #ddd;text-align:left;">Database</th>
            <th style="padding:6px 8px;border:1px solid #ddd;text-align:left;">Backup Path</th>
            <th style="padding:6px 8px;border:1px solid #ddd;text-align:center;">Retention</th>
            <th style="padding:6px 8px;border:1px solid #ddd;text-align:left;">Instance</th>
        </tr>
        $overrideRows
    </table>
"@
        }
    }

    # Build results list
    $rows = ""
    foreach ($r in $Results) {
        $color = switch ($r.Status) {
            "SUCCESS"               { "#2e7d32" }
            "DRY-RUN OK"            { "#0277bd" }
            "SUCCESS_WITH_WARNINGS" { "#e65100" }
            "VERIFY_FAILED"         { "#c62828" }
            default                 { "#c62828" }
        }
        $icon = switch ($r.Status) {
            "SUCCESS"               { "&#9989;" }
            "DRY-RUN OK"            { "&#128309;" }
            "SUCCESS_WITH_WARNINGS" { "&#9888;" }
            "VERIFY_FAILED"         { "&#10060;" }
            default                 { "&#10060;" }
        }

        # Get safe DB name and notes
        $notesEscaped = [System.Net.WebUtility]::HtmlEncode([string]$r.Notes)
        $dbEscaped    = [System.Net.WebUtility]::HtmlEncode([string]$r.Database)

        $rows += @"
        <tr>
            <td style="padding:8px;border:1px solid #ddd;">$dbEscaped</td>
            <td style="padding:8px;border:1px solid #ddd;color:${color};font-weight:bold;">$icon $($r.Status)</td>
            <td style="padding:8px;border:1px solid #ddd;text-align:right;">$($r.SizeMB) MB</td>
            <td style="padding:8px;border:1px solid #ddd;text-align:center;">$($r.Duration)</td>
            <td style="padding:8px;border:1px solid #ddd;text-align:center;">$($r.Retained) kept / $($r.Deleted) purged</td>
            <td style="padding:8px;border:1px solid #ddd;font-size:0.9em;">$notesEscaped</td>
        </tr>
"@
    }

    $reportTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $html = @"
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family:Segoe UI,Arial,sans-serif;margin:10px;">
    <h2 style="margin-bottom:4px;">$statusEmoji SQL Express Backup Report$dryTag</h2>
    <p style="color:#555;margin-top:0;">
        <strong>Server:</strong> $ServerName &nbsp;|&nbsp;
        <strong>Time:</strong> $reportTime &nbsp;|&nbsp;
        <strong>Result:</strong> $statusText
    </p>
    
    $configSummaryHtml

    <table style="border-collapse:collapse;width:100%;margin-top:12px;">
        <tr style="background:#1565c0;color:#fff;">
            <th style="padding:10px;border:1px solid #ddd;text-align:left;">Database</th>
            <th style="padding:10px;border:1px solid #ddd;text-align:left;">Status</th>
            <th style="padding:10px;border:1px solid #ddd;text-align:right;">Size</th>
            <th style="padding:10px;border:1px solid #ddd;text-align:center;">Duration</th>
            <th style="padding:10px;border:1px solid #ddd;text-align:center;">Retention</th>
            <th style="padding:10px;border:1px solid #ddd;text-align:left;">Notes</th>
        </tr>
        $rows
    </table>
    <p style="color:#999;font-size:0.85em;margin-top:16px;">
        Generated by Backup-SQLExpressDB.ps1
    </p> 
    <p style="color:#999;font-size:0.85em;margin-top:2px;">
        GitHub: <a href="https://github.com/jchimp/sqlexpress-backup" style="color:#999;">jchimp/sqlexpress-backup</a>
    </p>
</body>
</html>
"@

    if ($script:DryRunMode) {
        Write-Log "Would send email report:" "DRYRUN"
        Write-Log "  From:    $($SmtpConfig.From)" "DRYRUN"
        Write-Log "  To:      $($SmtpConfig.To -join ', ')" "DRYRUN"
        Write-Log "  Subject: $subjectLine" "DRYRUN"
        Write-Log "  Server:  $($SmtpConfig.Server):$($SmtpConfig.Port) (SSL: $($SmtpConfig.UseSsl))" "DRYRUN"
        return
    }

    # Build email
    try {
        $msg  = New-Object System.Net.Mail.MailMessage
        $msg.From = New-Object System.Net.Mail.MailAddress($SmtpConfig.From)
        $msg.Subject = $subjectLine
        $msg.Body = $html
        $msg.IsBodyHtml = $true

        $recipients = @($SmtpConfig.To)
        foreach ($to in $recipients) {
            if (-not [string]::IsNullOrWhiteSpace($to)) {
                [void]$msg.To.Add($to)
            }
        }

        $smtp = New-Object System.Net.Mail.SmtpClient($SmtpConfig.Server, $SmtpConfig.Port)
        $smtp.EnableSsl = [bool]$SmtpConfig.UseSsl

        if ($SmtpConfig.Username -and $SmtpConfig.Password) {
            $smtp.Credentials = New-Object System.Net.NetworkCredential(
                $SmtpConfig.Username, $SmtpConfig.Password
            )
        }

        # Send email
        $smtp.Send($msg)
        Write-Log "Email report sent to: $($recipients -join ', ')" "SUCCESS"
    }
    catch {
        Write-Log "Failed to send email report: $($_.Exception.Message)" "ERROR"
    }
    finally {
        if ($msg)  { $msg.Dispose() }
        if ($smtp) { $smtp.Dispose() }
    }
}


#===============================================================================
# MAIN EXECUTION
#===============================================================================
$script:DryRunMode = $DryRun.IsPresent
$serverName = $env:COMPUTERNAME

if ($script:DryRunMode) {
    Write-Host ""
    Write-Host "  +============================================+" -ForegroundColor Cyan
    Write-Host "  |         DRY-RUN MODE - NO CHANGES          |" -ForegroundColor Cyan
    Write-Host "  |   No backups, deletions, or emails sent    |" -ForegroundColor Cyan
    Write-Host "  +============================================+" -ForegroundColor Cyan
    Write-Host ""
}

# Verify config file
if (-not (Test-JsonConfig -Path $ConfigFile)) { exit 1 }

#------------------------------------------------------------------------------
# CONFIG FILE MODE
#------------------------------------------------------------------------------
if ($ConfigFile -and (Test-Path -LiteralPath $ConfigFile)) {
    try {
        $config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Log "Failed to parse config file: $($_.Exception.Message)" "ERROR"
        exit 1
    }

    $globalInstance = if ($config.ServerInstance) { $config.ServerInstance } else { ".\SQLEXPRESS" }
    $globalRetain   = if ($config.RetainCount -and [int]$config.RetainCount -gt 0) { [int]$config.RetainCount } else { 5 }

    # Get the log file and rotate
    $script:ActiveLogFile = if (-not $script:DryRunMode) {
        if ($LogFile) { $LogFile } else { $config.LogFile }
    } else { $null }
    if ($script:ActiveLogFile) { Rotate-LogFile -LogPath $script:ActiveLogFile -KeepCount 5 }

    Write-Log "================================================================="
    Write-Log "SQL Express Backup - Config Mode"
    Write-Log "  Config:     $ConfigFile"
    Write-Log "  Server:     $serverName"
    Write-Log "  Instance:   $globalInstance"
    Write-Log "  Databases:  $($config.Databases.Count)"
    Write-Log "  Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    if ($script:DryRunMode) { Write-Log "  Mode:       DRY-RUN (no changes will be made)" "DRYRUN" }
    Write-Log "================================================================="

    # Build the database list.
    # Get all our User DBs if needed and all DBs that are overridden in the config file.
    $dbList = @()
    if ($config.BackupAllUserDatabases -eq $true) {
        Write-Log "BackupAllUserDatabases = true - discovering databases on $globalInstance ..."

        if (-not $config.DefaultBackupPath) {
            Write-Log "DefaultBackupPath is required when BackupAllUserDatabases is true." "ERROR"
            exit 1
        }

        $discoveredDbs = Get-UserDatabases -Instance $globalInstance

        if ($discoveredDbs.Count -eq 0) {
            Write-Log "No user databases found on $globalInstance." "ERROR"
            exit 1
        }

        Write-Log "Found $($discoveredDbs.Count) user database(s): $($discoveredDbs -join ', ')"

        # Build override lookup from Databases array
        $overrides = @{}
        if ($config.Databases) {
            foreach ($dbOverride in $config.Databases) {
                $overrides[$dbOverride.Name] = $dbOverride
            }
        }

        # Create database list with overrides
        foreach ($dbName in $discoveredDbs) {
            $entryPath     = Join-Path $config.DefaultBackupPath $dbName
            $entryRetain   = $globalRetain
            $entryInstance = $globalInstance

            if ($overrides.ContainsKey($dbName)) {
                $ov = $overrides[$dbName]
                if ($ov.BackupPath)     { $entryPath     = $ov.BackupPath }
                if ($ov.RetainCount -and $ov.RetainCount -gt 0) { $entryRetain = $ov.RetainCount }
                if ($ov.ServerInstance) { $entryInstance = $ov.ServerInstance }
            }

            $entry = @{}
            $entry.Name           = $dbName
            $entry.BackupPath     = $entryPath
            $entry.RetainCount    = $entryRetain
            $entry.ServerInstance = $entryInstance
            $dbList += $entry
        }
    }
    else {

        # Selective mode - use Databases array as-is
        if (-not $config.Databases -or $config.Databases.Count -eq 0) {
            Write-Log "No databases defined in config file. Exiting." "ERROR"
            exit 1
        }

        # Create database list
        foreach ($db in $config.Databases) {
            $entryRetain   = $globalRetain
            $entryInstance = $globalInstance

            if ($db.RetainCount -and $db.RetainCount -gt 0) { $entryRetain = $db.RetainCount }
            if ($db.ServerInstance) { $entryInstance = $db.ServerInstance }
            
            # BackupPath: use per-DB if set, otherwise DefaultBackupPath\DbName
            if ($db.BackupPath) {
                $entryPath = $db.BackupPath
            }
            elseif ($config.DefaultBackupPath) {
                $entryPath = Join-Path $config.DefaultBackupPath $db.Name
            }
            else {
                Write-Log "No BackupPath for [$($db.Name)] and no DefaultBackupPath set." "ERROR"
                continue
            }

            $entry = @{}
            $entry.Name           = $db.Name
            $entry.BackupPath     = $entryPath
            $entry.RetainCount    = $entryRetain
            $entry.ServerInstance = $entryInstance
            $dbList += $entry
        }

    }

    # Loop through and back up each database
    $allResults = @()
    foreach ($db in $dbList) {
        Write-Log ""
        Write-Log "-----------------------------------------------------------------"
        Write-Log "Processing: $($db.Name)  [Instance: $($db.ServerInstance) | Retain: $($db.RetainCount)]"
        Write-Log "-----------------------------------------------------------------"

        # Backup database
        $r = Backup-SingleDatabase -DbName $db.Name `
                                   -BkPath $db.BackupPath `
                                   -Retain $db.RetainCount `
                                   -Instance $db.ServerInstance

        $allResults += $r
    }

    # Calculate results			   
    $passed   = @($allResults | Where-Object { $_.Status -in @("SUCCESS", "DRY-RUN OK") }).Count
    $warnings = @($allResults | Where-Object { $_.Status -eq "SUCCESS_WITH_WARNINGS" }).Count
    $failed   = @($allResults | Where-Object { $_.Status -notin @("SUCCESS", "DRY-RUN OK", "SUCCESS_WITH_WARNINGS") }).Count

    Write-Log ""
    Write-Log "================================================================="
    Write-Log "Batch complete: $passed passed, $warnings warnings, $failed failed out of $($allResults.Count)."
    Write-Log "================================================================="

    if ($config.Smtp -and $config.Smtp.Server) {
        $smtpHash = @{
            Server        = $config.Smtp.Server
            Port          = if ($config.Smtp.Port) { [int]$config.Smtp.Port } else { 25 }
            From          = $config.Smtp.From
            To            = @($config.Smtp.To)
            UseSsl        = [bool]$config.Smtp.UseSsl
            Username      = $config.Smtp.Username
            Password      = $config.Smtp.Password
            SendOnSuccess = if ($null -ne $config.Smtp.SendOnSuccess) { [bool]$config.Smtp.SendOnSuccess } else { $true }
            SendOnFailure = if ($null -ne $config.Smtp.SendOnFailure) { [bool]$config.Smtp.SendOnFailure } else { $true }
        }

        # Send email report
        Send-Report -SmtpConfig $smtpHash -Results $allResults -ServerName $serverName -Config $config

    } 
    else {
        Write-Log "No SMTP configuration found - skipping email report."
    }

    if ($failed -gt 0) { exit 1 } else { exit 0 }
}

#------------------------------------------------------------------------------
# SINGLE DATABASE MODE
#------------------------------------------------------------------------------																				
# Get log file and rotate
$script:ActiveLogFile = if (-not $script:DryRunMode) {
    if ($LogFile) { $LogFile } else { $config.LogFile }
} else { $null }
if ($script:ActiveLogFile) { Rotate-LogFile -LogPath $script:ActiveLogFile -KeepCount 5 }

# Check parameteres
if (-not $DatabaseName) {
    $DatabaseName = Read-Host "Enter the database name to back up"
    if (-not $DatabaseName) {
        Write-Log "Database name is required." "ERROR"
        exit 1
    }
}
if (-not $BackupPath) {
    $BackupPath = Read-Host "Enter the backup destination folder path"
    if (-not $BackupPath) {
        Write-Log "Backup path is required." "ERROR"
        exit 1
    }
}
if ($RetainCount -le 0) {
    $retainInput = Read-Host "Number of backups to retain [default: 5]"
    if ($retainInput -and $retainInput -match '^\d+$') {
        $RetainCount = [int]$retainInput
    } else {
        $RetainCount = 5
    }
}

Write-Log "================================================================="
Write-Log "SQL Express Backup - Single Database Mode"
Write-Log "  Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
if ($script:DryRunMode) { Write-Log "  Mode: DRY-RUN (no changes will be made)" "DRYRUN" }
Write-Log "================================================================="

# Backup single database
$r = Backup-SingleDatabase -DbName $DatabaseName `
                           -BkPath $BackupPath `
                           -Retain $RetainCount `
                           -Instance $ServerInstance

if ($r.Status -in @("SUCCESS", "DRY-RUN OK", "SUCCESS_WITH_WARNINGS")) {
    Write-Log "================================================================="
    if ($r.Status -eq "SUCCESS_WITH_WARNINGS") {
        Write-Log "Backup job finished with warnings: $($r.Notes)" "WARN"
    }
    else {
        Write-Log "Backup job finished successfully." "SUCCESS"
    }
    Write-Log "================================================================="
    exit 0
}
else {
    Write-Log "================================================================="
    Write-Log "Backup job FAILED: $($r.Notes)" "ERROR"
    Write-Log "================================================================="
    exit 1
}
