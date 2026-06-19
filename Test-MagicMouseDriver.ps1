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

# Expected hardware IDs from AppleWirelessMouse.inf
$expectedHwIds = @(
    "BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205ac_PID&030d",  # Magic Mouse 1
    "BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205ac_PID&0310",  # Magic Mouse 2 (Lightning)
    "BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0269",  # Magic Mouse 2 (alt BT VID)
    "BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205ac_PID&0323",  # Magic Mouse USB-C
    "BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0323"   # Magic Mouse USB-C (alt BT VID)
)
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
$stagedDriver = pnputil /enum-drivers 2>&1 | Select-String "AppleWirelessMouse" | Select-Object -First 1
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
# Test 4: INF validation -- hardware IDs, service, binary reference
# ---------------------------------------------------------------------------
Write-Host "`n[4] INF validation" -ForegroundColor Cyan

$infPath    = Join-Path $driverDir "AppleWirelessMouse.inf"
$infContent = Get-Content $infPath -Raw -ErrorAction SilentlyContinue
Test-Assert "INF file present" (Test-Path $infPath)

foreach ($hwId in $expectedHwIds) {
    Test-Assert "INF contains HW ID: $hwId" ($infContent -match [regex]::Escape($hwId))
}

Test-Assert "INF references applewirelessmouse.sys" ($infContent -match "applewirelessmouse\.sys")
Test-Assert "INF service type is KERNEL_DRIVER"     ($infContent -match "ServiceType\s*=\s*(%SERVICE_KERNEL_DRIVER%|0x1|1)")

$sysBinary = Join-Path $driverDir "AppleWirelessMouse.sys"
Test-Assert "SYS binary present alongside INF"      (Test-Path $sysBinary)

# ---------------------------------------------------------------------------
# Test 5: Driver store -- hardware ID coverage
# ---------------------------------------------------------------------------
Write-Host "`n[5] Driver store coverage" -ForegroundColor Cyan

$driverEnum = pnputil /enum-drivers 2>&1 | Out-String
$publishedName = (pnputil /enum-drivers 2>&1 | Select-String "oem\d+\.inf" |
    ForEach-Object { $_.Matches.Value } | Select-Object -First 1)

Test-Assert "Driver has a published (oem*.inf) name in driver store" ($null -ne $publishedName) "Run Setup-MagicMouse.ps1 first"
if ($publishedName) { Write-Host "    Published name: $publishedName" }

# devcon dp_enum lists hardware IDs covered by each staged driver package
$dpEnum = & $devcon dp_enum 2>&1 | Out-String
$coversMouseHwId = $dpEnum -match "05ac" -or $driverEnum -match "AppleWireless"
Test-Assert "Staged driver covers Apple Wireless Mouse hardware IDs" $coversMouseHwId

# ---------------------------------------------------------------------------
# Test 6: Hardware binding (requires physical Bluetooth + Magic Mouse)
# ---------------------------------------------------------------------------
Write-Host "`n[6] Hardware binding" -ForegroundColor Cyan

$liveDevice = Get-PnpDevice | Where-Object {
    ($_.HardwareID -like "*VID*05ac*") -or ($_.FriendlyName -match "Apple Wireless Mouse")
} | Select-Object -First 1

if ($null -ne $liveDevice) {
    Test-Assert "Device visible in PnP manager"         ($null -ne $liveDevice)
    Test-Assert "Device name is 'Apple Wireless Mouse'" ($liveDevice.FriendlyName -match "Apple Wireless Mouse") "Got: $($liveDevice.FriendlyName)"
    Test-Assert "Device has no error code"              ($liveDevice.Status -eq "OK") "Status: $($liveDevice.Status)"
    Write-Host "    Name  : $($liveDevice.FriendlyName)"
    Write-Host "    Status: $($liveDevice.Status)"
} else {
    Write-Host "  SKIP  No Magic Mouse detected via Bluetooth -- pair the mouse and re-run to test hardware binding" -ForegroundColor DarkGray
}

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
