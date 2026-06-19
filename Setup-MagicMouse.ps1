#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-command Apple Magic Mouse driver installer for Windows.

.DESCRIPTION
    Fully self-contained setup script. On a vanilla Windows machine it will:
      1. Download 7-Zip (if not already installed) -- needed to unpack Apple's pkg/dmg
      2. Fetch the latest Boot Camp ESD from Apple's software update catalog
      3. Extract the Apple Wireless Mouse driver (INF + SYS + CAT)
      4. Generate a fresh self-signed code-signing certificate unique to THIS machine
      5. Re-sign the driver package with that certificate
      6. Disable HVCI (Memory Integrity) if it is currently enabled
      7. Enable Windows test-signing mode
      8. Install the certificate into the local trust stores
      9. Stage the driver with pnputil
     10. Offer to reboot

    Every user who runs this script generates their own certificate -- no shared
    root CA is distributed, which is safer for an open-source tool.

.NOTES
    One-liner (no git required -- works on any vanilla Windows machine):
        Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/chrischip/magic-mouse-windows/main/Setup-MagicMouse.ps1 | iex

    Or clone and run locally:
        Set-ExecutionPolicy Bypass -Scope Process -Force
        .\Setup-MagicMouse.ps1

    Tested on Windows 10 21H2+ and Windows 11.
    Secure Boot does not need to be disabled.
    HVCI will be disabled automatically if it is on (requires reboot).
#>

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"   # speeds up Invoke-WebRequest significantly

# Admin check that works both when run as a .ps1 file and when piped via irm | iex
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run from an elevated (Administrator) PowerShell prompt." -ForegroundColor Red
    Write-Host ""
    Write-Host "Right-click PowerShell and choose 'Run as administrator', then run:" -ForegroundColor Yellow
    Write-Host "  Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/chrischip/magic-mouse-windows/main/Setup-MagicMouse.ps1 | iex" -ForegroundColor Cyan
    exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step($n, $msg) { Write-Host "`n[$n] $msg" -ForegroundColor Cyan }
function Write-OK($msg)       { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn($msg)     { Write-Host "    !!  $msg" -ForegroundColor Yellow }
function Write-Info($msg)     { Write-Host "        $msg" }

function Get-FileViaWebRequest($url, $dest, $description) {
    Write-Info "Downloading: $description"
    Write-Info "Source     : $url"
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    $size = (Get-Item $dest).Length
    Write-OK "Saved $([math]::Round($size/1MB,1)) MB -> $dest"
}

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------
$workDir    = Join-Path $env:TEMP "MagicMouseSetup"
$driverDir  = Join-Path $workDir  "driver"
New-Item -ItemType Directory -Force $workDir  | Out-Null
New-Item -ItemType Directory -Force $driverDir | Out-Null
Write-Host "Work directory: $workDir" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Step 1 -- 7-Zip
# ---------------------------------------------------------------------------
Write-Step 1 "Checking for 7-Zip..."

$7z = "C:\Program Files\7-Zip\7z.exe"
if (-not (Test-Path $7z)) {
    Write-Warn "7-Zip not found. Installing..."
    $msiUrl  = "https://7-zip.org/a/7z2409-x64.msi"
    $msiPath = Join-Path $workDir "7z-x64.msi"
    Get-FileViaWebRequest $msiUrl $msiPath "7-Zip installer"
    Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /qn /norestart" -Wait
    if (-not (Test-Path $7z)) { throw "7-Zip installation failed. Please install it manually from https://www.7-zip.org/" }
    Write-OK "7-Zip installed."
} else {
    Write-OK "7-Zip already installed: $7z"
}

# ---------------------------------------------------------------------------
# Step 2 -- Locate Boot Camp ESD from Apple's software update catalog
# ---------------------------------------------------------------------------
Write-Step 2 "Locating Boot Camp driver package from Apple's update catalog..."

$catalogUrl = "https://swscan.apple.com/content/catalogs/others/index-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
$esdFallback = "http://swcdn.apple.com/content/downloads/48/61/061-97204/zjcotww2iqibyvy6wbx3q9d50ca4lhig85/BootCampESD.pkg"
$esdUrl = $null

try {
    Write-Info "Fetching Apple software update catalog (this may take a moment)..."
    [xml]$catalog = (Invoke-WebRequest -Uri $catalogUrl -UseBasicParsing).Content

    # The plist structure: plist > dict > dict (Products) > dict (each product)
    $products = $catalog.plist.dict.ChildNodes | Where-Object { $_.Name -eq "dict" }

    $candidates = @()
    foreach ($product in $products) {
        $nodes    = $product.ChildNodes
        $pkgUrl   = $null
        $postDate = $null
        $isBC     = $false

        for ($i = 0; $i -lt $nodes.Count; $i++) {
            $node = $nodes[$i]
            if ($node.Name -eq "key" -and $node.InnerText -eq "Packages") {
                # Next sibling is an array of package dicts
                $pkgArray = $nodes[$i+1]
                foreach ($pkg in $pkgArray.ChildNodes) {
                    if ($pkg.Name -ne "dict") { continue }
                    $pkgNodes = $pkg.ChildNodes
                    for ($j = 0; $j -lt $pkgNodes.Count; $j++) {
                        if ($pkgNodes[$j].Name -eq "key" -and $pkgNodes[$j].InnerText -eq "URL") {
                            $url = $pkgNodes[$j+1].InnerText
                            if ($url -match "BootCampESD") { $pkgUrl = $url }
                        }
                    }
                }
            }
            if ($node.Name -eq "key" -and $node.InnerText -eq "PostDate") {
                $postDate = $nodes[$i+1].InnerText
            }
            if ($node.Name -eq "string" -and $node.InnerText -match "BootCamp") {
                $isBC = $true
            }
        }

        if ($isBC -and $pkgUrl) {
            $candidates += [PSCustomObject]@{ Url = $pkgUrl; PostDate = $postDate }
        }
    }

    if ($candidates.Count -gt 0) {
        $best = $candidates | Sort-Object PostDate -Descending | Select-Object -First 1
        $esdUrl = $best.Url
        Write-OK "Found ESD posted $($best.PostDate)"
        Write-Info "URL: $esdUrl"
    }
} catch {
    Write-Warn "Catalog lookup failed: $_"
}

if (-not $esdUrl) {
    Write-Warn "Falling back to known-good Boot Camp 6.1 ESD URL..."
    $esdUrl = $esdFallback
}

# ---------------------------------------------------------------------------
# Step 3 -- Download and extract Boot Camp ESD
# ---------------------------------------------------------------------------
Write-Step 3 "Downloading Boot Camp ESD (~700 MB)..."

$pkgPath    = Join-Path $workDir "BootCampESD.pkg"
$extract1   = Join-Path $workDir "extract1"
$extract2   = Join-Path $workDir "extract2"
$extractDmg = Join-Path $workDir "extractDmg"

if (Test-Path $pkgPath) {
    Write-OK "Already downloaded, skipping."
} else {
    # Use BITS for large download -- shows progress in the console
    try {
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $esdUrl -Destination $pkgPath -Description "Boot Camp ESD" -DisplayName "Apple Boot Camp"
    } catch {
        Write-Warn "BITS unavailable, falling back to WebRequest..."
        $ProgressPreference = "Continue"
        Invoke-WebRequest -Uri $esdUrl -OutFile $pkgPath -UseBasicParsing
        $ProgressPreference = "SilentlyContinue"
    }
    Write-OK "Downloaded: $([math]::Round((Get-Item $pkgPath).Length/1MB,0)) MB"
}

Write-Step 3 "Extracting Boot Camp ESD (3 layers: pkg > cpio > dmg)..."

# Layer 1: XAR (pkg) -> Payload~
New-Item -ItemType Directory -Force $extract1 | Out-Null
Write-Info "Layer 1: unpacking .pkg (XAR archive)..."
& $7z x $pkgPath -o"$extract1" -y | Out-Null

$payloadFile = Get-ChildItem $extract1 -Filter "Payload*" | Select-Object -First 1
if (-not $payloadFile) { throw "Could not find Payload file after pkg extraction. The ESD format may have changed." }

# Layer 2: CPIO -> WindowsSupport.dmg
New-Item -ItemType Directory -Force $extract2 | Out-Null
Write-Info "Layer 2: unpacking CPIO payload..."
& $7z x $payloadFile.FullName -o"$extract2" -y | Out-Null

$dmgFile = Get-ChildItem $extract2 -Filter "*.dmg" -Recurse | Select-Object -First 1
if (-not $dmgFile) { throw "Could not find WindowsSupport.dmg after CPIO extraction." }

# Layer 3: DMG (HFS+) -> driver files
New-Item -ItemType Directory -Force $extractDmg | Out-Null
Write-Info "Layer 3: unpacking DMG (HFS+ image)..."
& $7z x $dmgFile.FullName -o"$extractDmg" -y | Out-Null

# Locate the Magic Mouse driver folder
$mouseDriverSrc = Get-ChildItem $extractDmg -Filter "AppleWirelessMouse" -Recurse -Directory | Select-Object -First 1
if (-not $mouseDriverSrc) { throw "AppleWirelessMouse driver folder not found inside the DMG." }

Write-OK "Found driver: $($mouseDriverSrc.FullName)"

# Copy the three driver files to our working driver dir
Copy-Item (Join-Path $mouseDriverSrc.FullName "*") $driverDir -Force
Write-OK "Driver files staged:"
Get-ChildItem $driverDir | ForEach-Object { Write-Info "$($_.Name)  ($($_.Length) bytes)" }

# ---------------------------------------------------------------------------
# Step 3b -- Patch INF to add USB-C Magic Mouse hardware IDs
#             Apple's 2019 INF predates the USB-C model (2023, PID 0x0323).
#             We add candidate Bluetooth hardware IDs so the driver binds on
#             both VID variants (05ac = Apple USB VID, 004c = Apple BT VID).
# ---------------------------------------------------------------------------
$infPath = Get-ChildItem $driverDir -Filter "AppleWirelessMouse.inf" | Select-Object -First 1 -ExpandProperty FullName
if ($infPath) {
    $infContent = Get-Content $infPath -Raw
    $usbcEntries = @(
        '%AppleWirelessMouse.DeviceDesc%=AppleWirelessMouse,   BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&000205ac_PID&0323',
        '%AppleWirelessMouse.DeviceDesc%=AppleWirelessMouse,   BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0323'
    )
    $insertAfter = 'BTHENUM\{00001124-0000-1000-8000-00805f9b34fb}_VID&0001004c_PID&0269'
    if ($infContent -notmatch [regex]::Escape('PID&0323')) {
        $patch = "`r`n; Magic Mouse (USB-C, 2023) -- PID 0x0323 per Linux kernel 6.16`r`n" + ($usbcEntries -join "`r`n")
        $infContent = $infContent -replace ([regex]::Escape($insertAfter)), "$insertAfter$patch"
        [System.IO.File]::WriteAllText($infPath, $infContent, [System.Text.Encoding]::ASCII)
        Write-OK "INF patched: added USB-C Magic Mouse hardware IDs (PID 0x0323)"
    } else {
        Write-OK "INF already contains USB-C hardware IDs."
    }
}

# ---------------------------------------------------------------------------
# Step 4 -- Generate a self-signed code-signing certificate
#            Each user gets their own -- nothing pre-signed is distributed.
# ---------------------------------------------------------------------------
Write-Step 4 "Generating a self-signed code-signing certificate for THIS machine..."

$certSubject = "CN=MagicMouseDriver-$(hostname)-$(Get-Date -Format 'yyyyMMdd')"
$certStore   = "Cert:\LocalMachine\My"

$cert = New-SelfSignedCertificate `
    -Subject $certSubject `
    -CertStoreLocation $certStore `
    -KeyUsage DigitalSignature `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3") `
    -Type CodeSigningCert `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(10)

Write-OK "Certificate created."
Write-Info "Subject    : $($cert.Subject)"
Write-Info "Thumbprint : $($cert.Thumbprint)"
Write-Info "Expires    : $($cert.NotAfter)"

# ---------------------------------------------------------------------------
# Step 5 -- Sign the driver files with Set-AuthenticodeSignature
#            (built-in PowerShell -- no signtool / WDK required)
# ---------------------------------------------------------------------------
Write-Step 5 "Signing driver files with the new certificate..."

$filesToSign = Get-ChildItem $driverDir -Include "*.sys","*.cat" -Recurse

foreach ($f in $filesToSign) {
    $result = Set-AuthenticodeSignature `
        -FilePath $f.FullName `
        -Certificate $cert `
        -HashAlgorithm SHA256 `
        -TimestampServer "http://timestamp.digicert.com"

    if ($result.Status -eq "Valid") {
        Write-OK "Signed: $($f.Name)"
    } else {
        # Timestamp server may be unreachable -- retry without it
        Write-Warn "Timestamp failed, retrying without timestamp server..."
        $result = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -HashAlgorithm SHA256
        if ($result.Status -eq "Valid") {
            Write-OK "Signed (no timestamp): $($f.Name)"
        } else {
            throw "Failed to sign $($f.Name): $($result.StatusMessage)"
        }
    }
}

# ---------------------------------------------------------------------------
# Step 6 -- Disable HVCI (Memory Integrity) if currently enabled
# ---------------------------------------------------------------------------
Write-Step 6 "Checking HVCI / Memory Integrity..."

$needsReboot  = $false
$hvciKey      = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
$dgKey        = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"
$hvciEnabled  = (Get-ItemProperty $hvciKey -ErrorAction SilentlyContinue).Enabled -eq 1

if ($hvciEnabled) {
    Write-Warn "HVCI is ON. Disabling via registry..."
    New-Item -Path $hvciKey -Force | Out-Null
    Set-ItemProperty -Path $hvciKey -Name "Enabled"      -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $hvciKey -Name "WasEnabledBy" -Value 0 -Type DWord -Force
    if (Test-Path $dgKey) {
        Set-ItemProperty -Path $dgKey -Name "EnableVirtualizationBasedSecurity" -Value 0 -Type DWord -Force
    }
    Write-OK "HVCI disabled. Reboot required."
    $needsReboot = $true
} else {
    Write-OK "HVCI is already disabled."
}

# ---------------------------------------------------------------------------
# Step 7 -- Enable test-signing mode
# ---------------------------------------------------------------------------
Write-Step 7 "Checking test-signing mode..."

$bcdeditOut     = & bcdedit /enum "{current}" 2>&1
$testSigningOn  = ($bcdeditOut | Select-String "testsigning\s+Yes") -ne $null

if (-not $testSigningOn) {
    Write-Warn "Test signing is OFF. Enabling..."
    & bcdedit /set testsigning on | Out-Null
    Write-OK "Test signing enabled. Reboot required."
    $needsReboot = $true
} else {
    Write-OK "Test signing is already ON."
}

# ---------------------------------------------------------------------------
# Step 8 -- Trust the certificate in LocalMachine\Root and TrustedPublisher
# ---------------------------------------------------------------------------
Write-Step 8 "Installing certificate into system trust stores..."

foreach ($storeName in @("Root", "TrustedPublisher")) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, "LocalMachine")
    $store.Open("ReadWrite")
    if (-not ($store.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
        $store.Add($cert)
        Write-OK "Certificate added to LocalMachine\$storeName."
    } else {
        Write-OK "Certificate already in LocalMachine\$storeName."
    }
    $store.Close()
}

# ---------------------------------------------------------------------------
# Step 9 -- Stage driver with pnputil
# ---------------------------------------------------------------------------
Write-Step 9 "Staging driver package..."

$infFile = Join-Path $driverDir "AppleWirelessMouse.inf"
$pnpOut  = & pnputil /add-driver "$infFile" /install 2>&1
Write-Host ($pnpOut | Out-String).Trim()

if ($LASTEXITCODE -eq 0) {
    Write-OK "Driver staged and installed."
} elseif ($LASTEXITCODE -eq 3010) {
    Write-OK "Driver staged; will activate on next boot."
    $needsReboot = $true
} else {
    Write-Warn "pnputil exit code: $LASTEXITCODE"
    Write-Warn "Driver may be staged but waiting for test-signing reboot to validate."
    $needsReboot = $true
}

# ---------------------------------------------------------------------------
# Step 10 -- Register post-reboot device scan so an already-paired mouse is
#             picked up immediately without having to re-pair it.
# ---------------------------------------------------------------------------
if ($needsReboot) {
    $runOncePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
    Set-ItemProperty $runOncePath "MagicMouseScanDevices" `
        "powershell -NonInteractive -Command `"pnputil /scan-devices`"" -Type String
    Write-OK "Registered post-reboot device re-scan."
}

# ---------------------------------------------------------------------------
# Cleanup (offer to remove the ~2 GB of downloaded/extracted files)
# ---------------------------------------------------------------------------
Write-Host ""
$clean = Read-Host "Delete the $([math]::Round((Get-ChildItem $workDir -Recurse | Measure-Object -Property Length -Sum).Sum/1MB,0)) MB of downloaded/extracted files? [Y/N]"
if ($clean -match "^[Yy]") {
    Remove-Item $workDir -Recurse -Force
    Write-OK "Work directory removed."
} else {
    Write-Info "Files kept at: $workDir"
}

# ---------------------------------------------------------------------------
# Summary + reboot
# ---------------------------------------------------------------------------
Write-Host ""
if ($needsReboot) {
    Write-Host "================================================================" -ForegroundColor Yellow
    Write-Host "  Setup complete. A reboot is required." -ForegroundColor Yellow
    Write-Host "" -ForegroundColor Yellow
    Write-Host "  After rebooting:" -ForegroundColor Yellow
    Write-Host "    * A 'Test Mode' watermark will appear on the desktop." -ForegroundColor Yellow
    Write-Host "    * Pair your Magic Mouse via Bluetooth Settings." -ForegroundColor Yellow
    Write-Host "    * It should appear as 'Apple Wireless Mouse' in Device Manager" -ForegroundColor Yellow
    Write-Host "      under Mice and other pointing devices." -ForegroundColor Yellow
    Write-Host "================================================================" -ForegroundColor Yellow
    $choice = Read-Host "`nReboot now? [Y/N]"
    if ($choice -match "^[Yy]") { Restart-Computer -Force }
} else {
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host "  All done -- no reboot required." -ForegroundColor Green
    Write-Host "  Pair your Magic Mouse via Bluetooth Settings." -ForegroundColor Green
    Write-Host "================================================================" -ForegroundColor Green
}
