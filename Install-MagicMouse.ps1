#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Apple Magic Mouse driver installer.
    Disables HVCI if needed, enables test signing, imports the trust cert,
    installs the driver, and reboots if required.
.NOTES
    Run from the folder containing this script (the driver files and .cer must be alongside it).
    A single reboot may be needed if HVCI or test signing state had to change.
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [!!] $msg" -ForegroundColor Yellow }

$needsReboot = $false

# ---------------------------------------------------------------------------
# 1. HVCI (Memory Integrity) check and disable
# ---------------------------------------------------------------------------
Write-Step "Checking HVCI / Memory Integrity..."

$hvciKey = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
$hvciEnabled = $false

if (Test-Path $hvciKey) {
    $hvciEnabled = (Get-ItemProperty $hvciKey -ErrorAction SilentlyContinue).Enabled -eq 1
}

# Also check the legacy DeviceGuard key
$dgKey = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"
$vbsEnabled = (Get-ItemProperty $dgKey -ErrorAction SilentlyContinue).EnableVirtualizationBasedSecurity -eq 1

if ($hvciEnabled) {
    Write-Warn "HVCI is enabled. Disabling..."
    New-Item -Path $hvciKey -Force | Out-Null
    Set-ItemProperty -Path $hvciKey -Name "Enabled"        -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $hvciKey -Name "WasEnabledBy"   -Value 0 -Type DWord -Force
    # Also ensure VBS isn't forcing it back on
    if (Test-Path $dgKey) {
        Set-ItemProperty -Path $dgKey -Name "EnableVirtualizationBasedSecurity" -Value 0 -Type DWord -Force
    }
    Write-OK "HVCI disabled via registry. Reboot required."
    $needsReboot = $true
} else {
    Write-OK "HVCI is already disabled."
}

# ---------------------------------------------------------------------------
# 2. Test signing
# ---------------------------------------------------------------------------
Write-Step "Checking test signing mode..."

$bcdeditOut = & bcdedit /enum "{current}" 2>&1
$testSigningOn = ($bcdeditOut | Select-String "testsigning\s+Yes") -ne $null

if (-not $testSigningOn) {
    Write-Warn "Test signing is OFF. Enabling..."
    & bcdedit /set testsigning on | Out-Null
    Write-OK "Test signing enabled. Reboot required."
    $needsReboot = $true
} else {
    Write-OK "Test signing is already ON."
}

# ---------------------------------------------------------------------------
# 3. Import trust certificate into Root and TrustedPublisher
# ---------------------------------------------------------------------------
Write-Step "Importing trust certificate..."

$cerFile = Join-Path $scriptDir "MagicMouseTestCert.cer"
if (-not (Test-Path $cerFile)) {
    Write-Error "Certificate not found: $cerFile  -- ensure MagicMouseTestCert.cer is in the same folder as this script."
    exit 1
}

$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cerFile)
Write-Host "    Thumbprint : $($cert.Thumbprint)"
Write-Host "    Subject    : $($cert.Subject)"

foreach ($storeName in @("Root", "TrustedPublisher")) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, "LocalMachine")
    $store.Open("ReadWrite")
    $already = $store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
    if (-not $already) {
        $store.Add($cert)
        Write-OK "Certificate added to LocalMachine\$storeName."
    } else {
        Write-OK "Certificate already present in LocalMachine\$storeName."
    }
    $store.Close()
}

# ---------------------------------------------------------------------------
# 4. Stage driver into the driver store
#    pnputil stages it now; Windows binds it to the device after reboot.
# ---------------------------------------------------------------------------
Write-Step "Installing driver package..."

$infFile = Join-Path $scriptDir "AppleWirelessMouse.inf"
if (-not (Test-Path $infFile)) {
    Write-Error "INF not found: $infFile  -- ensure all driver files are in the same folder as this script."
    exit 1
}

$pnpOut = & pnputil /add-driver "$infFile" /install 2>&1
Write-Host ($pnpOut | Out-String).Trim()

if ($LASTEXITCODE -eq 0) {
    Write-OK "Driver staged successfully."
} elseif ($LASTEXITCODE -eq 3010) {
    Write-OK "Driver staged; reboot required to activate."
    $needsReboot = $true
} else {
    Write-Warn "pnputil returned exit code $LASTEXITCODE -- this is often fine if test signing was just enabled."
    Write-Warn "The driver is likely staged and will bind on next boot."
    $needsReboot = $true
}

# ---------------------------------------------------------------------------
# 5. Register a RunOnce task so Windows forces device re-enumeration after
#    reboot (picks up the driver for an already-paired Magic Mouse).
# ---------------------------------------------------------------------------
if ($needsReboot) {
    $cmd = "pnputil /scan-devices"
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    Set-ItemProperty -Path $regPath -Name "MagicMouseScanDevices" -Value "powershell -Command `"$cmd`"" -Type String
    Write-OK "Registered post-reboot device scan."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
if ($needsReboot) {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  A reboot is required to activate all changes." -ForegroundColor Yellow
    Write-Host "  After rebooting:" -ForegroundColor Yellow
    Write-Host "    1. You will see a 'Test Mode' watermark on the desktop." -ForegroundColor Yellow
    Write-Host "    2. Pair your Magic Mouse via Bluetooth Settings." -ForegroundColor Yellow
    Write-Host "    3. Windows should automatically load the Apple driver." -ForegroundColor Yellow
    Write-Host "    4. Verify in Device Manager: the mouse should show as" -ForegroundColor Yellow
    Write-Host "       'Apple Wireless Mouse' under Mice and other pointing devices." -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    $choice = Read-Host "`nReboot now? [Y/N]"
    if ($choice -match "^[Yy]") {
        Restart-Computer -Force
    } else {
        Write-Host "Remember to reboot before pairing the mouse." -ForegroundColor Yellow
    }
} else {
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  All done -- no reboot needed." -ForegroundColor Green
    Write-Host "  Pair your Magic Mouse via Bluetooth Settings." -ForegroundColor Green
    Write-Host "  It should appear as 'Apple Wireless Mouse' in Device Manager." -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
}
