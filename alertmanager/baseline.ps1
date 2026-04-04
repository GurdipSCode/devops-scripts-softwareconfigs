#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AlertmanagerExePath,

    [Parameter(Mandatory)]
    [string]$SourceConfigPath,

    [Parameter(Mandatory)]
    [string]$DomainServiceAccount,

    [Parameter(Mandatory)]
    [SecureString]$DomainServicePassword,

    [string]$ServiceName = "alertmanager",
    [string]$DisplayName = "Prometheus Alertmanager",
    [string]$ServiceDescription = "Prometheus Alertmanager via Servy",
    [string]$BaseDir = "C:\alertmanager-data",
    [string]$InstallDir = "C:\alertmanager",
    [string]$ListenAddress = "127.0.0.1:9093",
    [string]$Retention = "120h",
    [switch]$StartService
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param($m) Write-Host "[INFO ] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[ OK  ] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[WARN ] $m" -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "[FAIL ] $m" -ForegroundColor Red }

function ConvertTo-PlainText {
    param([SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
}

function Get-LogText {
    param([string]$Path)
    if (Test-Path $Path) {
        try { return Get-Content $Path -Raw }
        catch { return "<unable to read ${Path}: $($_.Exception.Message)>" }
    }
    return ""
}

function Show-Logs {
    param($out,$err)
    Write-Host "`n===== STDOUT =====" -ForegroundColor Yellow
    Write-Host (Get-LogText $out)
    Write-Host "`n===== STDERR =====" -ForegroundColor Yellow
    Write-Host (Get-LogText $err)
}

# Paths
$configDir = Join-Path $BaseDir "config"
$dataDir   = Join-Path $BaseDir "data"
$logDir    = Join-Path $BaseDir "logs"

$configDest = Join-Path $configDir "alertmanager.yml"
$exeDest    = Join-Path $InstallDir "alertmanager.exe"
$stdoutLog  = Join-Path $logDir "servy-stdout.log"
$stderrLog  = Join-Path $logDir "servy-stderr.log"

# Ensure directories
@($InstallDir,$configDir,$dataDir,$logDir) | ForEach-Object {
    if (!(Test-Path $_)) {
        New-Item -ItemType Directory -Path $_ -Force | Out-Null
        Write-Ok "Created $_"
    }
}

# Copy safely
if (!(Test-Path $exeDest) -or ((Resolve-Path $AlertmanagerExePath).Path -ne (Resolve-Path $exeDest -ErrorAction SilentlyContinue))) {
    Copy-Item $AlertmanagerExePath $exeDest -Force
}

if (!(Test-Path $configDest) -or ((Resolve-Path $SourceConfigPath).Path -ne (Resolve-Path $configDest -ErrorAction SilentlyContinue))) {
    Copy-Item $SourceConfigPath $configDest -Force
}

# Servy CLI
$servy = "$env:ProgramFiles\Servy\servy-cli.exe"
if (!(Test-Path $servy)) { throw "servy-cli.exe not found at $servy" }

# ---- PROBE ----
Write-Info "Probing Alertmanager startup"

$probe = Start-Process `
    -FilePath $exeDest `
    -ArgumentList @(
        "--config.file=$configDest",
        "--storage.path=$dataDir",
        "--cluster.listen-address=127.0.0.1:9095",
        "--web.listen-address=127.0.0.1:9094"
    ) `
    -WorkingDirectory $InstallDir `
    -PassThru

Start-Sleep 5

if ($probe.HasExited) {
    Write-Bad "Alertmanager failed to start"
    throw "Fix config before continuing"
}

Stop-Process $probe.Id -Force
Write-Ok "Probe successful"

# ---- DOMAIN CHECK ----
Write-Info "Validating domain credentials"

try {
    $cred = New-Object System.Management.Automation.PSCredential(
        $DomainServiceAccount,
        $DomainServicePassword
    )

    New-PSDrive -Name Z -PSProvider FileSystem -Root "\\$env:COMPUTERNAME\c$" -Credential $cred -ErrorAction Stop | Out-Null
    Remove-PSDrive Z -ErrorAction SilentlyContinue

    Write-Ok "Credential validation succeeded"
}
catch {
    throw "Credential validation failed: $($_.Exception.Message)"
}

$plain = ConvertTo-PlainText $DomainServicePassword

$params = @(
    "--config.file=$configDest"
    "--storage.path=$dataDir"
    "--web.listen-address=$ListenAddress"
    "--cluster.listen-address=127.0.0.1:9095"
    "--data.retention=$Retention"
    "--log.level=info"
) -join " "

# remove existing
& $servy uninstall --quiet --name="$ServiceName" 2>$null

# ---- INSTALL ----
Write-Info "Installing service"

$installOutput = & $servy install `
    --quiet `
    --name="$ServiceName" `
    --displayName="$DisplayName" `
    --description="$ServiceDescription" `
    --path="$exeDest" `
    --startupDir="$InstallDir" `
    --params="$params" `
    --stdout="$stdoutLog" `
    --stderr="$stderrLog" `
    --user="$DomainServiceAccount" `
    --password="$plain" 2>&1

if ($LASTEXITCODE -ne 0) {
    $installOutput | ForEach-Object { Write-Host $_ }

    if ($installOutput -match "1789") {
        throw "ERROR 1789: Domain trust/auth failure (machine cannot talk to AD)"
    }

    throw "Service install failed"
}

Start-Sleep 2

if (!(Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
    throw "Service not created"
}

Write-Ok "Service installed"

# ---- START ----
if ($StartService) {
    try {
        Start-Service $ServiceName -ErrorAction Stop
        Start-Sleep 5

        $svc = Get-Service $ServiceName
        if ($svc.Status -ne "Running") {
            Write-Bad "Service stopped"
            Show-Logs $stdoutLog $stderrLog
            throw "Service failed"
        }

        Write-Ok "Service running"
    }
    catch {
        Write-Bad "Service start failed"
        Show-Logs $stdoutLog $stderrLog

        Write-Host "`n===== WINDOWS EVENTS =====" -ForegroundColor Yellow
        Get-WinEvent -LogName System -MaxEvents 20 |
        Where-Object {$_.Message -match $ServiceName} |
        Format-List TimeCreated,Message

        throw
    }
}

Write-Host "`nDONE" -ForegroundColor Green
