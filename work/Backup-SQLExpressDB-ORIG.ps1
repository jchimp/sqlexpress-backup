<#
.SYNOPSIS
    Backs up SQL Express databases with retention and email reporting.

.DESCRIPTION
    Reads a JSON config file to back up one or more SQL Express databases using sqlcmd.
    Features: checksum verification, retention cleanup, HTML email report.
    Also supports single-database mode via command-line parameters for one-off runs.
    If Backup-SQLExpressDB.json exists in the same directory as the script, it is loaded automatically.
    Use -DryRun to simulate the process without running sqlcmd or deleting files.

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

# ==============================================================================
# Helpers
# ==============================================================================

function Convert-ToSqlNLiteral {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return "NULL"
    }

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

    return @(
        Get-ChildItem -LiteralPath $BackupPath -Filter ("{0}_*.bak" -f $DbFileStem) -File |
        Sort-Object LastWriteTime -Descending
    )
}

function Get-CurrentIdentityName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return $env:USERNAME
    }
}

# ==============================================================================
# Logging
# ==============================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $ts  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $tag = if ($script:DryRunMode) { "[DRY-RUN] " } else { "" }

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
        }
        catch {
            Write-Host "[$ts] [WARN] Failed to write to log file $script:ActiveLogFile : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ==============================================================================
# Retention cleanup
# ==============================================================================

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

            $fileItem = Get-Item -LiteralPath $File.FullName -Force -ErrorAction Stop

            try {
                [System.IO.File]::SetAttributes($fileItem.FullName, [System.IO.FileAttributes]::Normal)
            }
            catch {
                Write-Log "  Attempt $attempt/$RetryCount - Could not reset attributes on $($fileItem.Name): $($_.Exception.Message)" "WARN"
            }

            Remove-Item -LiteralPath $fileItem.FullName -Force -ErrorAction Stop

            return @{
                Success = $true
                Message = "Deleted successfully"
            }
        }
        catch {
            Write-Log "  Attempt $attempt/$RetryCount - Failed to delete $($File.FullName): $($_.Exception.Message)" "ERROR"

            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }

    $owner = "Unavailable"
    try {
        $acl = Get-Acl -LiteralPath $File.FullName -ErrorAction Stop
        $owner = $acl.Owner
    }
    catch {
        # ignore
    }

    return @{
        Success = $false
        Message = "Access denied or file locked after $RetryCount attempts. Owner: $owner"
    }
}

# ==============================================================================
# Backup a single database
# ==============================================================================

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

    $dbFileStem = Convert-ToSafeFileName $DbName

    if (-not $script:DryRunMode -and -not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        $result.Status = "FAILED"
        $result.Notes  = "sqlcmd.exe not found in PATH"
        Write-Log $result.Notes "ERROR"
        return $result
    }

    if ($script:DryRunMode) {
        Write-Log "Would check for sqlcmd in PATH" "DRYRUN"
    }

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

    $dbNameLiteral    = Convert-ToSqlNLiteral $DbName
    $dbNameIdentifier = Convert-ToSqlBracketIdentifier $DbName

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

    $ts         = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $BkPath ("{0}_{1}.bak" -f $dbFileStem, $ts)

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

    if ($script:DryRunMode) {
        Write-Log "Would execute backup:" "DRYRUN"
        Write-Log "  Target file: $backupFile" "DRYRUN"
        Write-Log "  SQL: BACKUP DATABASE [$DbName] TO DISK ... WITH INIT, CHECKSUM, STATS = 10" "DRYRUN"
        Write-Log "Would verify backup with RESTORE VERIFYONLY ... WITH CHECKSUM" "DRYRUN"

        $result.BackupFile = $backupFile
        $result.SizeMB     = 0
        $result.Duration   = "00:00"
    }
    else {
        Write-Log "Starting backup -> $backupFile"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

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

    Write-Log "Applying retention policy (keep newest $Retain) ..."

    $allBackups   = Get-BackupFilesForDatabase -BackupPath $BkPath -DbFileStem $dbFileStem
    $cleanupErrors = @()

    if ($allBackups.Count -gt $Retain) {
        $toDelete = $allBackups | Select-Object -Skip $Retain

        if ($script:DryRunMode) {
            Write-Log "Would delete $($toDelete.Count) old backup(s):" "DRYRUN"
            foreach ($f in $toDelete) {
                $sizeMb = [Math]::Round($f.Length / 1MB, 2)
                $stamp  = $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                Write-Log "  Would delete: $($f.Name) ($sizeMb MB, $stamp)" "DRYRUN"
            }
        }
        else {
            foreach ($f in $toDelete) {
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
        if ($script:DryRunMode) {
            Write-Log $msg "DRYRUN"
        }
        else {
            Write-Log $msg
        }
    }

    $remainingBackups = Get-BackupFilesForDatabase -BackupPath $BkPath -DbFileStem $dbFileStem
    $result.Retained  = [Math]::Min($remainingBackups.Count, $Retain)

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

# ==============================================================================
# Send HTML email report
# ==============================================================================

function Send-Report {
    param(
        [hashtable]$SmtpConfig,
        [array]$Results,
        [string]$ServerName
    )

    $totalCount   = $Results.Count
    $successCount = ($Results | Where-Object { $_.Status -in @("SUCCESS", "DRY-RUN OK") }).Count
    $warningCount = ($Results | Where-Object { $_.Status -eq "SUCCESS_WITH_WARNINGS" }).Count
    $failCount    = ($Results | Where-Object { $_.Status -notin @("SUCCESS", "DRY-RUN OK", "SUCCESS_WITH_WARNINGS") }).Count

    $hasIssues = ($warningCount -gt 0 -or $failCount -gt 0)
    $allPassed = (-not $hasIssues)

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
        $subjectLine = "BACKUP ALERT: $failCount FAILED, $warningCount WARNINGS on $ServerName$dryTag"
        $statusEmoji = "&#10060;"
        $statusText  = "$failCount failed, $warningCount warnings, $successCount succeeded"
    }
    elseif ($warningCount -gt 0) {
        $subjectLine = "Backup WARNING: $warningCount warning(s) on $ServerName$dryTag"
        $statusEmoji = "&#9888;"
        $statusText  = "$warningCount warning(s), $successCount succeeded"
    }
    else {
        $subjectLine = "Backup OK: $successCount/$totalCount on $ServerName$dryTag"
        $statusEmoji = "&#9989;"
        $statusText  = "All backups succeeded"
    }

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
        Generated by Backup-SQLExpressDB.ps1
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
                [void]$msg.To.Add($to)
            }
        }

        $smtp = New-Object System.Net.Mail.SmtpClient($SmtpConfig.Server, $SmtpConfig.Port)
        $smtp.EnableSsl = [bool]$SmtpConfig.UseSsl

        if ($SmtpConfig.Username -and $SmtpConfig.Password) {
            $smtp.Credentials = New-Object System.Net.NetworkCredential(
                $SmtpConfig.Username,
                $SmtpConfig.Password
            )
        }

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

# ==============================================================================
# Main execution
# ==============================================================================

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

# -------------------- CONFIG FILE MODE --------------------

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

    $script:ActiveLogFile = if (-not $script:DryRunMode) {
        if ($LogFile) { $LogFile } else { $config.LogFile }
    }
    else {
        $null
    }

    Write-Log "================================================================="
    Write-Log "SQL Express Backup - Config Mode"
    Write-Log "  Config:     $ConfigFile"
    Write-Log "  Server:     $serverName"
    Write-Log "  Running as: $(Get-CurrentIdentityName)"
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

        $r = Backup-SingleDatabase -DbName $db.Name -BkPath $db.BackupPath -Retain $dbRetain -Instance $dbInstance
        $allResults += $r
    }

    $passed   = ($allResults | Where-Object { $_.Status -in @("SUCCESS", "DRY-RUN OK") }).Count
    $warnings = ($allResults | Where-Object { $_.Status -eq "SUCCESS_WITH_WARNINGS" }).Count
    $failed   = ($allResults | Where-Object { $_.Status -notin @("SUCCESS", "DRY-RUN OK", "SUCCESS_WITH_WARNINGS") }).Count

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

        Send-Report -SmtpConfig $smtpHash -Results $allResults -ServerName $serverName
    }
    else {
        Write-Log "No SMTP configuration found - skipping email report."
    }

    if ($failed -gt 0) {
        exit 1
    }
    else {
        exit 0
    }
}

# -------------------- SINGLE DATABASE MODE --------------------

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
    }
    else {
        $RetainCount = 5
    }
}

Write-Log "================================================================="
Write-Log "SQL Express Backup - Single Database Mode"
Write-Log "  Running as: $(Get-CurrentIdentityName)"
if ($script:DryRunMode) { Write-Log "  Mode: DRY-RUN (no changes will be made)" "DRYRUN" }
Write-Log "================================================================="

$r = Backup-SingleDatabase -DbName $DatabaseName -BkPath $BackupPath -Retain $RetainCount -Instance $ServerInstance

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
``