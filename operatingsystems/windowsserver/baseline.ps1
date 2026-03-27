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
# Write-BtopConfig
# Writes a minimal btop.conf for every user account on the machine.
# Skips any user whose config file already exists (never overwrites).
# btop on Windows (Scoop) reads config from:
#   %APPDATA%\btop\btop.conf  ->  <profile>\AppData\Roaming\btop\btop.conf
# ============================================================================
function Write-BtopConfig {
    param(
        [string] $ColorTheme     = "Default",
        [int]    $UpdateMs       = 500
    )

    $configLines = @(
        '#',
        '# btop.conf -- minimal config written by server setup script',
        '#',
        '',
        '# Color theme. "Default" uses the built-in btop theme.',
        "color_theme = `"$ColorTheme`"",
        '',
        '# Update interval in milliseconds.',
        "update_ms = $UpdateMs",
        '',
        '# Use UTF-8 box-drawing characters (requires a Nerd Font / Unicode terminal).',
        'utf_force = True',
        '',
        '# Show detailed CPU frequency information.',
        'show_cpu_freq = True',
        '',
        '# Clock format string (strftime). Empty = no clock.',
        'clock_format = "%X"',
        '',
        '# Smooth CPU graph.',
        'cpu_graph_upper = "total"',
        'cpu_graph_lower = "user"',
        '',
        '# Memory display unit: "b" | "kb" | "mb" | "gb".',
        'mem_graphs = True',
        '',
        '# Show processes as a tree.',
        'proc_tree = False'
    )

    $allProfiles = Get-AllUserProfilePaths

    # Also cover the currently running admin session
    if ($env:APPDATA) {
        $adminRoaming = $env:APPDATA
        $adminBtop    = Join-Path $adminRoaming "btop\btop.conf"
        if (!(Test-Path $adminBtop)) {
            try {
                $dir = Split-Path $adminBtop -Parent
                if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $configLines | Set-Content -Path $adminBtop -Encoding UTF8 -Force
                Write-Ok "Created btop.conf (current session): $adminBtop"
            } catch {
                Write-Warn "Failed writing btop.conf for current session: $($_.Exception.Message)"
            }
        } else {
            Write-Info "btop.conf already exists (current session) -- skipping: $adminBtop"
        }
    }

    foreach ($profileRoot in $allProfiles) {
        $roaming  = Join-Path $profileRoot "AppData\Roaming"
        $confPath = Join-Path $roaming "btop\btop.conf"

        if (Test-Path $confPath) {
            Write-Info "btop.conf already exists -- skipping: $confPath"
            continue
        }

        try {
            $dir = Split-Path $confPath -Parent
            if (!(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $configLines | Set-Content -Path $confPath -Encoding UTF8 -Force
            Write-Ok "Created btop.conf: $confPath"
        } catch {
            Write-Warn "Failed writing btop.conf to '${confPath}': $($_.Exception.Message)"
        }
    }
}

# ============================================================================
# Install-MsiFromNexus
# ============================================================================
function Install-MsiFromNexus {
    param(
        [Parameter(Mandatory)][string]   $NexusBaseUrl,
        [Parameter(Mandatory)][string[]] $MsiNames,
        [string] $InstallArgs   = "/qn /norestart",
        [string] $NexusUser     = "",
        [string] $NexusPassword = ""
    )

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

    Write-Host ""
    Write-Ok   "MSI installs complete -- $($results.Success.Count) succeeded, $($results.Failed.Count) failed"
    if ($results.Failed.Count -gt 0) {
        Write-Warn "Failed packages: $($results.Failed -join ', ')"
    }
}

# ============================================================================
# Write-ElitePowerShellProfile
# Writes the elite profile to a given path (AllUsers or per-user).
# ============================================================================
function Write-ElitePowerShellProfile {
    param([Parameter(Mandatory)][string]$ProfilePath)

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
        Write-Ok "Wrote profile -> $ProfilePath"
    } catch {
        Write-Warn "Failed writing profile to ${ProfilePath}: $($_.Exception.Message)"
    }
}

# ============================================================================
# Get-AllUserProfilePaths
# Returns a list of all local user profile root directories found in the
# registry, deduped and validated to exist on disk.
# ============================================================================
function Get-AllUserProfilePaths {
    $paths = @()

    $profileList = Get-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" `
        -ErrorAction SilentlyContinue

    foreach ($prof in $profileList) {
        $p = $prof.ProfileImagePath
        # Skip system pseudo-profiles (LocalService, NetworkService, systemprofile)
        if ($p -and (Test-Path $p) -and ($p -notmatch "systemprofile|LocalService|NetworkService")) {
            if ($paths -notcontains $p) { $paths += $p }
        }
    }

    return $paths
}

# ============================================================================
# Update-WindowsTerminalSettings
# Writes a complete, valid settings.json for EVERY user profile on the machine.
# Creates the file (and its parent LocalState directory) from scratch if it
# does not yet exist -- no need for the user to have opened Terminal first.
# ============================================================================
function Update-WindowsTerminalSettings {
    param(
        [Parameter(Mandatory)][string]$FontFace,
        [Parameter(Mandatory)][int]$FontSize
    )

    # Canonical default settings.json -- matches what Windows Terminal 1.x writes
    # on first launch, with our font baked in.  Extend the profiles/schemes arrays
    # here if you need extra shells or colour schemes in future.
    $defaultSettings = [ordered]@{
        '$schema'          = "https://aka.ms/terminal-profiles-schema"
        defaultProfile     = "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}"  # Windows PowerShell
        copyOnSelect       = $false
        copyFormatting     = $false
        alwaysShowTabs     = $true
        showTerminalTitleInTitlebar = $true
        launchMode         = "default"
        wordDelimiters     = " /\()""'-.,:;<>~!@#$%^&*|+=[]{}~?│"
        confirmCloseAllTabs = $true
        theme              = "dark"
        profiles           = [ordered]@{
            defaults = [ordered]@{
                font        = [ordered]@{ face = $FontFace; size = $FontSize }
                colorScheme = "Campbell"
                cursorShape = "bar"
                antialiasingMode = "grayscale"
                useAcrylic  = $false
                scrollbarState = "visible"
                padding     = "8, 8, 8, 8"
            }
            list = @(
                [ordered]@{
                    guid    = "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}"
                    name    = "Windows PowerShell"
                    commandline = "powershell.exe"
                    hidden  = $false
                    icon    = "ms-appx:///ProfileIcons/{61c54bbd-c2c6-5271-96e7-009a87ff44bf}.png"
                },
                [ordered]@{
                    guid    = "{0caa0dad-35be-5f56-a8ff-afceeeaa6101}"
                    name    = "Command Prompt"
                    commandline = "cmd.exe"
                    hidden  = $false
                    icon    = "ms-appx:///ProfileIcons/{0caa0dad-35be-5f56-a8ff-afceeeaa6101}.png"
                },
                [ordered]@{
                    guid    = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
                    name    = "PowerShell"
                    commandline = "pwsh.exe"
                    hidden  = $false
                    source  = "Windows.Terminal.PowershellCore"
                    icon    = "ms-appx:///ProfileIcons/{574e775e-4f2a-5b96-ac1e-a2962a402336}.png"
                }
            )
        }
        schemes = @(
            [ordered]@{
                name         = "Campbell"
                foreground   = "#CCCCCC"
                background   = "#0C0C0C"
                selectionBackground = "#FFFFFF"
                cursorColor  = "#FFFFFF"
                black        = "#0C0C0C"; red    = "#C50F1F"; green  = "#13A10E"; yellow = "#C19C00"
                blue         = "#0037DA"; purple = "#881798"; cyan   = "#3A96DD"; white  = "#CCCCCC"
                brightBlack  = "#767676"; brightRed = "#E74856"; brightGreen = "#16C60C"; brightYellow = "#F9F1A5"
                brightBlue   = "#3B78FF"; brightPurple = "#B4009E"; brightCyan = "#61D6D6"; brightWhite = "#F2F2F2"
            },
            [ordered]@{
                name         = "One Half Dark"
                foreground   = "#DCDFE4"
                background   = "#282C34"
                selectionBackground = "#FFFFFF"
                cursorColor  = "#A3B3CC"
                black        = "#282C34"; red    = "#E06C75"; green  = "#98C379"; yellow = "#E5C07B"
                blue         = "#61AFEF"; purple = "#C678DD"; cyan   = "#56B6C2"; white  = "#DCDFE4"
                brightBlack  = "#5A6374"; brightRed = "#E06C75"; brightGreen = "#98C379"; brightYellow = "#E5C07B"
                brightBlue   = "#61AFEF"; brightPurple = "#C678DD"; brightCyan = "#56B6C2"; brightWhite = "#DCDFE4"
            }
        )
        actions = @(
            @{ command = @{ action = "copy"; singleLine = $false }; keys = "ctrl+c" },
            @{ command = "paste";              keys = "ctrl+v" },
            @{ command = "find";               keys = "ctrl+shift+f" },
            @{ command = @{ action = "splitPane"; split = "auto"; splitMode = "duplicate" }; keys = "alt+shift+d" }
        )
    }

    $settingsJson = $defaultSettings | ConvertTo-Json -Depth 20

    # Candidate sub-paths inside each user's AppData\Local for Windows Terminal
    $terminalSubPaths = @(
        "Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "Microsoft\Windows Terminal\settings.json"
    )

    $updated = 0
    $created = 0

    # Include the current session's LOCALAPPDATA as well as all registry profiles
    $allLocalAppDatas = @( [string]$env:LOCALAPPDATA )

    foreach ($profileRoot in (Get-AllUserProfilePaths)) {
        $lad = Join-Path $profileRoot "AppData\Local"
        if ($allLocalAppDatas -notcontains $lad) { $allLocalAppDatas += $lad }
    }

    foreach ($localAppData in $allLocalAppDatas) {
        foreach ($subPath in $terminalSubPaths) {
            $settingsPath = Join-Path $localAppData $subPath

            # Only write the preview/stable package paths if the package folder exists,
            # OR if the file already exists there (e.g. manual install).
            $packageDir = Split-Path $settingsPath -Parent
            $packageRoot = Split-Path $packageDir -Parent   # …\LocalState -> …\Packages\Microsoft.WindowsTerminal_…

            $packageFolderExists = Test-Path (Split-Path $packageRoot -Parent)   # …\Packages dir

            # For the non-package path (Microsoft\Windows Terminal) always attempt creation.
            $isPackagePath = $subPath -like "Packages\*"

            if ($isPackagePath -and -not $packageFolderExists -and -not (Test-Path $settingsPath)) {
                # Package not installed for this user -- skip to avoid cluttering AppData
                continue
            }

            if (Test-Path $settingsPath) {
                # File exists -- update font in existing JSON, preserve everything else
                try {
                    $raw = Get-Content -Path $settingsPath -Raw -ErrorAction Stop
                    if ([string]::IsNullOrWhiteSpace($raw)) { throw "empty file" }

                    $data = $raw | ConvertFrom-Json -ErrorAction Stop |
                            ConvertTo-Json -Depth 60 |
                            ConvertFrom-Json -AsHashtable -ErrorAction Stop

                    if (-not $data.ContainsKey('profiles'))                     { $data['profiles'] = @{} }
                    if (-not $data['profiles'].ContainsKey('defaults'))         { $data['profiles']['defaults'] = @{} }
                    if (-not $data['profiles']['defaults'].ContainsKey('font')) { $data['profiles']['defaults']['font'] = @{} }

                    $data['profiles']['defaults']['font']['face'] = $FontFace
                    $data['profiles']['defaults']['font']['size'] = $FontSize

                    $data | ConvertTo-Json -Depth 60 | Set-Content -Path $settingsPath -Encoding UTF8 -Force
                    Write-Ok "Updated existing settings.json: $settingsPath"
                    $updated++
                } catch {
                    Write-Warn "Failed updating '${settingsPath}': $($_.Exception.Message)"
                }
            } else {
                # File does not exist -- write full default settings.json from scratch
                try {
                    if (!(Test-Path $packageDir)) {
                        New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
                    }
                    $settingsJson | Set-Content -Path $settingsPath -Encoding UTF8 -Force
                    Write-Ok "Created new settings.json: $settingsPath"
                    $created++
                } catch {
                    Write-Warn "Failed creating '${settingsPath}': $($_.Exception.Message)"
                }
            }
        }
    }

    Write-Ok "Windows Terminal settings -- $updated updated, $created created"
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

Write-Host ""
Write-Info "Writing btop.conf for all user accounts..."
Write-BtopConfig -ColorTheme "Default" -UpdateMs 500

# ============================================================================
# SECTION 4: PYTHON PIP + GLANCES (pip)
# ============================================================================
Write-Host "`n[4/14] Installing Python pip and Glances via pip..." -ForegroundColor Yellow

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

$nexusBaseUrl   = "http://10.0.0.49:8081/repository/msi-packages"
$nexusUser      = ""
$nexusPassword  = ""

$nexusMsiMap = @(
    @{ File = "action1_agent(GurdipDevOps).msi";        Keywords = @("Action1") },
    @{ File = "DevolutionsAgent-x86_64-2026.1.0.0.msi"; Keywords = @("Devolutions", "RDM", "Devolutions Agent") }
)

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
Write-Host "`n[6/14] Configuring Elite PowerShell Profiles..." -ForegroundColor Yellow

Trust-PSGallery
Install-PSModuleSafe -Name "PSFzf"
Install-PSModuleSafe -Name "Terminal-Icons"

# ---- AllUsers profile for Windows PowerShell 5.x (system-wide, one file) ----
$winPSAllUsersProfile = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\profile.ps1'
Write-Info "Writing AllUsers Windows PowerShell profile..."
Write-ElitePowerShellProfile -ProfilePath $winPSAllUsersProfile

# ---- AllUsers profile for PowerShell 7 (pwsh) ----
# Resolve without spawning a child process -- avoid StrictMode failures
$pwshAllUsersProfile = $null
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) {
    $pwshDir = Split-Path $pwshCmd.Source -Parent
    $pwsh7Candidates = @(
        (Join-Path $pwshDir 'profile.ps1'),
        'C:\Program Files\PowerShell\7\profile.ps1',
        'C:\Program Files\PowerShell\7-preview\profile.ps1'
    )
    foreach ($c in $pwsh7Candidates) {
        $parentDir = Split-Path $c -Parent
        if ($parentDir -and (Test-Path $parentDir)) {
            $pwshAllUsersProfile = $c
            break
        }
    }
}

if ($pwshAllUsersProfile) {
    Write-Info "Writing AllUsers pwsh 7 profile..."
    Write-ElitePowerShellProfile -ProfilePath $pwshAllUsersProfile
} else {
    Write-Warn "pwsh not found -- skipping pwsh AllUsers profile."
}

# ---- Windows Terminal settings.json -- all user accounts ----
Write-Host ""
Write-Info "Writing Windows Terminal settings.json for all user accounts..."
Update-WindowsTerminalSettings -FontFace "FiraCode Nerd Font" -FontSize 9

# ---- External font script (kept for fallback / WT preview installs) ----
Write-Host ""
Write-Info "Running supplemental font script..."
try {
    $fontScript = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/GurdipSCode/devops-scripts-softwareconfigs/refs/heads/main/operatingsystems/windowsserver/set-windows-terminal-font.ps1" -UseBasicParsing
    Invoke-Expression $fontScript
    Write-Ok "Font script completed"
} catch {
    Write-Warn "Font script failed: $($_.Exception.Message)"
}

# ============================================================================
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
