# SQL Express Backup

PowerShell-based backup solution for SQL Express databases using `sqlcmd`. Supports multi-database configs, auto-discovery of all user databases, retention cleanup, integrity verification, SMTP email reports, and dry-run testing.

---

### Files

| File                       | Purpose                                           |
| -------------------------- | ------------------------------------------------- |
| `Backup-SqlExpressDB.ps1`  | Main script — backup, verify, cleanup, email      |
| `Backup-SqlExpressDB.json` | Config file — databases, retention, SMTP settings |
| `Backup-SqlExpressDB.bat`  | Batch launcher for Task Scheduler                 |

### Requirements

- Windows with PowerShell 5.1+
- SQL Server command-line tools (`sqlcmd` in PATH)

### How It Works

- Reads `Backup-SqlExpressDB.json` for databases, backup paths, retention counts, and SMTP settings
- When `BackupAllUserDatabases` is enabled, queries `sys.databases` to auto-discover all user databases. Per-database overrides in the `Databases` array are merged with defaults.
- Loops through each database and for each one:
  - Verifies the database exists on the SQL instance via `sqlcmd`
  - Runs `BACKUP DATABASE ... WITH INIT, CHECKSUM` via `sqlcmd`
  - Verifies the backup file with `RESTORE VERIFYONLY ... WITH CHECKSUM`
  - Applies retention policy — keeps the newest N backups, deletes the rest
- Sends an HTML email summary via SMTP with per-database status and config overview
- Rotates the log file on each run (keeps last 5 copies, logrotate-style)
- Also supports single-database mode via command-line parameters (no config file needed)

### Installation

1. Clone the repo
    ```powershell
    # Clone (or download and extract the zip) to a folder of your choice
    git clone https://github.com/jchimp/sqlexpress-backup.git C:\Scripts\sqlexpress-backup

    # Or just clone from your root folder (git will create the sub-folder)
    git clone https://github.com/jchimp/sqlexpress-backup.git
    ```
2. Edit `Backup-SqlExpressDB.json` with your databases, SMTP, and backup paths
3. Test with a dry run:
    ```powershell
    .\Backup-SqlExpressDB.ps1 -DryRun
    ```
4. Run it for real or set up a [Scheduled Task](#setting-up-the-scheduled-task)

## Usage Examples

### Command Line

```powershell
# Auto-detect config file from same folder
.\Backup-SQLExpressDB.ps1

# Dry run with auto-detected config file
.\Backup-SQLExpressDB.ps1 -DryRun

# Use an explicit config file
.\Backup-SQLExpressDB.ps1 -ConfigFile "C:\Scripts\Backup-SQLExpressDB.json"

# Single database mode - parameterized
.\Backup-SQLExpressDB.ps1 -DatabaseName "SalesDB" -BackupPath "D:\Backups\SalesDB" -RetainCount 7

# Single database mode - parameterized dry run
.\Backup-SQLExpressDB.ps1 -DatabaseName "SalesDB" -BackupPath "D:\Backups\SalesDB" -RetainCount 7 -DryRun
```

### Via BAT launcher (for Task Scheduler or other tools)

```bat
C:\Scripts\Backup-SqlExpressDB.bat
```

### Setting Up the Scheduled Task

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

---

## Config File

### Example A: Backup All User Databases

The simplest setup — auto-discovers and backs up every user database on the instance. Each database gets a subfolder under `DefaultBackupPath`.

```json
{
    "ServerInstance": ".\\SQLEXPRESS",
    "RetainCount": 7,
    "DefaultBackupPath": "D:\\Backups",
    "BackupAllUserDatabases": true,
    "LogFile": "D:\\Backups\\Backup-SQLExpress_Log.log",

    "Smtp": {
        "Server": "mail.yourdomain.com",
        "Port": 25,
        "From": "backups@yourdomain.com",
        "To": ["admin@yourdomain.com", "user@yourdomain.com"],
        "UseSsl": false,
        "Username": "",
        "Password": "",
        "SendOnSuccess": true,
        "SendOnFailure": true
    },

    "Databases": []
}
```

> With `BackupAllUserDatabases` enabled, the `Databases` array can be empty or used for per-database overrides (custom retention, backup path, or instance).

### Example B: Selective Databases

Explicit list — only the databases you specify are backed up. Per-database fields are optional and fall back to global defaults.

```json
{
    "ServerInstance": ".\\SQLEXPRESS",
    "RetainCount": 7,
    "DefaultBackupPath": "D:\\Backups",
    "BackupAllUserDatabases": false,
    "LogFile": "D:\\Backups\\Backup-SQLExpress_Log.log",

    "Smtp": { "..." : "see Example A" },

    "Databases": [
        {
            "Name": "SalesDB"
        },
        {
            "Name": "InventoryDB",
            "BackupPath": "E:\\CriticalBackups\\InventoryDB",
            "RetainCount": 14
        }
    ]
}
```

> `SalesDB` inherits `DefaultBackupPath` (`D:\Backups\SalesDB\`) and `RetainCount` (7). `InventoryDB` overrides both.

---

### Config File Parameters

| Parameter                    | Scope  | Required | Default                    | Description                                                  |
| ---------------------------- | ------ | -------- | -------------------------- | ------------------------------------------------------------ |
| `ServerInstance`             | Global | No       | `.\SQLEXPRESS`             | Default SQL Server instance                                  |
| `RetainCount`                | Global | No       | `5`                        | Default number of backups to keep                            |
| `DefaultBackupPath`          | Global | No       | *(none)*                   | Base path for auto-generated backup folders (`path\DbName`)  |
| `BackupAllUserDatabases`     | Global | No       | `false`                    | Auto-discover and back up all user databases on the instance |
| `LogFile`                    | Global | No       | *(none)*                   | Append all output to this file (rotated, keeps last 5)       |
| `Smtp.Server`                | Global | No       | *(none)*                   | SMTP relay hostname                                          |
| `Smtp.Port`                  | Global | No       | `25`                       | SMTP port                                                    |
| `Smtp.From`                  | Global | No       | —                          | Sender email address                                         |
| `Smtp.To`                    | Global | No       | —                          | Array of recipient email addresses                           |
| `Smtp.UseSsl`                | Global | No       | `false`                    | Enable SSL/TLS                                               |
| `Smtp.Username`              | Global | No       | *(empty)*                  | SMTP auth username (leave empty for relay)                   |
| `Smtp.Password`              | Global | No       | *(empty)*                  | SMTP auth password                                           |
| `Smtp.SendOnSuccess`         | Global | No       | `true`                     | Send email when all backups succeed                          |
| `Smtp.SendOnFailure`         | Global | No       | `true`                     | Send email when any backup fails                             |
| `Databases[].Name`           | Per-DB | **Yes**  | —                          | Database name                                                |
| `Databases[].BackupPath`     | Per-DB | No       | `DefaultBackupPath\DbName` | Backup destination folder                                    |
| `Databases[].RetainCount`    | Per-DB | No       | *(global)*                 | Override retention for this database                         |
| `Databases[].ServerInstance` | Per-DB | No       | *(global)*                 | Override SQL instance for this database                      |
