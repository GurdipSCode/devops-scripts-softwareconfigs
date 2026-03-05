#Requires -RunAsAdministrator
# ============================================================================
# Windows Server 2025 - Setup, Optimization & Hardening Script (ELITE TERMINAL)
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
        # FIX: ${PackageId}: avoids "$PackageId:" being parsed as a drive-qualified variable
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


# ============================================================================
# SECTION 2: PACKAGES VIA CHOCOLATEY
# ============================================================================
Write-Host "`n[2/12] Installing Chocolatey Packages..." -ForegroundColor Yellow

$chocoPkgs = @(
    "git","notepadplusplus","sysinternals","glances","pwsh","osquery","poshgit","winmtr",
    "devolutions-agent","cnspec","cnquery","cloudbase-init",
    "terminal-icons.powershell","fzf","zoxide","microsoft-windows-terminal","nerd-fonts-firacode",
    "nerd-fonts-cascadiacode"
)

foreach ($p in $chocoPkgs) {
    try {
        Write-Info "choco install $p"
        choco install $p -y
        Write-Ok "Installed: $p"
    } catch {
        # FIX: ${p}: avoids "$p:" parser issue
        Write-Warn "Chocolatey install failed for ${p}: $($_.Exception.Message)"
        Write-Warn "Continuing..."
    }
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
    "nu"
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
