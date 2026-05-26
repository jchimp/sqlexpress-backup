<#
.SYNOPSIS
    Backs up SQL Express databases with retention, and email reporting.

.DESCRIPTION
    Reads a JSON config file to back up one or more SQL Express databases using sqlcmd.
    Features: checksum verification, retention cleanup, HTML email report.
    Also supports single-database mode via command-line parameters for one-off runs.
    Use -DryRun to simulate the entire process without executing sqlcmd or deleting files.

.PARAMETER ConfigFile
    Path to a JSON configuration file defining databases and SMTP settings.

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
    # Dry run with config (see what would happen):
    .\Backup-SqlExpressDB.ps1 -ConfigFile "C:\Scripts\Backup-SqlExpressDB.json" -DryRun

    # Config mode - multiple databases + email report:
    .\Backup-SqlExpressDB.ps1 -ConfigFile "C:\Scripts\Backup-SqlExpressDB.json"

    # Single database mode - interactive prompts:
    .\Backup-SqlExpressDB.ps1

    # Single database mode - parameterized:
    .\Backup-SqlExpressDB.ps1 -DatabaseName "WebTrack" -BackupPath "D:\Backups\WebTrack" -RetainCount 7
#>

param(
    [string]$ConfigFile,
    [string]$DatabaseName,
    [string]$BackupPath,
    [int]$RetainCount = 0,
    [string]$ServerInstance = ".\SQLEXPRESS",
    [string]$LogFile,
    [switch]$DryRun
)


# --- Helpers ------------------------------------------------------------------

function Convert-ToSqlNLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "NULL" }
    return "N'" + ($Value -replace "'", "''") + "'"
}

function Convert-ToSqlBracketIdentifier {
    param([Parameter(Mandatory)][string]$Name)
    return "[" + ($Name -replace "]", "]]") + "]"
}

# --- Logging helper -----------------------------------------------------------
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
            if ($logDir -and -not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            $entry | Out-File -FilePath $script:ActiveLogFile -Append -Encoding UTF8
        } catch {
            Write-Host "[$ts] [WARN] Failed to write to log file $script:ActiveLogFile : $_" -ForegroundColor Yellow
        }
    }
}

# --- Backup a single database -------------------------------------------------

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

    # Check DBName and backup path
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

    # Create backup directory
    if (-not (Test-Path $BkPath)) {
        if ($script:DryRunMode) {
            Write-Log "Would create directory: $BkPath" "DRYRUN"
        } else {
            Write-Log "Creating backup directory: $BkPath"
            try {
                New-Item -ItemType Directory -Path $BkPath -Force | Out-Null
            } catch {
                $result.Status = "FAILED"
                $result.Notes  = "Failed to create directory: $_"
                Write-Log $result.Notes "ERROR"
                return $result
            }
        }
    }

    # Get safe DB names
    $dbNameLiteral     = Convert-ToSqlNLiteral $DbName
    $dbNameIdentifier  = Convert-ToSqlBracketIdentifier $DbName

    # Verify database exists
    if ($script:DryRunMode) {
        Write-Log "Would verify database [$DbName] exists on $Instance" "DRYRUN"
    } else {
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

    # Perform the backup
    $ts         = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $BkPath ("{0}_{1}.bak" -f $DbName, $ts)

    $backupFileLiteral = Convert-ToSqlNLiteral $backupFile
    $backupNameLiteral = Convert-ToSqlNLiteral ("{0}-Full-{1}" -f $DbName, $ts)

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
																				  
        if (-not (Test-Path $backupFile)) {
            $result.Status = "FAILED"
            $result.Notes  = "Backup command completed but file was not found: $backupFile"
            Write-Log $result.Notes "ERROR"
            return $result
        }

        try {
            $result.SizeMB = [Math]::Round((Get-Item $backupFile).Length / 1MB, 2)
        } catch {
            $result.SizeMB = 0
        }

        Write-Log "Backup completed in $($result.Duration) - Size: $($result.SizeMB) MB" "SUCCESS"

        # Verify backup integrity
        Write-Log "Verifying backup checksum ..."
        $verifySql    = "RESTORE VERIFYONLY FROM DISK = $backupFileLiteral WITH CHECKSUM;"
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

    # Retention cleanup --
    Write-Log "Applying retention policy (keep newest $Retain) ..."

    if (Test-Path $BkPath) {
        $allBackups = Get-ChildItem -Path $BkPath -Filter ("{0}_*.bak" -f $DbName) -File |
                      Sort-Object LastWriteTime -Descending
    } else {
        $allBackups = @()
    }

    $result.Retained = [Math]::Min($allBackups.Count, $Retain)

    if ($allBackups.Count -gt $Retain) {
        $toDelete       = $allBackups | Select-Object -Skip $Retain
        $result.Deleted = $toDelete.Count

        if ($script:DryRunMode) {
            Write-Log "Would delete $($toDelete.Count) old backup(s):" "DRYRUN"
            foreach ($f in $toDelete) {
                Write-Log "  Would delete: $($f.Name)  ($([Math]::Round($f.Length / 1MB, 2)) MB, $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" "DRYRUN"
            }
        } else {
            foreach ($f in $toDelete) {
                try {
                    Remove-Item $f.FullName -Force
                    Write-Log "  Deleted: $($f.Name)" "WARN"
                } catch {
                    Write-Log "  Failed to delete $($f.Name): $_" "ERROR"
                }
            }
            Write-Log "Cleanup complete - removed $($result.Deleted) old backup(s)."
        }
    } else {
        $msg = "No cleanup needed ($($allBackups.Count) backups <= $Retain retention limit)."
        if ($script:DryRunMode) { Write-Log $msg "DRYRUN" } else { Write-Log $msg }
    }

    if ($script:DryRunMode) {
        $result.Status = "DRY-RUN OK"
        $result.Notes  = "Simulated - no changes made"
    } else {
        $result.Status = "SUCCESS"
        $result.Notes  = "Verified OK, $($result.Retained) kept / $($result.Deleted) purged"
    }

    return $result
}

# --- Send HTML email report ----------------------------------------------------

function Send-Report {
    param(
        [hashtable]$SmtpConfig,
        [array]$Results,
        [string]$ServerName
    )

    $totalCount   = $Results.Count
    $successCount = ($Results | Where-Object { $_.Status -in @("SUCCESS", "DRY-RUN OK") }).Count
    $failCount    = $totalCount - $successCount
    $allPassed    = $failCount -eq 0

    if ($allPassed -and -not $SmtpConfig.SendOnSuccess) {
        Write-Log "All backups succeeded - email suppressed (SendOnSuccess = false)."
        return
    }
    if (-not $allPassed -and -not $SmtpConfig.SendOnFailure) {
        Write-Log "Some backups failed - email suppressed (SendOnFailure = false)."
        return
    }

    $dryTag = if ($script:DryRunMode) { " [DRY-RUN]" } else { "" }

    $subjectLine = if ($allPassed) {
        "Backup OK: $totalCount/$totalCount on $ServerName$dryTag"
    } else {
        "BACKUP ALERT: $failCount FAILED on $ServerName$dryTag"
    }

    $statusEmoji = if ($allPassed) { "&#9989;" } else { "&#10060;" }
    $statusText  = if ($allPassed) { "All Backups Succeeded" } else { "$failCount of $totalCount Failed" }

    $rows = ""
    foreach ($r in $Results) {
        $color = switch ($r.Status) {
            "SUCCESS"       { "#2e7d32" }
            "DRY-RUN OK"    { "#0277bd" }
            "VERIFY_FAILED" { "#e65100" }
            default         { "#c62828" }
        }
        $icon = switch ($r.Status) {
            "SUCCESS"       { "&#9989;" }
            "DRY-RUN OK"    { "&#128309;" }
            "VERIFY_FAILED" { "&#9888;"  }
            default         { "&#10060;" }
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
<body style="font-family:Segoe UI,Arial,sans-serif;margin:20px;">
    <h2 style="margin-bottom:4px;">$statusEmoji SQL Express Backup Report$dryTag</h2>
    <p style="color:#555;margin-top:0;">
        <strong>Server:</strong> $ServerName &nbsp;|&nbsp;
        <strong>Time:</strong> $reportTime &nbsp;|&nbsp;
        <strong>Result:</strong> $statusText
    </p>
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
        Generated by Backup-SqlExpressDB.ps1
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

    try {
        $msg            = New-Object System.Net.Mail.MailMessage
        $msg.From       = New-Object System.Net.Mail.MailAddress($SmtpConfig.From)
        $msg.Subject    = $subjectLine
        $msg.Body       = $html
        $msg.IsBodyHtml = $true

        $recipients = @($SmtpConfig.To)
        foreach ($to in $recipients) {
            if (-not [string]::IsNullOrWhiteSpace($to)) {
                $msg.To.Add($to)
            }
        }

        $smtp           = New-Object System.Net.Mail.SmtpClient($SmtpConfig.Server, $SmtpConfig.Port)
        $smtp.EnableSsl = [bool]$SmtpConfig.UseSsl

        if ($SmtpConfig.Username -and $SmtpConfig.Password) {
            $smtp.Credentials = New-Object System.Net.NetworkCredential(
                $SmtpConfig.Username, $SmtpConfig.Password
            )
        }

        $smtp.Send($msg)
        Write-Log "Email report sent to: $($recipients -join ', ')" "SUCCESS"
    }
    catch {
        Write-Log "Failed to send email report: $_" "ERROR"
    }
    finally {
        if ($msg)  { $msg.Dispose() }
        if ($smtp) { $smtp.Dispose() }
    }
}


# ===============================================================================
#  MAIN EXECUTION
# ===============================================================================

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

# --- CONFIG FILE MODE ----------------------------------------------------------

if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) {
        Write-Host "Config file not found: $ConfigFile" -ForegroundColor Red
        exit 1
    }

    try {
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    } catch {
        Write-Log "Failed to parse config file: $_" "ERROR"
        exit 1
    }

    $globalInstance       = if ($config.ServerInstance) { $config.ServerInstance } else { ".\SQLEXPRESS" }
    $globalRetain         = if ($config.RetainCount -and [int]$config.RetainCount -gt 0) { [int]$config.RetainCount } else { 5 }
    $script:ActiveLogFile = if (-not $script:DryRunMode) { $config.LogFile } else { $null }

    Write-Log "================================================================="
    Write-Log "SQL Express Backup - Config Mode"
    Write-Log "  Config:     $ConfigFile"
    Write-Log "  Server:     $serverName"
    Write-Log "  Instance:   $globalInstance"
    Write-Log "  Databases:  $($config.Databases.Count)"
    if ($script:DryRunMode) { Write-Log "  Mode:       DRY-RUN (no changes will be made)" "DRYRUN" }
    Write-Log "================================================================="

    if (-not $config.Databases -or $config.Databases.Count -eq 0) {
        Write-Log "No databases defined in config file. Exiting." "ERROR"
        exit 1
    }

    $allResults = @()

    foreach ($db in $config.Databases) {
        $dbInstance = if ($db.ServerInstance) { $db.ServerInstance } else { $globalInstance }
        $dbRetain   = if ($db.RetainCount -and [int]$db.RetainCount -gt 0) { [int]$db.RetainCount } else { $globalRetain }

        Write-Log ""
        Write-Log "-----------------------------------------------------------------"
        Write-Log "Processing: $($db.Name)  [Instance: $dbInstance | Retain: $dbRetain]"
        Write-Log "-----------------------------------------------------------------"

        $r = Backup-SingleDatabase -DbName $db.Name `
                                   -BkPath $db.BackupPath `
                                   -Retain $dbRetain `
                                   -Instance $dbInstance

        $allResults += $r
    }

    $passed = ($allResults | Where-Object { $_.Status -in @("SUCCESS", "DRY-RUN OK") }).Count
    $failed = $allResults.Count - $passed

    Write-Log ""
    Write-Log "================================================================="
    Write-Log "Batch complete: $passed passed, $failed failed out of $($allResults.Count)."
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

        Send-Report -SmtpConfig $smtpHash -Results $allResults -ServerName $serverName
    } else {
        Write-Log "No SMTP configuration found - skipping email report."
    }

    if ($failed -gt 0) { exit 1 } else { exit 0 }
}

# --- SINGLE DATABASE MODE ------------------------------------------------------
																				

$script:ActiveLogFile = if (-not $script:DryRunMode) { $LogFile } else { $null }

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
if ($script:DryRunMode) { Write-Log "  Mode: DRY-RUN (no changes will be made)" "DRYRUN" }
Write-Log "================================================================="

$r = Backup-SingleDatabase -DbName $DatabaseName `
                           -BkPath $BackupPath `
                           -Retain $RetainCount `
                           -Instance $ServerInstance

if ($r.Status -in @("SUCCESS", "DRY-RUN OK")) {
    Write-Log "================================================================="
    Write-Log "Backup job finished successfully." "SUCCESS"
    Write-Log "================================================================="
    exit 0
} else {
    Write-Log "================================================================="
    Write-Log "Backup job FAILED: $($r.Notes)" "ERROR"
    Write-Log "================================================================="
    exit 1
}
