# SQL Express Backup Toolkit

PowerShell-based backup solution for SQL Express databases using `sqlcmd`. Supports multi-database configs, compression, retention cleanup, integrity verification, SMTP email reports, and dry-run testing.

## Files

| File | Purpose |
|---|---|
| `Backup-SqlExpressDB.ps1` | Main script — backup, verify, cleanup, email |
| `Backup-SqlExpressDB.json` | Config file — databases, retention, SMTP settings |
| `Backup-SqlExpressDB.bat` | Thin launcher for Task Scheduler |
| `README.md` | This file |

## Requirements

- Windows with PowerShell 5.1+
- SQL Server command-line tools (`sqlcmd` in PATH)
- SQL Server 2016 SP1+ for `WITH COMPRESSION` on Express edition (remove `, COMPRESSION` from the script for older builds)

## How It Works

1. Reads `Backup-SqlExpressDB.json` for the list of databases, backup paths, retention counts, and SMTP settings
2. Loops through each database entry and for each one:
   - Verifies the database exists on the SQL instance via `sqlcmd`
   - Runs `BACKUP DATABASE ... WITH COMPRESSION, INIT, CHECKSUM` via `sqlcmd`
   - Verifies the backup file with `RESTORE VERIFYONLY ... WITH CHECKSUM`
   - Applies retention policy — keeps the newest N backups, deletes the rest
3. Sends an HTML email summary via SMTP with per-database status
4. Also supports single-database mode via command-line parameters (no config file needed)

## Config File Parameters

| Parameter | Scope | Required | Default | Description |
|---|---|---|---|---|
| `ServerInstance` | Global | No | `.\SQLEXPRESS` | Default SQL Server instance |
| `RetainCount` | Global | No | `5` | Default number of backups to keep |
| `LogFile` | Global | No | *(none)* | Append all output to this file |
| `Smtp.Server` | Global | No | *(none)* | SMTP relay hostname |
| `Smtp.Port` | Global | No | `25` | SMTP port |
| `Smtp.From` | Global | No | — | Sender email address |
| `Smtp.To` | Global | No | — | Array of recipient email addresses |
| `Smtp.UseSsl` | Global | No | `false` | Enable SSL/TLS |
| `Smtp.Username` | Global | No | *(empty)* | SMTP auth username (leave empty for relay) |
| `Smtp.Password` | Global | No | *(empty)* | SMTP auth password |
| `Smtp.SendOnSuccess` | Global | No | `true` | Send email when all backups succeed |
| `Smtp.SendOnFailure` | Global | No | `true` | Send email when any backup fails |
| `Databases[].Name` | Per-DB | **Yes** | — | Database name |
| `Databases[].BackupPath` | Per-DB | **Yes** | — | Backup destination folder |
| `Databases[].RetainCount` | Per-DB | No | *(global)* | Override retention for this database |
| `Databases[].ServerInstance` | Per-DB | No | *(global)* | Override SQL instance for this database |

## Usage Examples

### Single database (no config file)

```powershell
# Interactive — prompts for database name, path, retention:
.\Backup-SqlExpressDB.ps1

# Parameterized:
.\Backup-SqlExpressDB.ps1 -DatabaseName "WebTrack" -BackupPath "D:\Backups\WebTrack" -RetainCount 7

# Dry run — see what would happen:
.\Backup-SqlExpressDB.ps1 -DatabaseName "WebTrack" -BackupPath "D:\Backups\WebTrack" -RetainCount 7 -DryRun
```

### Multi-database with config file

```powershell
# Full run:
.\Backup-SqlExpressDB.ps1 -ConfigFile "C:\Scripts\Backup-SqlExpressDB.json"

# Dry run first:
.\Backup-SqlExpressDB.ps1 -ConfigFile "C:\Scripts\Backup-SqlExpressDB.json" -DryRun
```

### Via BAT launcher (for Task Scheduler)

```bat
C:\Scripts\Backup-SqlExpressDB.bat
```

## Setting Up the Scheduled Task

1. Place all files in `C:\Scripts\` (or your preferred location)
2. Edit `Backup-SqlExpressDB.json` with your databases, paths, and SMTP settings
3. Test with a dry run: `.\Backup-SqlExpressDB.ps1 -ConfigFile "C:\Scripts\Backup-SqlExpressDB.json" -DryRun`
4. Open **Task Scheduler** → **Create Task** (not "Basic Task")
5. **General tab:**
   - ✅ Run whether user is logged on or not
   - ✅ Run with highest privileges
   - Account: a user with SQL Server `db_backupoperator` or `sysadmin` rights
6. **Trigger tab:** Set schedule (e.g., daily at 2:00 AM)
7. **Action tab:**
   - **Program:** `C:\Scripts\Backup-SqlExpressDB.bat`
   - **Start in:** `C:\Scripts`
8. **Settings tab:**
   - ✅ Allow task to be run on demand
   - ✅ Stop the task if it runs longer than 1 hour
