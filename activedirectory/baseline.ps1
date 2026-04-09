#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory, GroupPolicy

<#
.SYNOPSIS
    Active Directory Hardening & Best Practices Script
.DESCRIPTION
    Applies security hardening and best practices to Active Directory domain controllers.
    Covers: Account policies, Kerberos, LDAP signing, SMB, audit policies, privileged
    account hygiene, DNS security, SYSVOL permissions, and more.
.NOTES
    Run as Domain Administrator on a Domain Controller.
    Test in a lab environment before deploying to production.
    Some settings require a reboot or gpupdate to take effect.
#>

# ============================================================
#  CONFIGURATION — Review before running
# ============================================================
$LogPath         = "C:\Logs\AD_Hardening_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$DryRun          = $false   # Set to $true to preview changes without applying them
$BackupGPOPath   = "C:\Backup\GPO_Backup_$(Get-Date -Format 'yyyyMMdd')"

# ============================================================
#  HELPERS
# ============================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Write-Host $entry -ForegroundColor $(if ($Level -eq "ERROR") {"Red"} elseif ($Level -eq "WARN") {"Yellow"} else {"Cyan"})
    Add-Content -Path $LogPath -Value $entry
}

function Apply-Setting {
    param([string]$Description, [scriptblock]$Action)
    Write-Log "Applying: $Description"
    if (-not $DryRun) {
        try {
            & $Action
            Write-Log "  SUCCESS: $Description"
        } catch {
            Write-Log "  FAILED: $Description — $_" "ERROR"
        }
    } else {
        Write-Log "  [DRY RUN] Would apply: $Description" "WARN"
    }
}

# ============================================================
#  PRE-FLIGHT
# ============================================================
New-Item -ItemType Directory -Path (Split-Path $LogPath) -Force | Out-Null
Write-Log "============================================================"
Write-Log " Active Directory Hardening Script — $(Get-Date)"
Write-Log " Domain: $env:USERDNSDOMAIN | DC: $env:COMPUTERNAME"
Write-Log " DryRun: $DryRun"
Write-Log "============================================================"

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy     -ErrorAction SilentlyContinue

$Domain    = Get-ADDomain
$Forest    = Get-ADForest
$DomainDN  = $Domain.DistinguishedName
$DomainNC  = $Domain.DNSRoot

Write-Log "Domain DN : $DomainDN"
Write-Log "Forest    : $($Forest.Name)"

# ============================================================
#  1. BACKUP GPOs BEFORE CHANGES
# ============================================================
Write-Log "--- Section 1: GPO Backup ---"
New-Item -ItemType Directory -Path $BackupGPOPath -Force | Out-Null
Apply-Setting "Backup all Group Policy Objects" {
    Get-GPO -All | ForEach-Object {
        Backup-GPO -Guid $_.Id -Path $BackupGPOPath | Out-Null
    }
    Write-Log "  GPO backup saved to: $BackupGPOPath"
}

# ============================================================
#  2. DEFAULT DOMAIN POLICY — Account & Lockout Policies
# ============================================================
Write-Log "--- Section 2: Account & Lockout Policies ---"

# CIS Benchmark / NIST SP 800-63B aligned values
Apply-Setting "Set minimum password length to 14 characters" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -MinPasswordLength 14
}

Apply-Setting "Set password history to 24" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -PasswordHistoryCount 24
}

Apply-Setting "Set maximum password age to 60 days" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -MaxPasswordAge (New-TimeSpan -Days 60)
}

Apply-Setting "Set minimum password age to 1 day" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -MinPasswordAge (New-TimeSpan -Days 1)
}

Apply-Setting "Enable password complexity" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -ComplexityEnabled $true
}

Apply-Setting "Enable reversible encryption OFF" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -ReversibleEncryptionEnabled $false
}

Apply-Setting "Set account lockout threshold to 5 attempts" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -LockoutThreshold 5
}

Apply-Setting "Set account lockout duration to 30 minutes" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -LockoutDuration (New-TimeSpan -Minutes 30)
}

Apply-Setting "Set lockout observation window to 30 minutes" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -LockoutObservationWindow (New-TimeSpan -Minutes 30)
}

# ============================================================
#  3. KERBEROS SETTINGS
# ============================================================
Write-Log "--- Section 3: Kerberos Hardening ---"

Apply-Setting "Set Kerberos maximum ticket age to 10 hours" {
    Set-ADDefaultDomainPasswordPolicy -Identity $DomainNC `
        -MaxTicketAge (New-TimeSpan -Hours 10)   # via Default Domain Policy GPO
}

Apply-Setting "Disable RC4 Kerberos encryption via registry on DC" {
    # Require AES128/AES256 only — disables DES and RC4
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "SupportedEncryptionTypes" -Value 0x7FFFFFF8 -Type DWord
    # 0x7FFFFFF8 = AES128_CTS_HMAC_SHA1_96 + AES256_CTS_HMAC_SHA1_96 + future types
}

Apply-Setting "Enable Kerberos armoring (FAST) — require claims on DC" {
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Kdc\Parameters"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "EnableCbacAndArmor" -Value 1 -Type DWord
}

# ============================================================
#  4. LDAP SECURITY
# ============================================================
Write-Log "--- Section 4: LDAP Signing & Channel Binding ---"

Apply-Setting "Require LDAP server signing (registry)" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
    Set-ItemProperty -Path $regPath -Name "LDAPServerIntegrity" -Value 2 -Type DWord
    # 2 = Require signing
}

Apply-Setting "Enable LDAP channel binding tokens (registry)" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
    Set-ItemProperty -Path $regPath -Name "LdapEnforceChannelBinding" -Value 2 -Type DWord
    # 2 = Always (most secure)
}

Apply-Setting "Disable anonymous LDAP operations" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
    Set-ItemProperty -Path $regPath -Name "DSAHeuristics" -Value "0000002" -Type String
    # Position 7 = '2' disables anonymous LDAP operations
}

# ============================================================
#  5. SMB HARDENING
# ============================================================
Write-Log "--- Section 5: SMB Hardening ---"

Apply-Setting "Disable SMBv1 server" {
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
}

Apply-Setting "Enable SMB signing (required)" {
    Set-SmbServerConfiguration -RequireSecuritySignature $true -Force
    Set-SmbClientConfiguration -RequireSecuritySignature $true -Force
}

Apply-Setting "Enable SMB encryption" {
    Set-SmbServerConfiguration -EncryptData $true -Force
}

Apply-Setting "Disable SMB null sessions" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\LanManServer\Parameters"
    Set-ItemProperty -Path $regPath -Name "RestrictNullSessAccess" -Value 1 -Type DWord
}

# ============================================================
#  6. NTLM RESTRICTIONS
# ============================================================
Write-Log "--- Section 6: NTLM Restrictions ---"

Apply-Setting "Set NTLMv2 only (refuse LM & NTLMv1)" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    Set-ItemProperty -Path $regPath -Name "LmCompatibilityLevel" -Value 5 -Type DWord
    # 5 = Refuse LM/NTLM; accept NTLMv2 only
}

Apply-Setting "Enable Extended Protection for Authentication (EPA)" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\LSA"
    Set-ItemProperty -Path $regPath -Name "SuppressExtendedProtection" -Value 0 -Type DWord
}

Apply-Setting "Disable NTLM authentication to all remote servers (audit first)" {
    # Start with auditing before blocking — change to 4 to block after review
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "AuditReceivingNTLMTraffic" -Value 2 -Type DWord
    Set-ItemProperty -Path $regPath -Name "RestrictSendingNTLMTraffic" -Value 1 -Type DWord
}

# ============================================================
#  7. AUDIT POLICY (Advanced)
# ============================================================
Write-Log "--- Section 7: Advanced Audit Policy ---"

$auditSettings = @{
    "Account Logon\Credential Validation"              = "Success,Failure"
    "Account Logon\Kerberos Authentication Service"    = "Success,Failure"
    "Account Logon\Kerberos Service Ticket Operations" = "Success,Failure"
    "Account Management\Computer Account Management"   = "Success,Failure"
    "Account Management\Other Account Management Events" = "Success,Failure"
    "Account Management\Security Group Management"     = "Success,Failure"
    "Account Management\User Account Management"       = "Success,Failure"
    "DS Access\Directory Service Access"               = "Success,Failure"
    "DS Access\Directory Service Changes"              = "Success,Failure"
    "Logon/Logoff\Account Lockout"                     = "Success,Failure"
    "Logon/Logoff\Logon"                               = "Success,Failure"
    "Logon/Logoff\Logoff"                              = "Success"
    "Logon/Logoff\Special Logon"                       = "Success"
    "Object Access\SAM"                                = "Success,Failure"
    "Policy Change\Audit Policy Change"                = "Success,Failure"
    "Policy Change\Authentication Policy Change"       = "Success,Failure"
    "Privilege Use\Sensitive Privilege Use"            = "Success,Failure"
    "System\Security State Change"                     = "Success,Failure"
    "System\Security System Extension"                 = "Success,Failure"
    "System\System Integrity"                          = "Success,Failure"
}

foreach ($category in $auditSettings.Keys) {
    $flags = $auditSettings[$category]
    Apply-Setting "Audit: $category = $flags" {
        $parts    = $category -split "\\"
        $subcategory = $parts[1]
        $success  = $flags -match "Success"
        $failure  = $flags -match "Failure"
        $sFlag    = if ($success) { "enable" } else { "disable" }
        $fFlag    = if ($failure) { "enable" } else { "disable" }
        auditpol /set /subcategory:"$subcategory" /success:$sFlag /failure:$fFlag | Out-Null
    }
}

Apply-Setting "Set Security event log size to 4GB" {
    wevtutil sl Security /ms:4294967296 | Out-Null
}

Apply-Setting "Set Application event log size to 512MB" {
    wevtutil sl Application /ms:536870912 | Out-Null
}

# ============================================================
#  8. PRIVILEGED ACCOUNT HYGIENE
# ============================================================
Write-Log "--- Section 8: Privileged Account Hygiene ---"

Apply-Setting "Rename the built-in Administrator account" {
    # Change 'Administrator' to a less-predictable name
    $newName = "LocalSysAdmin"
    $builtinAdmin = Get-ADUser -Filter {SamAccountName -eq "Administrator"}
    if ($builtinAdmin) {
        Rename-ADObject -Identity $builtinAdmin.DistinguishedName -NewName $newName
        Set-ADUser -Identity $builtinAdmin -SamAccountName $newName -UserPrincipalName "$newName@$DomainNC"
        Write-Log "  Renamed built-in Administrator to '$newName'"
    }
}

Apply-Setting "Disable the built-in Guest account" {
    Disable-ADAccount -Identity "Guest"
}

Apply-Setting "Disable KRBTGT password last set check (ensure it's been rotated recently)" {
    $krbtgt = Get-ADUser -Identity krbtgt -Properties PasswordLastSet
    $daysSinceChange = ((Get-Date) - $krbtgt.PasswordLastSet).Days
    if ($daysSinceChange -gt 180) {
        Write-Log "  WARNING: KRBTGT password last changed $daysSinceChange days ago — consider rotating!" "WARN"
    } else {
        Write-Log "  KRBTGT password is $daysSinceChange days old — OK"
    }
}

Apply-Setting "Enable Protected Users security group for all admin accounts" {
    $protectedUsersGroup = Get-ADGroup "Protected Users"
    $adminGroups = @("Domain Admins","Enterprise Admins","Schema Admins","Administrators")
    foreach ($grp in $adminGroups) {
        try {
            $members = Get-ADGroupMember -Identity $grp -Recursive |
                       Where-Object { $_.objectClass -eq "user" }
            foreach ($member in $members) {
                $inProtected = Get-ADGroupMember -Identity "Protected Users" |
                               Where-Object { $_.SamAccountName -eq $member.SamAccountName }
                if (-not $inProtected) {
                    Add-ADGroupMember -Identity "Protected Users" -Members $member
                    Write-Log "  Added $($member.SamAccountName) to Protected Users"
                }
            }
        } catch { Write-Log "  Could not process $grp : $_" "WARN" }
    }
}

Apply-Setting "Set AdminSDHolder ACL propagation interval to 60 minutes (default is ok, just logging)" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
    $val = (Get-ItemProperty -Path $regPath -Name "AdminSDProtectFrequency" -ErrorAction SilentlyContinue)
    if ($val) {
        Write-Log "  AdminSDProtectFrequency = $($val.AdminSDProtectFrequency) seconds"
    } else {
        Write-Log "  AdminSDProtectFrequency not set — using default (3600s)"
    }
}

# ============================================================
#  9. FINE-GRAINED PASSWORD POLICIES FOR ADMINS
# ============================================================
Write-Log "--- Section 9: Fine-Grained Password Policy for Admins ---"

Apply-Setting "Create stricter Fine-Grained Password Policy for Domain Admins" {
    $psoName = "AdminPasswordPolicy"
    $existing = Get-ADFineGrainedPasswordPolicy -Filter {Name -eq $psoName} -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-ADFineGrainedPasswordPolicy -Name $psoName `
            -Precedence 10 `
            -MinPasswordLength 20 `
            -PasswordHistoryCount 24 `
            -ComplexityEnabled $true `
            -ReversibleEncryptionEnabled $false `
            -MaxPasswordAge (New-TimeSpan -Days 30) `
            -MinPasswordAge (New-TimeSpan -Days 1) `
            -LockoutThreshold 3 `
            -LockoutDuration (New-TimeSpan -Hours 1) `
            -LockoutObservationWindow (New-TimeSpan -Hours 1) `
            -Description "Stricter policy for privileged admin accounts"
        Write-Log "  Created PSO: $psoName"
    } else {
        Write-Log "  PSO '$psoName' already exists — skipping"
    }
    # Apply to Domain Admins group
    Add-ADFineGrainedPasswordPolicySubject -Identity $psoName -Subjects "Domain Admins" -ErrorAction SilentlyContinue
}

# ============================================================
#  10. SYSVOL & NETLOGON SHARE PERMISSIONS
# ============================================================
Write-Log "--- Section 10: SYSVOL / NETLOGON Hardening ---"

Apply-Setting "Ensure SYSVOL uses DFS-R (not FRS)" {
    $dfsrStatus = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\DFSR\Parameters\SysVols\Migrating Sysvols" -ErrorAction SilentlyContinue
    if ($dfsrStatus) {
        Write-Log "  SYSVOL migration state: $($dfsrStatus.'Local State')"
    } else {
        Write-Log "  DFSR SYSVOL migration key not found — may already be fully migrated"
    }
}

Apply-Setting "Remove 'Everyone' from NETLOGON and SYSVOL share write permissions" {
    foreach ($share in @("NETLOGON","SYSVOL")) {
        $acl = Get-Acl "\\$env:COMPUTERNAME\$share" -ErrorAction SilentlyContinue
        if ($acl) {
            $everyoneRules = $acl.Access | Where-Object {
                $_.IdentityReference -like "*Everyone*" -and
                $_.FileSystemRights -match "Write|FullControl"
            }
            foreach ($rule in $everyoneRules) {
                $acl.RemoveAccessRule($rule) | Out-Null
                Write-Log "  Removed $($rule.FileSystemRights) for Everyone on $share"
            }
            Set-Acl "\\$env:COMPUTERNAME\$share" $acl
        }
    }
}

# ============================================================
#  11. DNS SECURITY
# ============================================================
Write-Log "--- Section 11: DNS Hardening ---"

Apply-Setting "Disable DNS recursion on DC (internal DNS only)" {
    # Only do this if DCs are not acting as forwarders for external resolution
    # dnscmd /config /norecursion 1
    Write-Log "  NOTE: Recursion disabled only if DNS is strictly internal. Skipping auto-change — review manually." "WARN"
}

Apply-Setting "Enable DNS audit logging" {
    $dnsLogPath = "C:\Windows\System32\dns\dns.log"
    dnscmd /config /logfilemaxsize 0x4000000  | Out-Null   # 64MB
    dnscmd /config /loglevel 0x8100F331       | Out-Null   # Log queries, answers, updates
    Write-Log "  DNS debug logging enabled at $dnsLogPath"
}

Apply-Setting "Restrict DNS zone transfers to authorised servers only" {
    Get-DnsServerZone | Where-Object { -not $_.IsAutoCreated -and -not $_.IsReverseLookupZone } | ForEach-Object {
        Set-DnsServerPrimaryZone -Name $_.ZoneName -SecureSecondaries TransferToSecureServers -ErrorAction SilentlyContinue
        Write-Log "  Zone '$($_.ZoneName)': transfers restricted to secure servers"
    }
}

# ============================================================
#  12. LSA & CREDENTIAL PROTECTION
# ============================================================
Write-Log "--- Section 12: LSA / Credential Protection ---"

Apply-Setting "Enable LSA Protection (RunAsPPL)" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    Set-ItemProperty -Path $regPath -Name "RunAsPPL" -Value 1 -Type DWord
    Write-Log "  RunAsPPL set — REBOOT REQUIRED to take effect"
}

Apply-Setting "Enable Credential Guard (UEFI/Hyper-V required)" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    Set-ItemProperty -Path $regPath -Name "LsaCfgFlags" -Value 1 -Type DWord
    $dgiPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard"
    if (-not (Test-Path $dgiPath)) { New-Item -Path $dgiPath -Force | Out-Null }
    Set-ItemProperty -Path $dgiPath -Name "EnableVirtualizationBasedSecurity" -Value 1 -Type DWord
    Set-ItemProperty -Path $dgiPath -Name "RequirePlatformSecurityFeatures"   -Value 3 -Type DWord
    Set-ItemProperty -Path $dgiPath -Name "LsaCfgFlags"                        -Value 1 -Type DWord
    Write-Log "  Credential Guard configured — requires UEFI + Hyper-V + REBOOT"
}

Apply-Setting "Disable WDigest plaintext credential caching" {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "UseLogonCredential" -Value 0 -Type DWord
}

Apply-Setting "Enable Protected Mode for Local Security Authority" {
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\LSASS.exe"
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "AuditLevel" -Value 8 -Type DWord
}

# ============================================================
#  13. WINDOWS FIREWALL ON DCS
# ============================================================
Write-Log "--- Section 13: Windows Firewall ---"

Apply-Setting "Ensure Windows Firewall is enabled on all profiles" {
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True
}

Apply-Setting "Block inbound SMBv1 (TCP 445 from legacy sources)" {
    # This is informational — tighten the DC firewall via GPO in production
    Write-Log "  Ensure inbound firewall rules restrict TCP 445 to authorised management hosts only via GPO." "WARN"
}

# ============================================================
#  14. ACTIVE DIRECTORY TIERING REMINDER
# ============================================================
Write-Log "--- Section 14: AD Tiering Recommendations ---"
Write-Log "  REMINDER: Implement a 3-tier AD model (Tier 0/1/2) to prevent privilege escalation." "WARN"
Write-Log "  REMINDER: Use Privileged Access Workstations (PAWs) for all Tier 0 admin tasks." "WARN"
Write-Log "  REMINDER: Enable Microsoft Defender for Identity (MDI) for threat detection." "WARN"
Write-Log "  REMINDER: Rotate the KRBTGT password at least every 180 days (twice in quick succession)." "WARN"
Write-Log "  REMINDER: Audit and remove stale/inactive accounts and groups quarterly." "WARN"
Write-Log "  REMINDER: Deploy Microsoft LAPS for all domain-joined workstation local admin passwords." "WARN"

# ============================================================
#  15. FINAL: FORCE GROUP POLICY UPDATE
# ============================================================
Write-Log "--- Section 15: Apply Group Policy ---"
Apply-Setting "Force Group Policy update" {
    gpupdate /force | Out-Null
}

# ============================================================
#  SUMMARY
# ============================================================
Write-Log "============================================================"
Write-Log " Hardening script complete."
Write-Log " Log file: $LogPath"
Write-Log " GPO Backup: $BackupGPOPath"
Write-Log ""
Write-Log " ACTION REQUIRED:"
Write-Log "  1. Review $LogPath for any WARNs or ERRORs"
Write-Log "  2. REBOOT this DC to activate LSA Protection & Credential Guard"
Write-Log "  3. Test authentication and replication after reboot"
Write-Log "  4. Roll out to remaining DCs one at a time"
Write-Log "  5. Validate with: Invoke-ADDSDeployment health checks & dcdiag /test:all"
Write-Log "============================================================"
