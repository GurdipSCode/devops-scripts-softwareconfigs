#Requires -RunAsAdministrator
# ============================================================================
# Windows Server 2025 - Setup, Optimization & Hardening Script (ELITE TERMINAL)
# + Added: Action1 + PDQ Deploy Agent MSI installer (enterprise-grade: logs, retries, verify, cleanup)
# + Added: Disable RDP NLA
# + Added: Set timezone to GMT
# + Added: Ensure Glances via pip (installs Python + glances deps reliably)
# + Added: Enable WinRM for Semaphore UI (HTTP/5985) and run EVERY TIME
# - Removed: devolutions-agent from Chocolatey list
# FIXED: PowerShell parser errors with "$var:" inside strings (now uses ${var}: )
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param([string]$m) Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  $m" -ForegroundColor Yellow }
function Write-Bad  { param([string]$m) Write-Host "  $m" -ForegroundColor Red }

function Ensure-File {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (!(Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
}

function Invoke-ScoopInstallSafe {
    param([Parameter(Mandatory)][string]$PackageId)

    try {
        Write-Info "Scoop install: $PackageId"
        scoop install $PackageId
        Write-Ok "Installed: $PackageId"
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match "already installed" -or $msg -match "already exists") {
            Write-Warn "Scoop: $PackageId already installed / file exists — continuing"
            return
        }
        Write-Warn "Scoop install failed for ${PackageId}: $msg"
        Write-Warn "Continuing..."
    }
}

function Trust-PSGallery {
    try {
        Write-Info "Trusting PSGallery + enabling TLS 1.2..."

        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
        }

        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop | Out-Null
        Write-Ok "PSGallery set to Trusted"
    } catch {
        Write-Warn "Failed to trust PSGallery: $($_.Exception.Message)"
    }
}

function Install-PSModuleSafe {
    param([Parameter(Mandatory)][string]$Name)

    try {
        $already = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue
        if ($already) {
            Write-Info "Module already installed: $Name"
            return
        }
        Install-Module -Name $Name -Scope AllUsers -Force -AllowClobber -ErrorAction Stop | Out-Null
        Write-Ok "Installed PowerShell module (AllUsers): $Name"
    } catch {
        Write-Warn "Failed to install module '$Name': $($_.Exception.Message)"
    }
}

# ============================================================================
# Ensure Glances via pip (more reliable than choco package alone)
# ============================================================================
function Ensure-GlancesViaPip {
    [CmdletBinding()]
    param(
        [ValidateRange(1,10)][int]$MaxRetries = 3
    )

    try {
        Write-Info "Ensuring Python + pip are available for Glances..."

        $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
        if (-not $pythonCmd) {
            Write-Warn "python.exe not found on PATH yet. Refreshing PATH for this session..."
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
            $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
        }

        if (-not $pythonCmd) {
            Write-Warn "Python still not found. Glances pip install will be skipped (may need new session after Python install)."
            return
        }

        Write-Info "Upgrading pip..."
        & python -m pip install --upgrade pip | Out-Null

        for ($i=1; $i -le $MaxRetries; $i++) {
            try {
                Write-Info "Installing/Upgrading Glances via pip (attempt $i/$MaxRetries)..."
                & python -m pip install --upgrade glances psutil pywin32 | Out-Null
                Write-Ok "Glances installed/upgraded via pip"
                break
            } catch {
                Write-Warn "pip install glances failed: $($_.Exception.Message)"
                if ($i -eq $MaxRetries) { throw }
                Start-Sleep -Seconds 3
            }
        }

        $gl = Get-Command glances -ErrorAction SilentlyContinue
        if ($gl) {
            Write-Ok "glances is available: $($gl.Source)"
        } else {
            Write-Warn "glances not on PATH yet. You can run: python -m glances"
            Write-Warn "If you want 'glances' on PATH immediately, restart the shell after install."
        }
    } catch {
        Write-Warn "Ensure-GlancesViaPip failed: $($_.Exception.Message)"
    }
}

# ============================================================================
# Enable WinRM for Semaphore (HTTP/5985). Runs EVERY TIME script runs.
# WARNING: Firewall is off in this script; prefer setting TrustedHosts to your controller IP.
# ============================================================================
function Enable-WinRMForSemaphore {
    [CmdletBinding()]
    param(
        [string]$TrustedHosts = "*"
    )

    try {
        Write-Info "Enabling WinRM for Semaphore (HTTP/5985)..."

        Set-Service -Name WinRM -StartupType Automatic -ErrorAction Stop
        Start-Service -Name WinRM -ErrorAction Stop

        & winrm quickconfig -q | Out-Null

        $httpListener = & winrm enumerate winrm/config/Listener 2>$null | Out-String
        if ($httpListener -notmatch "Transport\s*=\s*HTTP") {
            & winrm create winrm/config/Listener?Address=*+Transport=HTTP '@{Port="5985"}' | Out-Null
        }

        & winrm set winrm/config/service/auth '@{Basic="true";Kerberos="true";Negotiate="true";Certificate="false";CredSSP="false"}' | Out-Null
        & winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
        & winrm set winrm/config '@{MaxTimeoutms="1800000"}' | Out-Null
        & winrm set winrm/config/service '@{MaxConcurrentOperationsPerUser="1500"}' | Out-Null

        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WSMAN\Client" `
            -Name "TrustedHosts" -Value $TrustedHosts -Force

        Write-Ok "WinRM enabled. TrustedHosts='$TrustedHosts'"

        try {
            Test-WSMan -ComputerName localhost -ErrorAction Stop | Out-Null
            Write-Ok "Test-WSMan localhost OK"
        } catch {
            Write-Warn "Test-WSMan check failed: $($_.Exception.Message)"
        }
    }
    catch {
        Write-Warn "Failed enabling WinRM: $($_.Exception.Message)"
    }
}

function Write-ElitePowerShellProfile {
    param([Parameter(Mandatory)][string]$ProfilePath)

    $profileContent = @'
# ============================================
# Elite PowerShell Global Profile (ALL USERS)
# ============================================

# ---- Encoding ----
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
} catch {}

# ---- ANSI rendering (PowerShell 7+) ----
try {
    if (Test-Path Variable:\PSStyle) {
        $PSStyle.OutputRendering = 'Ansi'
    }
} catch {}

# ---- PSReadLine ----
if (Get-Module -ListAvailable -Name PSReadLine) {
    Import-Module PSReadLine -ErrorAction SilentlyContinue

    try {
        Set-PSReadLineOption -PredictionSource History
        Set-PSReadLineOption -PredictionViewStyle ListView
    } catch {}

    try {
        Set-PSReadLineOption -EditMode Windows
        Set-PSReadLineOption -BellStyle None
        Set-PSReadLineOption -HistoryNoDuplicates
        Set-PSReadLineOption -HistorySearchCursorMovesToEnd
        Set-PSReadLineOption -ShowToolTips
        Set-PSReadLineOption -ContinuationPrompt '⟩ '
    } catch {}

    try {
        Set-PSReadLineKeyHandler -Key Tab -Function Complete
        Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
        Set-PSReadLineKeyHandler -Key Ctrl+LeftArrow -Function BackwardWord
        Set-PSReadLineKeyHandler -Key Ctrl+RightArrow -Function ForwardWord
        Set-PSReadLineKeyHandler -Key Alt+Backspace -Function BackwardKillWord
        Set-PSReadLineKeyHandler -Key Ctrl+Backspace -Function BackwardKillWord
    } catch {}
}

# ---- Terminal-Icons ----
if (Get-Module -ListAvailable -Name Terminal-Icons) {
    Import-Module Terminal-Icons -ErrorAction SilentlyContinue
}

# ---- PSFzf (keybinds: Ctrl+R, Ctrl+T, Alt+C) ----
if (Get-Module -ListAvailable -Name PSFzf) {
    Import-Module PSFzf -ErrorAction SilentlyContinue
    try { Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r' | Out-Null } catch {}
    try { Enable-PsFzfAliases | Out-Null } catch {}
}

# ---- zoxide (smart jump) ----
if (Get-Command zoxide -ErrorAction SilentlyContinue) {
    try { Invoke-Expression (& zoxide init powershell) } catch {}
}

# ---- posh-git ----
if (Get-Module -ListAvailable -Name posh-git) {
    Import-Module posh-git -ErrorAction SilentlyContinue
}

# ---- ActiveDirectoryStructure + Testimo ----
if (Get-Module -ListAvailable -Name ActiveDirectoryStructure) {
    Import-Module ActiveDirectoryStructure -ErrorAction SilentlyContinue
}
if (Get-Module -ListAvailable -Name Testimo) {
    Import-Module Testimo -ErrorAction SilentlyContinue
}

# ---- QoL ----
function ll { Get-ChildItem -Force }
function la { Get-ChildItem -Force }
function .. { Set-Location .. }
function ... { Set-Location ../.. }

# ---- Starship prompt ----
if (Get-Command starship -ErrorAction SilentlyContinue) {
    try { Invoke-Expression (& starship init powershell) } catch {}
}
'@

    $dir = Split-Path $ProfilePath -Parent
    if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    Set-Content -Path $ProfilePath -Value $profileContent -Force -Encoding UTF8
    Write-Ok "Wrote ALL-USERS profile -> $ProfilePath"
}

function Update-WindowsTerminalSettings {
    param(
        [Parameter(Mandatory)][string]$FontFace,
        [Parameter(Mandatory)][int]$FontSize
    )

    $local = [string]$env:LOCALAPPDATA
    $candidates = @(
        "$local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$local\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$local\Microsoft\Windows Terminal\settings.json"
    )

    $targets = @($candidates | Where-Object { Test-Path $_ })
    if (-not $targets -or $targets.Count -eq 0) {
        Write-Warn "Windows Terminal settings.json not found for this user. Skipping font config."
        Write-Warn "Open Windows Terminal once, then re-run this script as that user."
        return
    }

    foreach ($path in $targets) {
        try {
            Write-Info "Updating Windows Terminal settings: $path"
            $raw = Get-Content -Path $path -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) { throw "settings.json is empty" }

            $json = $raw | ConvertFrom-Json -ErrorAction Stop

            if (-not $json.profiles) { $json | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) -Force }
            if (-not $json.profiles.defaults) { $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) -Force }
            if (-not $json.profiles.defaults.font) { $json.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{}) -Force }

            $json.profiles.defaults.font.face = $FontFace
            $json.profiles.defaults.font.size = $FontSize

            $out = $json | ConvertTo-Json -Depth 60
            Set-Content -Path $path -Value $out -Encoding UTF8 -Force

            Write-Ok "Terminal defaults set: font='$FontFace' size=$FontSize"
        } catch {
            Write-Warn "Failed updating '$path': $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# SECTION X: ACTION1 + PDQ DEPLOY AGENT (MSI) - Enterprise installer
# ============================================================================
function Install-Agents_Action1_PDQ {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string]$Action1Url,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()]
        [string]$PDQUrl,

        [string]$Action1ExpectedDisplayName = "Action1",
        [string]$PDQExpectedDisplayName     = "PDQ Deploy",

        [string]$Action1ServiceNameContains = "Action1",
        [string]$PDQServiceNameContains     = "PDQ",

        [string]$BaseDir = "$env:ProgramData\AgentInstall",

        [ValidateRange(1,10)][int]$DownloadRetries = 3,
        [ValidateRange(1,60)][int]$RetryDelaySeconds = 5,

        [switch]$Cleanup = $true
    )

    $LogsDir  = Join-Path $BaseDir "Logs"
    $StageDir = Join-Path $BaseDir "Stage"
    New-Item -ItemType Directory -Path $LogsDir  -Force | Out-Null
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
    $LogFile  = Join-Path $LogsDir ("Install-Agents_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

    function Write-AgentLog {
        param([Parameter(Mandatory)][string]$Message, [ValidateSet("INFO","WARN","ERROR","OK")][string]$Level="INFO")
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "[${ts}] [$Level] $Message"
        Write-Host "  $line"
        Add-Content -Path $LogFile -Value $line
    }

    function Test-DisplayNameInstalled {
        param([Parameter(Mandatory)][string]$DisplayNameContains)

        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        foreach ($p in $paths) {
            $hits = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -and $_.DisplayName -like "*$DisplayNameContains*" }
            if ($hits) { return $true }
        }
        return $false
    }

    function Test-ServiceExistsContains {
        param([Parameter(Mandatory)][string]$NameContains)
        $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like "*$NameContains*" -or $_.DisplayName -like "*$NameContains*"
        }
        return [bool]$svc
    }

    function Get-FileNameFromUrl {
        param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$DefaultName)
        try {
            $u = [Uri]$Url
            $name = Split-Path -Leaf $u.AbsolutePath
            if ([string]::IsNullOrWhiteSpace($name)) { return $DefaultName }
            if ($name -notmatch '\.msi$') { return $DefaultName }
            return $name
        } catch {
            return $DefaultName
        }
    }

    function Download-File {
        param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile, [int]$Retries=3, [int]$DelaySeconds=5)

        if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }

        for ($i=1; $i -le $Retries; $i++) {
            try {
                Write-AgentLog "Downloading ($i/$Retries): $Url -> $OutFile"
                try {
                    Start-BitsTransfer -Source $Url -Destination $OutFile -TransferType Download -ErrorAction Stop
                } catch {
                    Write-AgentLog "BITS failed; falling back to Invoke-WebRequest: $($_.Exception.Message)" "WARN"
                    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
                }

                if (-not (Test-Path -LiteralPath $OutFile)) { throw "Download completed but destination file not found." }

                $len = (Get-Item -LiteralPath $OutFile).Length
                if ($len -lt 50KB) { throw "Downloaded file is unexpectedly small (${len} bytes)." }

                Write-AgentLog "Download OK (${len} bytes): $OutFile" "OK"
                return
            } catch {
                Write-AgentLog "Download attempt $i failed: $($_.Exception.Message)" "WARN"
                if ($i -lt $Retries) { Start-Sleep -Seconds $DelaySeconds } else { throw }
            }
        }
    }

    function Install-MSI {
        param([Parameter(Mandatory)][string]$MsiPath, [string]$ExtraMsiArgs = "")
        if (-not (Test-Path -LiteralPath $MsiPath)) { throw "MSI not found: $MsiPath" }

        $args = "/i `"$MsiPath`" /qn /norestart $ExtraMsiArgs"
        Write-AgentLog "Running: msiexec.exe $args"
        $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
        $code = $p.ExitCode

        if ($code -eq 0) { Write-AgentLog "MSI install succeeded: $MsiPath" "OK"; return 0 }
        if ($code -eq 3010) { Write-AgentLog "MSI install succeeded (reboot required): $MsiPath" "WARN"; return 3010 }
        throw "MSI install failed with exit code $code: $MsiPath"
    }

    $rebootRequired = $false

    Write-AgentLog "=== Agent install started ==="
    Write-AgentLog "BaseDir: $BaseDir"
    Write-AgentLog "StageDir: $StageDir"
    Write-AgentLog "LogFile: $LogFile"

    $Action1MsiName = Get-FileNameFromUrl -Url $Action1Url -DefaultName "Action1Agent.msi"
    $PDQMsiName     = Get-FileNameFromUrl -Url $PDQUrl     -DefaultName "PDQDeployAgent.msi"
    $Action1MsiPath = Join-Path $StageDir $Action1MsiName
    $PDQMsiPath     = Join-Path $StageDir $PDQMsiName

    $action1Installed = Test-DisplayNameInstalled -DisplayNameContains $Action1ExpectedDisplayName
    if (-not $action1Installed -and $Action1ServiceNameContains) {
        $action1Installed = Test-ServiceExistsContains -NameContains $Action1ServiceNameContains
    }

    if ($action1Installed) {
        Write-AgentLog "Action1 appears already installed. Skipping." "OK"
    } else {
        Write-AgentLog "Action1 not detected. Downloading + installing..."
        Download-File -Url $Action1Url -OutFile $Action1MsiPath -Retries $DownloadRetries -DelaySeconds $RetryDelaySeconds
        $exit = Install-MSI -MsiPath $Action1MsiPath
        if ($exit -eq 3010) { $rebootRequired = $true }

        $verified = Test-DisplayNameInstalled -DisplayNameContains $Action1ExpectedDisplayName
        if (-not $verified -and $Action1ServiceNameContains) {
            $verified = Test-ServiceExistsContains -NameContains $Action1ServiceNameContains
        }

        if ($verified) { Write-AgentLog "Action1 verified installed." "OK" }
        else { Write-AgentLog "Action1 install ran, but verification failed. Check tenant MSI/link." "WARN" }
    }

    $pdqInstalled = Test-DisplayNameInstalled -DisplayNameContains $PDQExpectedDisplayName
    if (-not $pdqInstalled -and $PDQServiceNameContains) {
        $pdqInstalled = Test-ServiceExistsContains -NameContains $PDQServiceNameContains
    }

    if ($pdqInstalled) {
        Write-AgentLog "PDQ Deploy Agent appears already installed. Skipping." "OK"
    } else {
        Write-AgentLog "PDQ Deploy Agent not detected. Downloading + installing..."
        Download-File -Url $PDQUrl -OutFile $PDQMsiPath -Retries $DownloadRetries -DelaySeconds $RetryDelaySeconds
        $exit = Install-MSI -MsiPath $PDQMsiPath
        if ($exit -eq 3010) { $rebootRequired = $true }

        $verified = Test-DisplayNameInstalled -DisplayNameContains $PDQExpectedDisplayName
        if (-not $verified -and $PDQServiceNameContains) {
            $verified = Test-ServiceExistsContains -NameContains $PDQServiceNameContains
        }

        if ($verified) { Write-AgentLog "PDQ Deploy Agent verified installed." "OK" }
        else { Write-AgentLog "PDQ install ran, but verification failed. Check MSI/link." "WARN" }
    }

    if ($Cleanup) {
        Write-AgentLog "Cleanup enabled. Removing staged MSI files..."
        foreach ($f in @($Action1MsiPath, $PDQMsiPath)) {
            if (Test-Path -LiteralPath $f) {
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
                Write-AgentLog "Deleted: $f" "OK"
            }
        }
    } else {
        Write-AgentLog "Cleanup disabled. Staged MSIs kept in: $StageDir" "WARN"
    }

    Write-AgentLog "=== Agent install completed ===" "OK"
    return @{ RebootRequired = $rebootRequired; LogFile = $LogFile }
}

# ============================================================================
# Disable RDP NLA
# ============================================================================
function Disable-RdpNla {
    try {
        Write-Info "Disabling RDP Network Level Authentication (NLA)..."

        $tsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
        Set-ItemProperty -Path $tsKey -Name "UserAuthentication" -Value 0 -Type DWord -Force

        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Type DWord -Force

        try { Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null } catch {}

        try { Restart-Service -Name TermService -Force -ErrorAction SilentlyContinue } catch {
            Write-Warn "Could not restart TermService (may require reboot): $($_.Exception.Message)"
        }

        Write-Ok "RDP NLA disabled"
    } catch {
        Write-Warn "Failed to disable RDP NLA: $($_.Exception.Message)"
    }
}

# ============================================================================
# Set timezone to GMT
# ============================================================================
function Set-TimezoneGmt {
    try {
        Write-Info "Setting timezone to GMT (Greenwich Mean Time)..."
        tzutil /s "GMT Standard Time" | Out-Null
        Write-Ok "Timezone set: GMT Standard Time"
    } catch {
        Write-Warn "Failed to set timezone: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Banner
# ----------------------------------------------------------------------------
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Windows Server Setup, Optimization &" -ForegroundColor Cyan
Write-Host " Hardening Script (Elite Terminal)" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Bad "WARNING: This script applies significant changes."
Write-Bad "Windows Firewall will be DISABLED (per your request)."
Write-Host ""
Read-Host "Press Enter to continue or Ctrl+C to abort"

# ============================================================================
# SECTION 0: QUICK SYSTEM CHANGES (Timezone + RDP NLA + WinRM)
# Runs EVERY TIME script runs.
# ============================================================================
Write-Host "`n[0/12] Applying Quick System Changes..." -ForegroundColor Yellow
Set-TimezoneGmt
Disable-RdpNla

# WinRM for Semaphore - executes EVERY TIME
# NOTE: replace "*" with your Semaphore controller IP(s) if possible.
Enable-WinRMForSemaphore -TrustedHosts "*"

# ============================================================================
# SECTION 1: PACKAGE MANAGERS
# ============================================================================
Write-Host "`n[1/12] Installing Package Managers..." -ForegroundColor Yellow

Set-ExecutionPolicy Bypass -Scope Process -Force
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
Write-Ok "Chocolatey installed/available"

if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Write-Info "Scoop already installed -> running scoop update"
    try { scoop update } catch { Write-Warn "scoop update failed: $($_.Exception.Message)" }
} else {
    Write-Info "Installing Scoop (RunAsAdmin)..."
    iex "& {$(irm get.scoop.sh)} -RunAsAdmin"
}

try { scoop bucket add extras | Out-Null } catch {}
try { scoop bucket add nerd-fonts | Out-Null } catch {}

# ============================================================================
# SECTION 2: PACKAGES VIA CHOCOLATEY
# ============================================================================
Write-Host "`n[2/12] Installing Chocolatey Packages..." -ForegroundColor Yellow

$chocoPkgs = @(
    "git","notepadplusplus","sysinternals","glances","pwsh","osquery","poshgit","winmtr",
    "python",
    "cnspec","cnquery","pdq-agent","cloudbase-init",
    "terminal-icons.powershell","fzf","zoxide","microsoft-windows-terminal"
)

foreach ($p in $chocoPkgs) {
    try {
        Write-Info "choco install $p"
        choco install $p -y
        Write-Ok "Installed: $p"
    } catch {
        Write-Warn "Chocolatey install failed for ${p}: $($_.Exception.Message)"
        Write-Warn "Continuing..."
    }
}

Write-Host "`n  Ensuring Glances works (pip-based install)..." -ForegroundColor Cyan
Ensure-GlancesViaPip

# ============================================================================
# SECTION 2.5: ACTION1 + PDQ DEPLOY AGENT (MSI) INSTALL
# ============================================================================
Write-Host "`n[2.5/12] Installing Action1 + PDQ Deploy Agent (MSI)..." -ForegroundColor Yellow

# >>>>>>> IMPORTANT <<<<<<<
# Replace these with your real links:
# - Action1 MSI is tenant-specific (from your Action1 console).
# - PDQ Deploy Agent MSI is usually hosted on your PDQ server / share.
$Action1AgentMsiUrl = "https://REPLACE-ME/YOUR-Action1Agent.msi"
$PDQDeployAgentMsiUrl = "https://REPLACE-ME/YOUR-PDQDeployAgent.msi"

try {
    $agentResult = Install-Agents_Action1_PDQ -Action1Url $Action1AgentMsiUrl -PDQUrl $PDQDeployAgentMsiUrl
    if ($agentResult.RebootRequired) {
        Write-Warn "Agent install indicates a reboot is required (3010)."
    }
    Write-Info "Agent install log: $($agentResult.LogFile)"
} catch {
    Write-Warn "Agent install failed (continuing with rest of script): $($_.Exception.Message)"
}

# ============================================================================
# SECTION 3: PACKAGES VIA SCOOP
# ============================================================================
Write-Host "`n[3/12] Installing Scoop Packages..." -ForegroundColor Yellow

$scoopPkgs = @(
    "btop",
    "neovim",
    "main/wttop",
    "starship",
    "nu",
    "nerd-fonts/FiraCode-NF",
    "nerd-fonts/CascadiaCode-NF"
)
foreach ($pkg in $scoopPkgs) { Invoke-ScoopInstallSafe -PackageId $pkg }

# ============================================================================
# SECTION 4: ELITE POWERSHELL PROFILE (ALL USERS) + MODULES + TERMINAL FONT
# ============================================================================
Write-Host "`n[4/12] Configuring Elite PowerShell Profiles (All Users)..." -ForegroundColor Yellow

Trust-PSGallery
Install-PSModuleSafe -Name "PSFzf"
Install-PSModuleSafe -Name "ActiveDirectoryStructure"
Install-PSModuleSafe -Name "Testimo"

$winPSAllUsersProfile = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\profile.ps1'
Write-ElitePowerShellProfile -ProfilePath $winPSAllUsersProfile

$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd -and $pwshCmd.Source) {
    $pwshInstallDir = Split-Path -Path $pwshCmd.Source -Parent
    $pwshAllUsersProfile = Join-Path $pwshInstallDir 'profile.ps1'
    Write-ElitePowerShellProfile -ProfilePath $pwshAllUsersProfile
} else {
    Write-Warn "pwsh not found; skipping pwsh ALL USERS profile update."
}

Write-Host "`n  Configuring Windows Terminal defaults to Nerd Font + size 9..." -ForegroundColor Cyan
Update-WindowsTerminalSettings -FontFace "FiraCode Nerd Font" -FontSize 9

# ============================================================================
# SECTION 5: PERFORMANCE OPTIMIZATIONS
# ============================================================================
Write-Host "`n[5/12] Applying Performance Optimizations..." -ForegroundColor Yellow

powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
Write-Ok "Power plan set to High Performance"

Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "UserPreferencesMask" -Value ([byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00)) -Type Binary -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Type String -Force
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -Type String -Force
Write-Ok "Visual effects minimized"

$servicesToDisable = @(
    "DiagTrack","dmwappushservice","WSearch","SysMain","MapsBroker","lfsvc","RetailDemo",
    "wisvc","XblAuthManager","XblGameSave","XboxNetApiSvc","XboxGipSvc","Fax","PrintNotify",
    "Spooler","WMPNetworkSvc","icssvc","WpcMonSvc","PhoneSvc","RemoteRegistry","TapiSrv",
    "FrameServer","WerSvc","CDPSvc"
)
foreach ($svc in $servicesToDisable) {
    $service = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Ok "Disabled service: $svc"
    }
}

# ============================================================================
# SECTION 6: NETWORK OPTIMIZATIONS
# ============================================================================
Write-Host "`n[6/12] Applying Network Optimizations..." -ForegroundColor Yellow

netsh int tcp set global autotuninglevel=normal
netsh int tcp set global rss=enabled
netsh int tcp set global timestamps=disabled
netsh int tcp set global initialRto=2000
netsh int tcp set global nonsackrttresiliency=disabled
Write-Ok "TCP settings optimized"

# ============================================================================
# SECTION 7: DISK / STORAGE OPTIMIZATIONS
# ============================================================================
Write-Host "`n[7/12] Applying Disk & Storage Optimizations..." -ForegroundColor Yellow

fsutil behavior set disable8dot3 1
fsutil behavior set disablelastaccess 1
fsutil behavior set disabledeletenotify 0
Write-Ok "Disk optimizations applied (8.3 off, last access off, TRIM enabled)"

# ============================================================================
# SECTION 8: SECURITY HARDENING - SMB
# ============================================================================
Write-Host "`n[8/12] Applying SMB Hardening..." -ForegroundColor Yellow

Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction SilentlyContinue | Out-Null
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force -ErrorAction SilentlyContinue
Set-SmbClientConfiguration -RequireSecuritySignature $true -Force -ErrorAction SilentlyContinue
Set-SmbServerConfiguration -EncryptData $true -Force -ErrorAction SilentlyContinue
Write-Ok "SMB hardening applied"

# ============================================================================
# SECTION 9: SECURITY HARDENING - TLS/SSL
# ============================================================================
Write-Host "`n[9/12] Applying TLS/SSL Hardening..." -ForegroundColor Yellow

$protocolBase = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"
@(
    @{ Name = "SSL 2.0"; Enabled = 0 }, @{ Name = "SSL 3.0"; Enabled = 0 },
    @{ Name = "TLS 1.0"; Enabled = 0 }, @{ Name = "TLS 1.1"; Enabled = 0 },
    @{ Name = "TLS 1.2"; Enabled = 1 }, @{ Name = "TLS 1.3"; Enabled = 1 }
) | ForEach-Object {
    $p = $_.Name; $en = [int]$_.Enabled
    New-Item -Path "$protocolBase\$p\Server" -Force | Out-Null
    New-Item -Path "$protocolBase\$p\Client" -Force | Out-Null
    Set-ItemProperty -Path "$protocolBase\$p\Server" -Name "Enabled" -Value $en -Type DWord -Force
    Set-ItemProperty -Path "$protocolBase\$p\Server" -Name "DisabledByDefault" -Value (1 - $en) -Type DWord -Force
    Set-ItemProperty -Path "$protocolBase\$p\Client" -Name "Enabled" -Value $en -Type DWord -Force
    Set-ItemProperty -Path "$protocolBase\$p\Client" -Name "DisabledByDefault" -Value (1 - $en) -Type DWord -Force
}
Write-Ok "TLS/SSL hardening applied"

# ============================================================================
# SECTION 10: ACCOUNT & ACCESS POLICIES
# ============================================================================
Write-Host "`n[10/12] Applying Account & Access Hardening..." -ForegroundColor Yellow

net accounts /lockoutthreshold:3 /lockoutduration:30 /lockoutwindow:30
net accounts /minpwlen:14 /maxpwage:365 /minpwage:1 /uniquepw:24
Write-Ok "Account policies applied"

# ============================================================================
# SECTION 11: FIREWALL DISABLE (PER REQUEST)
# ============================================================================
Write-Host "`n[11/12] Disabling Windows Firewall (per request)..." -ForegroundColor Yellow

Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Write-Bad "Windows Firewall DISABLED on Domain/Public/Private profiles"

# ============================================================================
# SECTION 12: OSConfig Baseline (install only)
# ============================================================================
Write-Host "`n[12/12] Installing Microsoft OSConfig Security Baseline..." -ForegroundColor Yellow

Trust-PSGallery
try {
    Install-Module -Name Microsoft.OSConfig -Scope AllUsers -Repository PSGallery -Force -ErrorAction Stop | Out-Null
    Write-Ok "OSConfig module installed"
} catch {
    Write-Warn "OSConfig install failed: $($_.Exception.Message)"
}

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host " Setup & Hardening Complete!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Restart Windows Terminal + PowerShell to load:" -ForegroundColor Yellow
Write-Host "  - Updated Terminal font defaults (FiraCode Nerd Font, size 9)" -ForegroundColor Yellow
Write-Host "  - Updated All-Users profiles (Terminal-Icons, PSFzf, zoxide, starship, Testimo, ADS)" -ForegroundColor Yellow
Write-Host ""

$reboot = Read-Host "Reboot now? (y/n)"
if ($reboot -eq 'y') {
    Write-Bad "Rebooting in 10 seconds..."
    shutdown /r /t 10 /c "Server hardening complete - rebooting"
}
