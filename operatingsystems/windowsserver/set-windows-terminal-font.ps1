#Requires -RunAsAdministrator
# ============================================================================
# Set Windows Terminal Font - All User Profiles
# ============================================================================

$FontFace = "FiraCode NF"
$FontSize  = 9

function Write-Info { param([string]$m) Write-Host "  $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "  $m" -ForegroundColor Yellow }

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Windows Terminal Font Setter" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ---- Probe registry for exact registered Nerd Font face name ----
Write-Info "Detecting installed Nerd Font..."
$fontSearchNames = @(
    "FiraCode NF",
    "FiraCode Nerd Font Mono",
    "FiraCode Nerd Font",
    "CaskaydiaCove NF",
    "CaskaydiaCove Nerd Font Mono"
)
foreach ($regPath in @("HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts", "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts")) {
    $reg = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    if ($reg) {
        foreach ($candidate in $fontSearchNames) {
            if ($reg.PSObject.Properties | Where-Object { $_.Name -like "*$candidate*" }) {
                $FontFace = $candidate
                break
            }
        }
    }
    if ($FontFace -ne "FiraCode NF") { break }
}
Write-Ok "Font face: $FontFace"

# ---- Build list of ALL user profile LocalAppData paths ----
$allLocalAppDatas = @([string]$env:LOCALAPPDATA)
foreach ($prof in (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" -ErrorAction SilentlyContinue)) {
    if ($prof.ProfileImagePath -and (Test-Path $prof.ProfileImagePath)) {
        $p = Join-Path $prof.ProfileImagePath "AppData\Local"
        if ($allLocalAppDatas -notcontains $p) { $allLocalAppDatas += $p }
    }
}
Write-Info "Checking $($allLocalAppDatas.Count) user profile(s)"

# ---- Write to every settings.json found ----
$updated = 0
foreach ($localAppData in $allLocalAppDatas) {
    $candidates = @(
        "$localAppData\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$localAppData\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$localAppData\Microsoft\Windows Terminal\settings.json"
    )
    foreach ($settingsPath in ($candidates | Where-Object { Test-Path $_ })) {
        try {
            Write-Info "Found: $settingsPath"

            # Unlock in case previously locked
            Set-ItemProperty -Path $settingsPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue

            $raw  = Get-Content -Path $settingsPath -Raw -ErrorAction Stop
            $json = $raw | ConvertFrom-Json -ErrorAction Stop

            # Add profiles node if missing
            if (-not (Get-Member -InputObject $json -Name profiles -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                $json | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            # Add defaults node if missing
            if (-not (Get-Member -InputObject $json.profiles -Name defaults -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            # Add font node if missing
            if (-not (Get-Member -InputObject $json.profiles.defaults -Name font -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                $json.profiles.defaults | Add-Member -NotePropertyName font -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            # Set face
            if (-not (Get-Member -InputObject $json.profiles.defaults.font -Name face -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                $json.profiles.defaults.font | Add-Member -NotePropertyName face -NotePropertyValue $FontFace -Force
            } else {
                $json.profiles.defaults.font.face = $FontFace
            }
            # Set size
            if (-not (Get-Member -InputObject $json.profiles.defaults.font -Name size -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
                $json.profiles.defaults.font | Add-Member -NotePropertyName size -NotePropertyValue $FontSize -Force
            } else {
                $json.profiles.defaults.font.size = $FontSize
            }

            $json | ConvertTo-Json -Depth 60 | Set-Content -Path $settingsPath -Encoding UTF8 -Force

            # Lock read-only so WT cannot overwrite on exit
            Set-ItemProperty -Path $settingsPath -Name IsReadOnly -Value $true -ErrorAction SilentlyContinue

            Write-Ok "Written + locked: $settingsPath"
            $updated++

            # Verify immediately
            $check = Get-Content $settingsPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
            $face  = $check.profiles.defaults.font.face
            $size  = $check.profiles.defaults.font.size
            if ($face) { Write-Ok "VERIFIED: face='$face' size=$size" }
            else       { Write-Warn "VERIFY FAILED - font not found after write" }

        } catch {
            Write-Warn "Failed on $settingsPath - $($_.Exception.Message)"
        }
    }
}

Write-Host ""
if ($updated -gt 0) {
    Write-Ok "Done - $updated file(s) updated. Close and reopen Windows Terminal."
} else {
    Write-Warn "No settings.json found. Open Windows Terminal once then re-run."
}
