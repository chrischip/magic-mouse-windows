#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Simulated hardware test for the Apple Magic Mouse driver.

.DESCRIPTION
    Uses devcon.exe (Windows Driver Kit) to create a virtual root-enumerated
    device with the Magic Mouse hardware ID, then verifies that Windows binds
    the correct Apple driver to it -- without needing physical Bluetooth
    hardware or an actual Magic Mouse.

    Tests performed:
      1. Driver is staged in the Windows driver store
      2. Signing chain is valid (signtool verify)
      3. Virtual device can be created with the Magic Mouse hardware ID
      4. Windows binds the Apple driver (not the generic HID driver)
      5. Device reports no error code in Device Manager
      6. Virtual device is cleanly removed after the test

.NOTES
    Requires the Windows Driver Kit (WDK) for devcon.exe.
    Run Setup-MagicMouse.ps1 first to install and sign the driver.

    Run as Administrator:
        Set-ExecutionPolicy Bypass -Scope Process -Force
        .\Test-MagicMouseDriver.ps1
#>

$ErrorActionPreference = "Stop"

# Hardware ID from AppleWirelessMouse.inf -- Magic Mouse 2
$testHwId   = "BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205ac_PID&0310"
$driverDir  = "C:\Users\Docker\magicMouseDriver\driver"
$signtool   = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe"

# Locate devcon.exe (WDK installs it under Tools\)
$devcon = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10" -Filter "devcon.exe" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "x64" } |
    Select-Object -First 1 -ExpandProperty FullName

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
$pass  = 0
$fail  = 0
$warns = @()

function Test-Assert($name, $condition, $detail = "") {
    if ($condition) {
        Write-Host "  PASS  $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL  $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red
        $script:fail++
    }
}

function Test-Warn($msg) {
    Write-Host "  WARN  $msg" -ForegroundColor Yellow
    $script:warns += $msg
}

Write-Host ""
Write-Host "Apple Magic Mouse Driver -- Simulation Test" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Test 1: devcon.exe available
# ---------------------------------------------------------------------------
Write-Host "`n[1] Tools" -ForegroundColor Cyan
Test-Assert "devcon.exe found" ($null -ne $devcon) "Install the WDK: winget install Microsoft.WindowsWDK.10.0.26100"
Test-Assert "signtool.exe found" (Test-Path $signtool) "Install the Windows SDK"
if ($null -eq $devcon) {
    Write-Host "`nCannot continue without devcon.exe. Exiting." -ForegroundColor Red
    exit 1
}
Write-Host "    devcon  : $devcon"
Write-Host "    signtool: $signtool"

# ---------------------------------------------------------------------------
# Test 2: Driver is staged in the Windows driver store
# ---------------------------------------------------------------------------
Write-Host "`n[2] Driver store" -ForegroundColor Cyan
$stagedDriver = pnputil /enum-drivers 2>&1 | Select-String -A6 "AppleWirelessMouse" | Select-Object -First 1
Test-Assert "Driver is staged in driver store" ($null -ne $stagedDriver) "Run Setup-MagicMouse.ps1 first"

# ---------------------------------------------------------------------------
# Test 3: Signature validity (signtool verify /pa)
# ---------------------------------------------------------------------------
Write-Host "`n[3] Signature" -ForegroundColor Cyan
foreach ($file in @("AppleWirelessMouse.cat", "AppleWirelessMouse.sys")) {
    $path = Join-Path $driverDir $file
    if (Test-Path $path) {
        $result = & $signtool verify /pa "$path" 2>&1
        $ok = ($result | Select-String "Successfully verified") -ne $null
        Test-Assert "$file signature valid" $ok ($result | Select-String "error|not signed" | Select-Object -First 1)
    } else {
        Test-Warn "$file not found in $driverDir -- skipping signature check"
    }
}

# ---------------------------------------------------------------------------
# Test 4: Create virtual device with Magic Mouse hardware ID
# ---------------------------------------------------------------------------
Write-Host "`n[4] Virtual device creation" -ForegroundColor Cyan

$infPath = Join-Path $driverDir "AppleWirelessMouse.inf"
Test-Assert "INF file present" (Test-Path $infPath)

$devconOut = & $devcon install "$infPath" "$testHwId" 2>&1
$installed  = ($devconOut | Select-String "Device node created|Drivers installed|already installed") -ne $null
$noError    = ($devconOut | Select-String "failed|error" -CaseSensitive:$false) -eq $null
Test-Assert "Virtual device created by devcon" $installed ($devconOut | Out-String).Trim()
Test-Assert "devcon reported no errors"        $noError   ($devconOut | Out-String).Trim()

# Give Windows a moment to bind the driver
Start-Sleep -Seconds 3

# ---------------------------------------------------------------------------
# Test 5: Correct driver bound (Apple, not generic HID)
# ---------------------------------------------------------------------------
Write-Host "`n[5] Driver binding" -ForegroundColor Cyan

$device = Get-PnpDevice | Where-Object {
    $_.HardwareID -like "*VID*05ac*PID*0310*" -or
    $_.FriendlyName -match "Apple Wireless Mouse"
} | Select-Object -First 1

Test-Assert "Device visible in PnP manager"      ($null -ne $device)
Test-Assert "Device name is 'Apple Wireless Mouse'" ($device.FriendlyName -match "Apple Wireless Mouse") "Got: $($device.FriendlyName)"
Test-Assert "Device status is OK (no error code)" ($device.Status -eq "OK") "Status: $($device.Status) -- Code: $($device.ConfigManagerErrorCode)"

if ($device) {
    Write-Host "    Name   : $($device.FriendlyName)"
    Write-Host "    Status : $($device.Status)"
    Write-Host "    HW ID  : $($device.HardwareID | Select-Object -First 1)"
}

# ---------------------------------------------------------------------------
# Test 6: Clean up virtual device
# ---------------------------------------------------------------------------
Write-Host "`n[6] Cleanup" -ForegroundColor Cyan

$removeOut = & $devcon remove "$testHwId" 2>&1
$removed   = ($removeOut | Select-String "removed|no matching") -ne $null
Test-Assert "Virtual device removed" $removed ($removeOut | Out-String).Trim()

# Verify it's gone
Start-Sleep -Seconds 2
$stillThere = Get-PnpDevice | Where-Object { $_.HardwareID -like "*VID*05ac*PID*0310*" }
Test-Assert "Device no longer in PnP manager" ($null -eq $stillThere)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
$total = $pass + $fail
if ($fail -eq 0) {
    Write-Host "  ALL TESTS PASSED  ($pass / $total)" -ForegroundColor Green
} else {
    Write-Host "  $fail FAILED, $pass PASSED  ($total total)" -ForegroundColor Red
}
if ($warns.Count -gt 0) {
    Write-Host "  Warnings:" -ForegroundColor Yellow
    $warns | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
}
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

exit $fail
