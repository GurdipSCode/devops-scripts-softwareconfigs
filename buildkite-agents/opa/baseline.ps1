#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs OPA, Regal, Conftest, Harbor CLI, oras, Cosign, Semgrep, ggshield, git-cliff;
    enables long path support.
.DESCRIPTION
    - OPA, Regal, Conftest, Harbor CLI, oras, Cosign: GitHub release binaries -> local bin on PATH
    - Semgrep & ggshield: pip
    - git-cliff: winget
    - Enables LongPathsEnabled in the registry
.NOTES
    Run from an elevated PowerShell session.
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\devtools"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Add-ToUserPath($pathToAdd) {
    $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($currentPath -notlike "*$pathToAdd*") {
        $newPath = if ([string]::IsNullOrEmpty($currentPath)) { $pathToAdd } else { "$currentPath;$pathToAdd" }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:Path = "$env:Path;$pathToAdd"
        Write-Host "    Added $pathToAdd to user PATH"
    } else {
        Write-Host "    $pathToAdd already on user PATH"
    }
}

function Get-LatestGitHubAsset {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$AssetMatch
    )
    $api = "https://api.github.com/repos/$Repo/releases/latest"
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'PowerShell' }
    $asset = $release.assets | Where-Object { $_.name -like $AssetMatch } | Select-Object -First 1
    if (-not $asset) {
        throw "No asset matching '$AssetMatch' found in latest release of $Repo"
    }
    return [pscustomobject]@{
        Url     = $asset.browser_download_url
        Name    = $asset.name
        Version = $release.tag_name
    }
}

function Expand-Archive-Flexible {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )
    New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
    if ($ArchivePath -like '*.zip') {
        Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
    } elseif ($ArchivePath -like '*.tar.gz' -or $ArchivePath -like '*.tgz') {
        tar -xzf $ArchivePath -C $DestinationPath
    } else {
        throw "Unsupported archive type: $ArchivePath"
    }
}

function Install-ArchivedBinary {
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$AssetMatch,
        [Parameter(Mandatory)][string]$ExeNameInArchive, # filename inside the archive, e.g. 'conftest.exe'
        [Parameter(Mandatory)][string]$FinalExeName,     # name to use on PATH, e.g. 'conftest.exe'
        [Parameter(Mandatory)][string]$InstallDir
    )
    $asset = Get-LatestGitHubAsset -Repo $Repo -AssetMatch $AssetMatch
    $download = Join-Path $env:TEMP $asset.Name
    Invoke-WebRequest -Uri $asset.Url -OutFile $download -UseBasicParsing

    if ($asset.Name -like '*.exe') {
        Copy-Item -Path $download -Destination (Join-Path $InstallDir $FinalExeName) -Force
    } else {
        $extractDir = Join-Path $env:TEMP ("extract-" + [IO.Path]::GetFileNameWithoutExtension($asset.Name))
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
        Expand-Archive-Flexible -ArchivePath $download -DestinationPath $extractDir
        $exe = Get-ChildItem -Path $extractDir -Recurse -Filter $ExeNameInArchive | Select-Object -First 1
        if (-not $exe) { throw "Could not find $ExeNameInArchive inside $($asset.Name)." }
        Copy-Item -Path $exe.FullName -Destination (Join-Path $InstallDir $FinalExeName) -Force
        Remove-Item $extractDir -Recurse -Force
    }
    Remove-Item $download -Force
    Write-Host "    $Repo $($asset.Version) -> $(Join-Path $InstallDir $FinalExeName)"
}

# --- Prep -------------------------------------------------------------------
Write-Step "Preparing install directory: $InstallDir"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Add-ToUserPath $InstallDir

# --- Enable long paths ------------------------------------------------------
Write-Step "Enabling Windows long path support"
$lpKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'
Set-ItemProperty -Path $lpKey -Name 'LongPathsEnabled' -Value 1 -Type DWord
Write-Host "    LongPathsEnabled = 1 (reboot may be required for all apps to honor it)"

if (Get-Command git -ErrorAction SilentlyContinue) {
    git config --global core.longpaths true
    Write-Host "    git config --global core.longpaths true"
}

# --- OPA --------------------------------------------------------------------
Write-Step "Installing OPA"
$opa = Get-LatestGitHubAsset -Repo 'open-policy-agent/opa' -AssetMatch 'opa_windows_amd64.exe'
$opaPath = Join-Path $InstallDir 'opa.exe'
Invoke-WebRequest -Uri $opa.Url -OutFile $opaPath -UseBasicParsing
Write-Host "    OPA $($opa.Version) -> $opaPath"

# --- Regal ------------------------------------------------------------------
Write-Step "Installing Regal"
$regal = Get-LatestGitHubAsset -Repo 'StyraInc/regal' -AssetMatch 'regal_Windows_x86_64.exe'
$regalPath = Join-Path $InstallDir 'regal.exe'
Invoke-WebRequest -Uri $regal.Url -OutFile $regalPath -UseBasicParsing
Write-Host "    Regal $($regal.Version) -> $regalPath"

# --- Conftest ---------------------------------------------------------------
Write-Step "Installing Conftest"
Install-ArchivedBinary `
    -Repo 'open-policy-agent/conftest' `
    -AssetMatch '*Windows_x86_64.zip' `
    -ExeNameInArchive 'conftest.exe' `
    -FinalExeName 'conftest.exe' `
    -InstallDir $InstallDir

# --- Harbor CLI -------------------------------------------------------------
Write-Step "Installing Harbor CLI"
Install-ArchivedBinary `
    -Repo 'goharbor/harbor-cli' `
    -AssetMatch '*windows_amd64*' `
    -ExeNameInArchive 'harbor*.exe' `
    -FinalExeName 'harbor.exe' `
    -InstallDir $InstallDir

# --- oras -------------------------------------------------------------------
Write-Step "Installing oras"
Install-ArchivedBinary `
    -Repo 'oras-project/oras' `
    -AssetMatch '*_windows_amd64.zip' `
    -ExeNameInArchive 'oras.exe' `
    -FinalExeName 'oras.exe' `
    -InstallDir $InstallDir

# --- Cosign -----------------------------------------------------------------
Write-Step "Installing Cosign"
$cosign = Get-LatestGitHubAsset -Repo 'sigstore/cosign' -AssetMatch 'cosign-windows-amd64.exe'
$cosignPath = Join-Path $InstallDir 'cosign.exe'
Invoke-WebRequest -Uri $cosign.Url -OutFile $cosignPath -UseBasicParsing
Write-Host "    Cosign $($cosign.Version) -> $cosignPath"

# --- pip-based tools --------------------------------------------------------
Write-Step "Installing Semgrep and ggshield via pip"
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "python is not on PATH. Install Python (e.g. 'winget install Python.Python.3.12') and re-run."
}
python -m pip install --upgrade pip
python -m pip install --upgrade semgrep ggshield

# --- git-cliff via winget ---------------------------------------------------
Write-Step "Installing git-cliff via winget"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is not available. Install App Installer from the Microsoft Store."
}
winget install --id orhun.git-cliff --exact --accept-source-agreements --accept-package-agreements

# --- Verify -----------------------------------------------------------------
Write-Step "Verifying installations"
$tools = @(
    @{ Name = 'opa';       Args = 'version' }
    @{ Name = 'regal';     Args = 'version' }
    @{ Name = 'conftest';  Args = '--version' }
    @{ Name = 'harbor';    Args = 'version' }
    @{ Name = 'oras';      Args = 'version' }
    @{ Name = 'cosign';    Args = 'version' }
    @{ Name = 'semgrep';   Args = '--version' }
    @{ Name = 'ggshield';  Args = '--version' }
    @{ Name = 'git-cliff'; Args = '--version' }
