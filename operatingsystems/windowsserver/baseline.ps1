#Requires -RunAsAdministrator
# ============================================================================
# Windows Server 2025 - Setup, Optimization & Hardening Script (ELITE TERMINAL)
# FIXED: PowerShell parser errors with "$var:" inside strings (now uses ${var}: )
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# Global trap -- catches any terminating error and prints it instead of silent exit
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
            Write-Warn "Scoop: $PackageId already installed / file exists -- continuing"
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
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope AllUsers -Force -Confirm:$false -ErrorAction Stop | Out-Null
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
        Install-Module -Name $Name -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Ok "Installed PowerShell module (AllUsers): $Name"
    } catch {
        Write-Warn "Failed to install module '$Name': $($_.Exception.Message)"
    }
}

# ============================================================================
# Install-MsiFromNexus
# Downloads a list of MSI filenames from a Nexus raw repo and installs them.
#
# Parameters:
#   -NexusBaseUrl   : Base URL of the Nexus raw repo, no trailing slash
#                     e.g. "http://nexus:8081/repository/msi-packages"
#   -MsiNames       : Array of MSI filenames (just the filename, no path)
#                     e.g. @("Action1.msi", "MyApp-1.0.0.msi")
#   -InstallArgs    : msiexec arguments (default: /qn /norestart)
#   -NexusUser      : Optional Nexus username (if auth required)
#   -NexusPassword  : Optional Nexus password (if auth required)
# ============================================================================
function Install-MsiFromNexus {
    param(
        [Parameter(Mandatory)][string]   $NexusBaseUrl,
        [Parameter(Mandatory)][string[]] $MsiNames,
        [string] $InstallArgs   = "/qn /norestart",
        [string] $NexusUser     = "",
        [string] $NexusPassword = ""
    )

    # Build auth header once if credentials supplied
    $headers = @{}
    if ($NexusUser -and $NexusPassword) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${NexusUser}:${NexusPassword}"))
        $headers["Authorization"] = "Basic $encoded"
    }

    $results = @{ Success = @(); Failed = @() }

    foreach ($msiName in $MsiNames) {
        $url  = "$NexusBaseUrl/$msiName"
        $dest = "$env:TEMP\$msiName"

        Write-Info "[$msiName] Downloading from $url ..."

        try {
            $iwrParams = @{
                Uri             = $url
                OutFile         = $dest
                UseBasicParsing = $true
                ErrorAction     = "Stop"
            }
            if ($headers.Count -gt 0) { $iwrParams["Headers"] = $headers }
            Invoke-WebRequest @iwrParams
            Write-Ok "[$msiName] Downloaded"
        } catch {
            Write-Warn "[$msiName] Download failed: $($_.Exception.Message)"
            $results.Failed += $msiName
            continue
        }

        Write-Info "[$msiName] Installing..."

        try {
            $proc = Start-Process msiexec.exe `
                -ArgumentList "/i `"$dest`" $InstallArgs" `
                -Wait -PassThru -ErrorAction Stop

            switch ($proc.ExitCode) {
                0    { Write-Ok   "[$msiName] Installed successfully" }
                3010 { Write-Ok   "[$msiName] Installed -- reboot required to complete" }
                1638 { Write-Warn "[$msiName] Another version already installed -- skipping" }
                1641 { Write-Ok   "[$msiName] Installed -- reboot initiated by installer" }
                default {
                    Write-Warn "[$msiName] Installer exited with code $($proc.ExitCode)"
                    $results.Failed += $msiName
                    continue
                }
            }
            $results.Success += $msiName
        } catch {
            Write-Warn "[$msiName] Install failed: $($_.Exception.Message)"
            $results.Failed += $msiName
        } finally {
            Remove-Item $dest -Force -ErrorAction SilentlyContinue
        }
    }

    # Summary
    Write-Host ""
    Write-Ok   "MSI installs complete -- $($results.Success.Count) succeeded, $($results.Failed.Count) failed"
    if ($results.Failed.Count -gt 0) {
        Write-Warn "Failed packages: $($results.Failed -join ', ')"
    }
}

function Write-ElitePowerShellProfile {
    param([Parameter(Mandatory)][string]$ProfilePath)

    # Build profile as array of lines -- avoids here-string issues when run via iex
    $lines = @(
        '# ============================================',
        '# Elite PowerShell Global Profile (ALL USERS)',
        '# ============================================',
        '',
        '# ---- Encoding ----',
        'try {',
        '    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8',
        '    $PSDefaultParameterValues[''Out-File:Encoding''] = ''utf8''',
        '} catch {}',
        '',
        '# ---- ANSI rendering (PowerShell 7+) ----',
        'try {',
        '    if (Test-Path Variable:\PSStyle) {',
        '        $PSStyle.OutputRendering = ''Ansi''',
        '    }',
        '} catch {}',
        '',
        '# ---- PSReadLine ----',
        'if (Get-Module -ListAvailable -Name PSReadLine) {',
        '    Import-Module PSReadLine -ErrorAction SilentlyContinue',
        '    try {',
        '        Set-PSReadLineOption -PredictionSource History',
        '        Set-PSReadLineOption -PredictionViewStyle ListView',
        '    } catch {}',
        '    try {',
        '        Set-PSReadLineOption -EditMode Windows',
        '        Set-PSReadLineOption -BellStyle None',
        '        Set-PSReadLineOption -HistoryNoDuplicates',
        '        Set-PSReadLineOption -HistorySearchCursorMovesToEnd',
        '        Set-PSReadLineOption -ShowToolTips',
        '        Set-PSReadLineOption -ContinuationPrompt ''> ''',
        '    } catch {}',
        '    try {',
        '        Set-PSReadLineKeyHandler -Key Tab -Function Complete',
        '        Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward',
        '        Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward',
        '        Set-PSReadLineKeyHandler -Key Ctrl+LeftArrow -Function BackwardWord',
        '        Set-PSReadLineKeyHandler -Key Ctrl+RightArrow -Function ForwardWord',
        '        Set-PSReadLineKeyHandler -Key Alt+Backspace -Function BackwardKillWord',
        '        Set-PSReadLineKeyHandler -Key Ctrl+Backspace -Function BackwardKillWord',
        '    } catch {}',
        '}',
        '',
        '# ---- Terminal-Icons ----',
        'if (Get-Module -ListAvailable -Name Terminal-Icons) {',
        '    Import-Module Terminal-Icons -ErrorAction SilentlyContinue',
        '}',
        '',
        '# ---- PSFzf ----',
        'if (Get-Module -ListAvailable -Name PSFzf) {',
        '    Import-Module PSFzf -ErrorAction SilentlyContinue',
        '    try { Set-PsFzfOption -PSReadlineChordProvider ''Ctrl+t'' -PSReadlineChordReverseHistory ''Ctrl+r'' | Out-Null } catch {}',
        '    try { Enable-PsFzfAliases | Out-Null } catch {}',
        '}',
        '',
        '# ---- zoxide ----',
        'if (Get-Command zoxide -ErrorAction SilentlyContinue) {',
        '    try { Invoke-Expression (& zoxide init powershell) } catch {}',
        '}',
        '',
        '# ---- posh-git ----',
        'if (Get-Module -ListAvailable -Name posh-git) {',
        '    Import-Module posh-git -ErrorAction SilentlyContinue',
        '}',
        '',
        '# ---- QoL aliases ----',
        'function ll { Get-ChildItem -Force }',
        'function la { Get-ChildItem -Force }',
        'function .. { Set-Location .. }',
        'function ... { Set-Location ../.. }',
        '',
        '# ---- Starship prompt ----',
        'if (Get-Command starship -ErrorAction SilentlyContinue) {',
        '    try { Invoke-Expression (& starship init powershell) } catch {}',
        '}'
    )

    try {
        $dir = Split-Path $ProfilePath -Parent
        if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $lines | Set-Content -Path $ProfilePath -Encoding UTF8 -Force
        Write-Ok "Wrote ALL-USERS profile -> $ProfilePath"
    } catch {
        Write-Warn "Failed writing profile to ${ProfilePath}: $($_.Exception.Message)"
    }
}

function Update-WindowsTerminalSettings {
    param(
        [Parameter(Mandatory)][string]$FontFace,
        [Parameter(Mandatory)][int]$FontSize
    )

    # Build candidate paths for ALL user profiles on the machine, not just the
    # running admin -- script runs as Administrator so $env:LOCALAPPDATA points
    # to the admin profile, missing any other logged-on users.
    $allLocalAppDatas = @()

    # Add current session's LOCALAPPDATA first
    $allLocalAppDatas += [string]$env:LOCALAPPDATA

    # Enumerate all user profile directories from the registry
    $profileList = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" -ErrorAction SilentlyContinue
    foreach ($prof in $profileList) {
        $profilePath = $prof.ProfileImagePath
        if ($profilePath -and (Test-Path $profilePath)) {
            $localAppData = Join-Path $profilePath "AppData\Local"
            if ($allLocalAppDatas -notcontains $localAppData) {
                $allLocalAppDatas += $localAppData
            }
        }
    }

    $updated = 0
    foreach ($localAppData in $allLocalAppDatas) {
        $candidates = @(
            "$localAppData\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
            "$localAppData\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
            "$localAppData\Microsoft\Windows Terminal\settings.json"
        )

        foreach ($settingsPath in ($candidates | Where-Object { Test-Path $_ })) {
            try {
                Write-Info "Updating Windows Terminal settings: $settingsPath"
                $raw = Get-Content -Path $settingsPath -Raw -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($raw)) { throw "settings.json is empty" }

                # Round-trip through hashtable to get fully mutable objects
                $data = $raw | ConvertFrom-Json -ErrorAction Stop | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable -ErrorAction Stop

                if (-not $data.ContainsKey('profiles'))                     { $data['profiles'] = @{} }
                if (-not $data['profiles'].ContainsKey('defaults'))         { $data['profiles']['defaults'] = @{} }
                if (-not $data['profiles']['defaults'].ContainsKey('font')) { $data['profiles']['defaults']['font'] = @{} }

                $data['profiles']['defaults']['font']['face'] = $FontFace
                $data['profiles']['defaults']['font']['size'] = $FontSize

                $data | ConvertTo-Json -Depth 60 | Set-Content -Path $settingsPath -Encoding UTF8 -Force

                Write-Ok "Terminal font set: '$FontFace' size=$FontSize -> $settingsPath"
                $updated++
            } catch {
                Write-Warn "Failed updating '${settingsPath}': $($_.Exception.Message)"
            }
        }
    }

    if ($updated -eq 0) {
        Write-Warn "No Windows Terminal settings.json found across any user profile."
        Write-Warn "Open Windows Terminal once as each user, then re-run the script."
    } else {
        Write-Ok "Updated $updated settings.json file(s)"
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
# SECTION 1: PACKAGE MANAGERS
# ============================================================================
Write-Host "`n[1/14] Installing Package Managers..." -ForegroundColor Yellow

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

# ============================================================================
# SECTION 2: PACKAGES VIA CHOCOLATEY
# ============================================================================
Write-Host "`n[2/14] Installing Chocolatey Packages..." -ForegroundColor Yellow

$chocoPkgs = @(
    "git","notepadplusplus","sysinternals","python","pwsh","osquery","poshgit","winmtr",
    "pingplotter","cnspec","cnquery","cloudbaseinit",
    "terminal-icons.powershell","fzf","zoxide","microsoft-windows-terminal","nerd-fonts-firacode",
    "nerd-fonts-cascadiacode"
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

# Refresh PATH so choco-installed tools (python, etc.) are visible in this session
Write-Info "Refreshing PATH after Chocolatey installs..."
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
Write-Ok "PATH refreshed"

# ============================================================================
# SECTION 3: PACKAGES VIA SCOOP
# ============================================================================
Write-Host "`n[3/14] Installing Scoop Packages..." -ForegroundColor Yellow

$scoopPkgs = @(
    "btop",
    "neovim",
    "main/wttop",
    "starship",
    "nu"
)
foreach ($pkg in $scoopPkgs) { Invoke-ScoopInstallSafe -PackageId $pkg }

# ============================================================================
# SECTION 4: PYTHON PIP + GLANCES (pip)
# ============================================================================
Write-Host "`n[4/14] Installing Python pip and Glances via pip..." -ForegroundColor Yellow

# Resolve python executable -- try py launcher, then python, then choco install paths
$pyExe = $null
foreach ($candidate in @("py", "python")) {
    $resolved = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($resolved) { $pyExe = $resolved.Source; break }
}
if (-not $pyExe) {
    $pyExe = Get-Item "C:\Python3*\python.exe" -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $pyExe) {
    $pyExe = Get-Item "C:\tools\python*\python.exe" -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
}

if ($pyExe) {
    Write-Info "Using Python: $pyExe"

    try {
        Write-Info "Bootstrapping pip via get-pip.py..."
        $getPipPath = "$env:TEMP\get-pip.py"
        (New-Object System.Net.WebClient).DownloadFile("https://bootstrap.pypa.io/get-pip.py", $getPipPath)
        & $pyExe $getPipPath --quiet
        Remove-Item $getPipPath -Force -ErrorAction SilentlyContinue
        Write-Ok "pip installed/updated"
    } catch {
        Write-Warn "pip bootstrap failed: $($_.Exception.Message)"
        Write-Warn "Continuing..."
    }

    try {
        Write-Info "Installing glances via pip..."
        & $pyExe -m pip install glances --quiet
        Write-Ok "glances installed via pip"
    } catch {
        Write-Warn "pip install glances failed: $($_.Exception.Message)"
        Write-Warn "Continuing..."
    }
} else {
    Write-Warn "Python not found after PATH refresh -- skipping pip/glances install"
    Write-Warn "Ensure python is installed and re-run, or install manually: py -m pip install glances"
}

# ============================================================================
# SECTION 5: MSI PACKAGES FROM NEXUS
# ============================================================================
Write-Host "`n[5/14] Installing MSI packages from Nexus..." -ForegroundColor Yellow

# -------------------------------------------------------------------
# CONFIG -- update these to match your Nexus server and repo
# -------------------------------------------------------------------
$nexusBaseUrl   = "http://10.0.0.49:8081/repository/msi-packages"
$nexusUser      = ""    # leave empty string "" for anonymous
$nexusPassword  = ""    # leave empty string "" for anonymous

# Each entry uses keyword fragments - ANY match = already installed
$nexusMsiMap = @(
    @{ File = "action1_agent(GurdipDevOps).msi";        Keywords = @("Action1") },
    @{ File = "DevolutionsAgent-x86_64-2026.1.0.0.msi"; Keywords = @("Devolutions", "RDM", "Devolutions Agent") }
)
# -------------------------------------------------------------------

# Collect all installed display names from 32-bit and 64-bit hives
# Collect installed display names — use explicit property access to avoid StrictMode errors
$installedPrograms = @()
$regHives = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
foreach ($hive in $regHives) {
    $entries = Get-ItemProperty $hive -ErrorAction SilentlyContinue
    foreach ($entry in $entries) {
        $dn = $entry.PSObject.Properties["DisplayName"]
        if ($dn -and $dn.Value) { $installedPrograms += $dn.Value }
    }
}

Write-Info "Installed programs found: $($installedPrograms.Count)"

$msiToInstall = @()
foreach ($entry in $nexusMsiMap) {
    $found = $false
    foreach ($keyword in $entry.Keywords) {
        if ($installedPrograms | Where-Object { $_ -like "*$keyword*" }) {
            Write-Warn "Already installed (matched: $keyword), skipping: $($entry.File)"
            $found = $true
            break
        }
    }
    if (-not $found) {
        Write-Info "Not installed, queued: $($entry.File)"
        $msiToInstall += $entry.File
    }
}

if ($msiToInstall.Count -gt 0) {
    Install-MsiFromNexus `
        -NexusBaseUrl   $nexusBaseUrl `
        -MsiNames       $msiToInstall `
        -NexusUser      $nexusUser `
        -NexusPassword  $nexusPassword
} else {
    Write-Ok "All MSI packages already installed - skipping Nexus downloads"
}

# ============================================================================
# SECTION 6: ELITE POWERSHELL PROFILE (ALL USERS) + MODULES + TERMINAL FONT
# ============================================================================
Write-Host "`n[6/14] Configuring Elite PowerShell Profiles (All Users)..." -ForegroundColor Yellow

Trust-PSGallery
Install-PSModuleSafe -Name "PSFzf"
Install-PSModuleSafe -Name "Terminal-Icons"

$winPSAllUsersProfile = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\profile.ps1'
Write-ElitePowerShellProfile -ProfilePath $winPSAllUsersProfile

# Resolve pwsh ALL USERS profile path without spawning a child process
# Child pwsh via iex pipe can fail with StrictMode -- use known paths instead
$pwshAllUsersProfile = $null
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd -and $pwshCmd.Source) {
    try {
        # Try known PS7 all-users profile locations directly
        $pwshDir = Split-Path $pwshCmd.Source -Parent
        $candidates = @(
            (Join-Path $pwshDir 'profile.ps1'),
            'C:\Program Files\PowerShell\7\profile.ps1',
            'C:\Program Files\PowerShell\7-preview\profile.ps1'
        )
        foreach ($c in $candidates) {
            if ($c -and (Split-Path $c -Parent | Test-Path)) {
                $pwshAllUsersProfile = $c
                break
            }
        }
    } catch {
        Write-Warn "Could not resolve pwsh profile path: $($_.Exception.Message)"
    }
}

if ($pwshAllUsersProfile) {
    Write-ElitePowerShellProfile -ProfilePath $pwshAllUsersProfile
} else {
    Write-Warn "pwsh not found or profile path unresolvable -- skipping pwsh ALL USERS profile."
}

Write-Host "`n  Setting Windows Terminal font via external script..." -ForegroundColor Cyan
try {
    $fontScript = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/GurdipSCode/devops-scripts-softwareconfigs/refs/heads/main/operatingsystems/windowsserver/set-windows-terminal-font.ps1" -UseBasicParsing
    Invoke-Expression $fontScript
    Write-Ok "Font script completed"
} catch {
    Write-Warn "Font script failed: $($_.Exception.Message)"
}

# SECTION 7: PERFORMANCE OPTIMIZATIONS
# ============================================================================
Write-Host "`n[7/14] Applying Performance Optimizations..." -ForegroundColor Yellow

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
# SECTION 8: NETWORK OPTIMIZATIONS
# ============================================================================
Write-Host "`n[8/14] Applying Network Optimizations..." -ForegroundColor Yellow

netsh int tcp set global autotuninglevel=normal
netsh int tcp set global rss=enabled
netsh int tcp set global timestamps=disabled
netsh int tcp set global initialRto=2000
netsh int tcp set global nonsackrttresiliency=disabled
Write-Ok "TCP settings optimized"

# ============================================================================
# SECTION 9: DISK / STORAGE OPTIMIZATIONS
# ============================================================================
Write-Host "`n[9/14] Applying Disk & Storage Optimizations..." -ForegroundColor Yellow

fsutil behavior set disable8dot3 1
fsutil behavior set disablelastaccess 1
fsutil behavior set disabledeletenotify 0
Write-Ok "Disk optimizations applied (8.3 off, last access off, TRIM enabled)"

# ============================================================================
# SECTION 10: SECURITY HARDENING - SMB
# ============================================================================
Write-Host "`n[10/14] Applying SMB Hardening..." -ForegroundColor Yellow

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "SMB1" -Value 0 -Type DWord -Force
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force -ErrorAction SilentlyContinue
Set-SmbClientConfiguration -RequireSecuritySignature $true -Force -ErrorAction SilentlyContinue
Set-SmbServerConfiguration -EncryptData $true -Force -ErrorAction SilentlyContinue
Write-Ok "SMB hardening applied"

# ============================================================================
# SECTION 11: SECURITY HARDENING - TLS/SSL
# ============================================================================
Write-Host "`n[11/14] Applying TLS/SSL Hardening..." -ForegroundColor Yellow

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
# SECTION 12: ACCOUNT & ACCESS POLICIES
# ============================================================================
Write-Host "`n[12/14] Applying Account & Access Hardening..." -ForegroundColor Yellow

net accounts /lockoutthreshold:3 /lockoutduration:30 /lockoutwindow:30
net accounts /minpwlen:14 /maxpwage:365 /minpwage:1 /uniquepw:24
Write-Ok "Account policies applied"

# ============================================================================
# SECTION 13: FIREWALL DISABLE (PER REQUEST)
# ============================================================================
Write-Host "`n[13/14] Disabling Windows Firewall (per request)..." -ForegroundColor Yellow

Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Write-Bad "Windows Firewall DISABLED on Domain/Public/Private profiles"

# ============================================================================
# SECTION 14: OSConfig Baseline (install only)
# ============================================================================
Write-Host "`n[14/14] Installing Microsoft OSConfig Security Baseline..." -ForegroundColor Yellow

Trust-PSGallery
try {
    Install-Module -Name Microsoft.OSConfig -Scope AllUsers -Repository PSGallery -Force -Confirm:$false -ErrorAction Stop | Out-Null
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
Write-Host "  - Updated All-Users profiles (Terminal-Icons, PSFzf, zoxide, starship)" -ForegroundColor Yellow
Write-Host ""

$reboot = Read-Host "Reboot now? (y/n)"
if ($reboot -eq 'y') {
    Write-Bad "Rebooting in 10 seconds..."
    shutdown /r /t 10 /c "Server hardening complete - rebooting"
}
