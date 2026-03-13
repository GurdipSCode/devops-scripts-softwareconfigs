#Requires -RunAsAdministrator
# ============================================================================
# SQL Server Security Hardening & Best Practices
# Covers: Lock Pages, Max Memory, TempDB, SA, Protocols, Auditing, TLS
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Info { param([string]$m) Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  $m" -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host "  $m" -ForegroundColor Red }

trap {
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Red
    Write-Host " SCRIPT ERROR" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "  Error : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Line  : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host "  Cmd   : $($_.InvocationInfo.Line.Trim())" -ForegroundColor Red
    Write-Host ""
    continue
}

# ============================================================================
# CONFIG — adjust to match your environment
# ============================================================================
$SqlInstance       = "localhost"          # SQL instance e.g. localhost\SQLEXPRESS
$MaxMemoryMB       = 4096                 # Max server memory in MB — leave ~2GB for OS
$TempDbFileCount   = 4                    # Recommended: match logical CPU count up to 8
$SqlServiceAccount = "NT SERVICE\MSSQLSERVER"  # Account running SQL Server service
# ============================================================================

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " SQL Server Security Hardening" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Warn "Review the CONFIG section at the top before running."
Write-Host ""
Read-Host "Press Enter to continue or Ctrl+C to abort"

# ============================================================================
# SECTION 1: DETECT SQL INSTANCE
# ============================================================================
Write-Host "`n[1/10] Detecting SQL Server instance..." -ForegroundColor Yellow

$sqlCmd = Get-Command sqlcmd -ErrorAction SilentlyContinue
if (-not $sqlCmd) {
    Write-Warn "sqlcmd not found in PATH — trying common install paths..."
    $sqlCmdPaths = @(
        "C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe",
        "C:\Program Files\Microsoft SQL Server\110\Tools\Binn\sqlcmd.exe",
        "C:\Program Files\Microsoft SQL Server\120\Tools\Binn\sqlcmd.exe",
        "C:\Program Files\Microsoft SQL Server\130\Tools\Binn\sqlcmd.exe",
        "C:\Program Files\Microsoft SQL Server\140\Tools\Binn\sqlcmd.exe",
        "C:\Program Files\Microsoft SQL Server\150\Tools\Binn\sqlcmd.exe",
        "C:\Program Files\Microsoft SQL Server\160\Tools\Binn\sqlcmd.exe"
    )
    foreach ($p in $sqlCmdPaths) {
        if (Test-Path $p) { $sqlCmd = $p; break }
    }
}

if (-not $sqlCmd) {
    Write-Bad "sqlcmd not found. Install SQL Server Management Tools or add sqlcmd to PATH."
    exit 1
}

$sqlExe = if ($sqlCmd -is [string]) { $sqlCmd } else { $sqlCmd.Source }
Write-Ok "Using sqlcmd: $sqlExe"

function Invoke-Sql {
    param([Parameter(Mandatory)][string]$Query, [string]$Database = "master")
    try {
        $result = & $sqlExe -S $SqlInstance -d $Database -Q $Query -b -W 2>&1
        return $result
    } catch {
        Write-Warn "SQL execution failed: $($_.Exception.Message)"
        return $null
    }
}

# Test connection
$testResult = Invoke-Sql -Query "SELECT @@VERSION"
if ($testResult -match "SQL Server") {
    Write-Ok "Connected to SQL Server on $SqlInstance"
    Write-Info ($testResult | Select-Object -First 1)
} else {
    Write-Bad "Could not connect to $SqlInstance. Check instance name and that SQL Server is running."
    exit 1
}

# ============================================================================
# SECTION 2: LOCK PAGES IN MEMORY (LPIM)
# ============================================================================
Write-Host "`n[2/10] Configuring Lock Pages in Memory..." -ForegroundColor Yellow

# LPIM prevents Windows from paging out SQL Server buffer pool — critical for performance
# Must be set via Local Security Policy for the SQL service account

try {
    $tempInf = "$env:TEMP\lpim_policy.inf"
    $tempDb  = "$env:TEMP\lpim_policy.sdb"

    # Export current security policy
    secedit /export /cfg $tempInf /quiet

    $policyContent = Get-Content $tempInf -Raw -ErrorAction Stop

    # Check if already configured
    if ($policyContent -match "SeLockMemoryPrivilege") {
        Write-Warn "SeLockMemoryPrivilege already configured in policy"
        $current = ($policyContent | Select-String "SeLockMemoryPrivilege").ToString()
        Write-Info "Current: $current"

        # Add service account if not already there
        if ($policyContent -notmatch [regex]::Escape($SqlServiceAccount)) {
            $policyContent = $policyContent -replace "(SeLockMemoryPrivilege\s*=\s*.*)", "`$1,*S-1-5-80-0"
            Write-Info "Appended SQL service account to existing LPIM policy"
        } else {
            Write-Ok "SQL service account already has Lock Pages in Memory"
        }
    } else {
        # Add the privilege
        $policyContent += "`n[Privilege Rights]`nSeLockMemoryPrivilege = $SqlServiceAccount`n"
        Write-Info "Added SeLockMemoryPrivilege for $SqlServiceAccount"
    }

    Set-Content $tempInf -Value $policyContent -Force
    secedit /configure /db $tempDb /cfg $tempInf /quiet
    Remove-Item $tempInf, $tempDb -Force -ErrorAction SilentlyContinue
    Write-Ok "Lock Pages in Memory configured — requires SQL Server service restart"
} catch {
    Write-Warn "LPIM configuration failed: $($_.Exception.Message)"
    Write-Warn "Set manually: Local Security Policy > User Rights Assignment > Lock pages in memory"
}

# Enable LPIM in SQL Server (trace flag 845 not needed on Standard/Enterprise with proper LPIM)
Invoke-Sql -Query "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;" | Out-Null
Write-Ok "Advanced options enabled"

# ============================================================================
# SECTION 3: MAX SERVER MEMORY
# ============================================================================
Write-Host "`n[3/10] Setting Max Server Memory..." -ForegroundColor Yellow

# Get total RAM
$totalRamMB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
Write-Info "Total RAM: ${totalRamMB}MB"
Write-Info "Setting Max Server Memory to: ${MaxMemoryMB}MB"
Write-Info "Reserved for OS: $($totalRamMB - $MaxMemoryMB)MB"

if ($MaxMemoryMB -ge $totalRamMB) {
    Write-Warn "MaxMemoryMB ($MaxMemoryMB) >= total RAM ($totalRamMB) — capping at $($totalRamMB - 2048)MB"
    $MaxMemoryMB = $totalRamMB - 2048
}

Invoke-Sql -Query "EXEC sp_configure 'max server memory (MB)', $MaxMemoryMB; RECONFIGURE WITH OVERRIDE;" | Out-Null
Invoke-Sql -Query "EXEC sp_configure 'min server memory (MB)', 512; RECONFIGURE WITH OVERRIDE;" | Out-Null
Write-Ok "Max server memory set to ${MaxMemoryMB}MB, min set to 512MB"

# ============================================================================
# SECTION 4: TEMPDB OPTIMISATION
# ============================================================================
Write-Host "`n[4/10] Optimising TempDB..." -ForegroundColor Yellow

# Get current TempDB file count
$tempDbFiles = Invoke-Sql -Query "SELECT COUNT(*) FROM tempdb.sys.database_files WHERE type = 0"
Write-Info "Current TempDB data files: $($tempDbFiles | Select-Object -Last 1)"

# Set TempDB to equal-sized files, autogrowth off on percentage
$tempDbSizeMB  = 256
$tempDbGrowth  = 256

# Add TempDB files if needed
for ($i = 2; $i -le $TempDbFileCount; $i++) {
    $addFile = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM tempdb.sys.database_files WHERE name = 'tempdev$i')
BEGIN
    ALTER DATABASE tempdb ADD FILE (
        NAME = N'tempdev$i',
        FILENAME = N'$(Invoke-Sql -Query "SELECT physical_name FROM tempdb.sys.database_files WHERE file_id=1" | Select-Object -Last 1 | ForEach-Object { Split-Path $_ -Parent })\tempdb$i.ndf',
        SIZE = ${tempDbSizeMB}MB,
        FILEGROWTH = ${tempDbGrowth}MB
    )
END
"@
    Invoke-Sql -Query $addFile | Out-Null
}

# Set all TempDB files to consistent size and fixed growth
Invoke-Sql -Query @"
USE master;
ALTER DATABASE tempdb MODIFY FILE (NAME = N'tempdev', SIZE = ${tempDbSizeMB}MB, FILEGROWTH = ${tempDbGrowth}MB);
ALTER DATABASE tempdb MODIFY FILE (NAME = N'templog', SIZE = 64MB, FILEGROWTH = 64MB);
"@ | Out-Null

Write-Ok "TempDB configured: $TempDbFileCount data files at ${tempDbSizeMB}MB each, ${tempDbGrowth}MB fixed growth"

# ============================================================================
# SECTION 5: SECURITY — SA ACCOUNT & AUTHENTICATION
# ============================================================================
Write-Host "`n[5/10] Hardening SA account and authentication..." -ForegroundColor Yellow

# Disable SA account (use Windows auth or named SQL account instead)
Invoke-Sql -Query "ALTER LOGIN [sa] DISABLE;" | Out-Null
Write-Ok "SA account disabled"

# Rename SA to obscure it (even disabled, rename reduces attack surface)
Invoke-Sql -Query "ALTER LOGIN [sa] WITH NAME = [sql_disabled_sa];" | Out-Null
Write-Ok "SA account renamed to sql_disabled_sa"

# Ensure Windows Authentication mode is preferred — check current mode
$authMode = Invoke-Sql -Query "SELECT SERVERPROPERTY('IsIntegratedSecurityOnly')"
if ($authMode -match "1") {
    Write-Ok "Authentication mode: Windows Authentication only (most secure)"
} else {
    Write-Warn "Authentication mode: Mixed Mode (SQL + Windows) — consider switching to Windows only if possible"
}

# Enforce password policy on all SQL logins
$sqlLogins = Invoke-Sql -Query "SELECT name FROM sys.sql_logins WHERE is_policy_checked = 0 AND name != 'sql_disabled_sa'"
if ($sqlLogins) {
    Write-Warn "SQL logins without password policy enforcement: $sqlLogins"
}
Invoke-Sql -Query @"
DECLARE @sql NVARCHAR(MAX) = ''
SELECT @sql += 'ALTER LOGIN [' + name + '] WITH CHECK_POLICY = ON, CHECK_EXPIRATION = ON; '
FROM sys.sql_logins
WHERE is_disabled = 0 AND name NOT IN ('sql_disabled_sa')
EXEC sp_executesql @sql
"@ | Out-Null
Write-Ok "Password policy enforced on all enabled SQL logins"

# ============================================================================
# SECTION 6: SURFACE AREA REDUCTION
# ============================================================================
Write-Host "`n[6/10] Reducing SQL Server surface area..." -ForegroundColor Yellow

$surfaceConfigs = @(
    @{ Name = "xp_cmdshell";                  Value = 0; Desc = "xp_cmdshell disabled" },
    @{ Name = "Ole Automation Procedures";     Value = 0; Desc = "OLE Automation disabled" },
    @{ Name = "Ad Hoc Distributed Queries";    Value = 0; Desc = "Ad Hoc Distributed Queries disabled" },
    @{ Name = "Database Mail XPs";             Value = 0; Desc = "Database Mail XPs disabled" },
    @{ Name = "SMB file share access";         Value = 0; Desc = "SMB file share access disabled" },
    @{ Name = "remote admin connections";      Value = 0; Desc = "Remote DAC disabled" },
    @{ Name = "clr enabled";                   Value = 0; Desc = "CLR disabled" },
    @{ Name = "clr strict security";           Value = 1; Desc = "CLR strict security enabled" },
    @{ Name = "cross db ownership chaining";   Value = 0; Desc = "Cross-DB ownership chaining disabled" },
    @{ Name = "scan for startup procs";        Value = 0; Desc = "Startup procedures scan disabled" }
)

foreach ($cfg in $surfaceConfigs) {
    $result = Invoke-Sql -Query "EXEC sp_configure '$($cfg.Name)', $($cfg.Value); RECONFIGURE WITH OVERRIDE;"
    if ($result -notmatch "Error") {
        Write-Ok $cfg.Desc
    } else {
        Write-Warn "Could not set '$($cfg.Name)': $result"
    }
}

# ============================================================================
# SECTION 7: NETWORK PROTOCOLS
# ============================================================================
Write-Host "`n[7/10] Hardening SQL Server network protocols..." -ForegroundColor Yellow

# Disable Named Pipes, enable TCP only
try {
    $sqlWmiNS = "root\Microsoft\SqlServer\ComputerManagement16"
    $altNS    = @(
        "root\Microsoft\SqlServer\ComputerManagement16",
        "root\Microsoft\SqlServer\ComputerManagement15",
        "root\Microsoft\SqlServer\ComputerManagement14",
        "root\Microsoft\SqlServer\ComputerManagement13",
        "root\Microsoft\SqlServer\ComputerManagement12",
        "root\Microsoft\SqlServer\ComputerManagement11"
    )

    $wmiNS = $null
    foreach ($ns in $altNS) {
        try {
            $test = Get-WmiObject -Namespace $ns -Class ServerNetworkProtocol -ErrorAction Stop
            if ($test) { $wmiNS = $ns; break }
        } catch {}
    }

    if ($wmiNS) {
        # Disable Named Pipes
        $np = Get-WmiObject -Namespace $wmiNS -Class ServerNetworkProtocol |
              Where-Object { $_.ProtocolName -eq "Np" }
        if ($np) { $np.SetEnable(0) | Out-Null; Write-Ok "Named Pipes disabled" }

        # Disable Shared Memory (external connections only — local is fine)
        # Keep Shared Memory enabled for local tools

        # Enable TCP
        $tcp = Get-WmiObject -Namespace $wmiNS -Class ServerNetworkProtocol |
               Where-Object { $_.ProtocolName -eq "Tcp" }
        if ($tcp) { $tcp.SetEnable(1) | Out-Null; Write-Ok "TCP/IP enabled" }

        Write-Ok "Network protocols configured via WMI"
    } else {
        Write-Warn "Could not find SQL WMI namespace — configure protocols manually in SQL Server Configuration Manager"
    }
} catch {
    Write-Warn "WMI protocol config failed: $($_.Exception.Message)"
}

# ============================================================================
# SECTION 8: TLS ENFORCEMENT
# ============================================================================
Write-Host "`n[8/10] Enforcing TLS for SQL Server connections..." -ForegroundColor Yellow

# Find SQL Server registry key
$sqlRegPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\SuperSocketNetLib",
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib",
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL14.MSSQLSERVER\MSSQLServer\SuperSocketNetLib",
    "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL13.MSSQLSERVER\MSSQLServer\SuperSocketNetLib"
)

$sqlRegPath = $sqlRegPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($sqlRegPath) {
    Set-ItemProperty -Path $sqlRegPath -Name "ForceEncryption" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $sqlRegPath -Name "HideInstance"    -Value 1 -Type DWord -Force
    Write-Ok "Force encryption enabled for SQL Server connections"
    Write-Ok "SQL Server instance hidden from browser service"
} else {
    Write-Warn "SQL Server registry path not found — set ForceEncryption manually in SQL Server Configuration Manager > Protocols > Properties"
}

# ============================================================================
# SECTION 9: AUDITING
# ============================================================================
Write-Host "`n[9/10] Configuring SQL Server auditing..." -ForegroundColor Yellow

# Enable C2 audit trace (logs all activity — high overhead, use SQL Audit in prod instead)
# Using SQL Server Audit (lighter weight) for failed logins
Invoke-Sql -Query "EXEC sp_configure 'c2 audit mode', 0; RECONFIGURE;" | Out-Null

# Enable failed + successful login auditing
$auditQuery = @"
USE master;
EXEC xp_instance_regwrite
    N'HKEY_LOCAL_MACHINE',
    N'Software\Microsoft\MSSQLServer\MSSQLServer',
    N'AuditLevel',
    REG_DWORD,
    3;
"@
Invoke-Sql -Query $auditQuery | Out-Null
Write-Ok "Login auditing set to: Both failed and successful logins"

# Create a server audit for security events if it doesn't exist
$auditSetup = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = 'SecurityAudit')
BEGIN
    CREATE SERVER AUDIT [SecurityAudit]
    TO FILE (FILEPATH = 'C:\SQLAudit\', MAXSIZE = 100MB, MAX_ROLLOVER_FILES = 10, RESERVE_DISK_SPACE = OFF)
    WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);

    ALTER SERVER AUDIT [SecurityAudit] WITH (STATE = ON);

    CREATE SERVER AUDIT SPECIFICATION [SecurityAuditSpec]
    FOR SERVER AUDIT [SecurityAudit]
    ADD (FAILED_LOGIN_GROUP),
    ADD (SUCCESSFUL_LOGIN_GROUP),
    ADD (LOGOUT_GROUP),
    ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
    ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),
    ADD (SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP),
    ADD (SERVER_PERMISSION_CHANGE_GROUP),
    ADD (SERVER_OBJECT_PERMISSION_CHANGE_GROUP)
    WITH (STATE = ON);
END
"@

# Create audit directory
if (-not (Test-Path "C:\SQLAudit")) {
    New-Item -ItemType Directory -Path "C:\SQLAudit" -Force | Out-Null
    Write-Ok "Created C:\SQLAudit directory"
}

Invoke-Sql -Query $auditSetup | Out-Null
Write-Ok "SQL Server audit configured — logs to C:\SQLAudit"

# ============================================================================
# SECTION 10: ADDITIONAL BEST PRACTICES
# ============================================================================
Write-Host "`n[10/10] Applying additional best practices..." -ForegroundColor Yellow

# Instant File Initialization — grant to SQL service account
Write-Info "Configuring Instant File Initialization (IFI)..."
try {
    $tempInfIFI = "$env:TEMP\ifi_policy.inf"
    $tempDbIFI  = "$env:TEMP\ifi_policy.sdb"
    secedit /export /cfg $tempInfIFI /quiet
    $ifiContent = Get-Content $tempInfIFI -Raw
    if ($ifiContent -notmatch "SeManageVolumePrivilege") {
        $ifiContent += "`nSeManageVolumePrivilege = $SqlServiceAccount`n"
    }
    Set-Content $tempInfIFI -Value $ifiContent -Force
    secedit /configure /db $tempDbIFI /cfg $tempInfIFI /quiet
    Remove-Item $tempInfIFI, $tempDbIFI -Force -ErrorAction SilentlyContinue
    Write-Ok "Instant File Initialization granted to $SqlServiceAccount"
} catch {
    Write-Warn "IFI config failed: $($_.Exception.Message)"
}

# Optimize for ad hoc workloads
Invoke-Sql -Query "EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;" | Out-Null
Write-Ok "Optimize for ad hoc workloads enabled"

# Cost threshold for parallelism (default 5 is too low)
Invoke-Sql -Query "EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE;" | Out-Null
Write-Ok "Cost threshold for parallelism set to 50"

# Max degree of parallelism — set to half logical CPUs, max 8
$logicalCPUs  = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$maxDop       = [math]::Min([math]::Floor($logicalCPUs / 2), 8)
$maxDop       = [math]::Max($maxDop, 1)
Invoke-Sql -Query "EXEC sp_configure 'max degree of parallelism', $maxDop; RECONFIGURE;" | Out-Null
Write-Ok "MAXDOP set to $maxDop (logical CPUs: $logicalCPUs)"

# Backup compression
Invoke-Sql -Query "EXEC sp_configure 'backup compression default', 1; RECONFIGURE;" | Out-Null
Write-Ok "Backup compression enabled by default"

# Remote access disabled
Invoke-Sql -Query "EXEC sp_configure 'remote access', 0; RECONFIGURE WITH OVERRIDE;" | Out-Null
Write-Ok "Remote access disabled"

# Apply all reconfigurations
Invoke-Sql -Query "RECONFIGURE WITH OVERRIDE;" | Out-Null

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host " SQL Server Hardening Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "REQUIRES SQL SERVER SERVICE RESTART:" -ForegroundColor Yellow
Write-Host "  - Lock Pages in Memory" -ForegroundColor Yellow
Write-Host "  - Force Encryption (TLS)" -ForegroundColor Yellow
Write-Host "  - Named Pipes disabled" -ForegroundColor Yellow
Write-Host "  - Instance hidden from browser" -ForegroundColor Yellow
Write-Host ""
Write-Host "VERIFY MANUALLY:" -ForegroundColor Yellow
Write-Host "  - TempDB file locations are on fast storage" -ForegroundColor Yellow
Write-Host "  - Max Memory ($MaxMemoryMB MB) is appropriate for your workload" -ForegroundColor Yellow
Write-Host "  - SQL Audit path C:\SQLAudit has sufficient disk space" -ForegroundColor Yellow
Write-Host "  - MAXDOP ($maxDop) suits your query workload" -ForegroundColor Yellow
Write-Host ""

$restart = Read-Host "Restart SQL Server service now to apply all changes? (y/n)"
if ($restart -eq 'y') {
    try {
        $svcName = Get-Service | Where-Object { $_.DisplayName -like "*SQL Server (*" -and $_.DisplayName -notlike "*Agent*" -and $_.DisplayName -notlike "*Browser*" } | Select-Object -First 1
        if ($svcName) {
            Write-Bad "Restarting: $($svcName.DisplayName)..."
            Restart-Service -Name $svcName.Name -Force
            Write-Ok "SQL Server service restarted"
        } else {
            Write-Warn "Could not find SQL Server service — restart manually"
        }
    } catch {
        Write-Warn "Service restart failed: $($_.Exception.Message)"
        Write-Warn "Restart manually: Restart-Service MSSQLSERVER"
    }
}
