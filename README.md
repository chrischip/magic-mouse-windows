# Apple Magic Mouse Driver for Windows

> ### ⚠️ EARLY DEVELOPMENT — HIGH RISK
>
> **This project is experimental and has not been widely tested.**
> It makes low-level changes to your Windows kernel configuration that
> cannot be undone without manual steps and a reboot.
>
> **Do NOT run this on:**
> - Work or corporate laptops
> - Machines storing sensitive data or credentials
> - Any machine you cannot afford to spend time recovering
>
> **Expect:**
> - Possible driver load failures (blue screen / reboot loop in worst case)
> - A permanent "Test Mode" watermark on your desktop
> - Reduced kernel security until you manually undo the changes
>
> **This is suitable for:** personal machines, spare laptops, and VMs where
> you understand the risks and know how to restore Windows if something
> goes wrong. See the [Uninstalling](#uninstalling) section for full
> rollback instructions.
>
> Use at your own risk. No warranty is provided.

---

Installs Apple's Magic Mouse driver on Windows by fetching it directly from
Apple's Boot Camp CDN, signing it with a machine-generated certificate, and
configuring the system to load it.

---

## Supported Models

| Model | Bluetooth PID | Status |
|---|---|---|
| Magic Mouse 1 | `030d` | Supported |
| Magic Mouse 2 (Lightning) | `0310` | Supported |
| Magic Mouse (USB-C, 2023) | `0323` | Likely supported — PID unconfirmed on Windows |

The USB-C model hardware ID is based on the Linux kernel 6.16 patch that added
support for it. If you have the USB-C model and the driver doesn't bind after
pairing, open Device Manager, find the mouse under Bluetooth, check its hardware
ID in Properties → Details, and open a GitHub issue with that value.

---

## Install — one command, no tools required

**Step 1.** Press `Win`, type `powershell`, right-click **Windows PowerShell** → **Run as administrator**

**Step 2.** Paste and run:

```
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/chrischip/magic-mouse-windows/main/Setup-MagicMouse.ps1 | iex
```

**Step 3.** Reboot when prompted, then pair your Magic Mouse via **Settings → Bluetooth**

That's it. No git, no Visual Studio, no extra downloads needed beforehand.
The script fetches everything (~700 MB from Apple's servers) and sets itself up.

---

## What the Script Does

0. Offers to create a **Windows System Restore Point** — strongly recommended
1. Downloads **7-Zip** (if not installed) — needed to unpack Apple's pkg/dmg format
2. Fetches the **Boot Camp ESD** (~700 MB) from Apple's software update servers
3. Extracts the `AppleWirelessMouse` driver (`INF` + `SYS` + `CAT`) and verifies the SHA256 hash of the download
4. Patches the INF to add **USB-C Magic Mouse** hardware IDs (not in Apple's 2019 original)
5. Generates a **self-signed code-signing certificate unique to your machine**
6. Rebuilds the driver catalog with correct file hashes, then signs it
7. Disables **HVCI (Memory Integrity)** if it is currently enabled
8. Enables **Windows test-signing mode**
9. Installs the certificate into the system trust stores
10. Stages the driver with `pnputil`
11. Offers to reboot

No Apple binaries are included in this repository. They are downloaded at
runtime directly from Apple's servers.

---

## ⚠️ Security Implications — Read Before Running

This script makes **permanent system-wide changes** that reduce your machine's
security posture. Understand each one before proceeding.

### 1. Test-Signing Mode

`bcdedit /set testsigning on` is set by the script and persists across reboots
until you explicitly turn it off.

**What it does:**
- Instructs the Windows kernel to load drivers signed by any certificate present
  in the `LocalMachine\TrustedPublisher` certificate store, regardless of
  whether that certificate chains to a Microsoft-trusted root.
- This is a **machine-wide, permanent policy change** — it is not scoped to
  this driver alone.

**What this means in practice:**
- Any driver signed with *any* certificate that you (or malware) later adds to
  `TrustedPublisher` will load into the kernel without further warning.
- The Windows desktop will display a **"Test Mode"** watermark in the
  bottom-right corner at all times as a visual reminder that the policy is
  active.
- It does not affect user-mode application security, Windows Defender, or
  network-level protections.
- It **does** weaken the kernel's driver loading gate — one of Windows'
  primary defences against rootkits.

**How to revert:**
```powershell
# Run as Administrator, then reboot
bcdedit /set testsigning off
```

---

### 2. HVCI / Memory Integrity is Disabled

If HVCI (Hypervisor-Protected Code Integrity) was enabled on your machine, the
script disables it. If it was already off (common on older hardware or machines
that were upgraded from Windows 10), this step has no effect.

**What HVCI does when enabled:**
- Runs the kernel's code-integrity checks inside a hardware-isolated hypervisor
  (VBS — Virtualization Based Security).
- Even if the kernel itself is compromised, the hypervisor can reject unsigned
  or maliciously modified kernel code before it executes.
- Protects against a class of attacks where malware patches kernel memory at
  runtime to bypass driver signature checks.

**What disabling it means:**
- The kernel's signature enforcement is still active, but it is no longer
  hardware-isolated — it is just a software check inside the kernel.
- A sufficiently privileged attacker (or a vulnerable driver) could patch
  kernel memory to bypass driver signature enforcement entirely.
- **Windows Defender Credential Guard** (which protects NTLM hashes and
  Kerberos tickets) may also be weakened or disabled, depending on your
  configuration.
- On modern hardware (roughly 2022+), HVCI is enabled by default because the
  performance cost is now negligible. Disabling it on such machines represents
  a meaningful reduction in protection.

**How to re-enable:**
Go to **Windows Security → Device Security → Core isolation → Memory Integrity**
and toggle it back on, then reboot.

Or via PowerShell (as Administrator):
```powershell
$key = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
Set-ItemProperty -Path $key -Name "Enabled" -Value 1 -Type DWord
# Then reboot
```

> **Note:** Re-enabling HVCI after installing this driver will cause the driver
> to stop loading, because test-signed drivers are blocked by HVCI regardless
> of test-signing mode. You cannot have both HVCI enabled and this driver
> loaded at the same time.

---

### 3. A Self-Signed Root Certificate is Added to Your System

The script generates a unique code-signing certificate for your machine and
adds it to two Windows certificate stores:

| Store | Purpose |
|---|---|
| `LocalMachine\Root` | Marks the certificate as a trusted root CA |
| `LocalMachine\TrustedPublisher` | Allows drivers signed by it to load in test mode |

**What this means:**
- The certificate is generated fresh on your machine and never leaves it — its
  private key is not shared, not distributed, and not in this repository.
- However, the certificate is added as a **trusted root CA**, which means
  Windows will trust *any* certificate it signs — not just driver certificates.
  This is an inherently broad grant of trust.
- If an attacker gains local Administrator access to your machine, they could
  use the private key to sign other software that Windows will trust.
- The private key is stored in the Windows machine certificate store
  (`LocalMachine\My`), accessible to any process running as SYSTEM or
  Administrator.

**How to remove the certificate:**
```powershell
$thumb = (Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match "MagicMouseDriver" }).Thumbprint
foreach ($store in @("My","Root","TrustedPublisher")) {
    Get-ChildItem "Cert:\LocalMachine\$store" |
        Where-Object { $_.Thumbprint -eq $thumb } |
        Remove-Item
}
```

---

### 4. Summary: Combined Risk Profile

| What you gain | What you give up |
|---|---|
| Functional Magic Mouse scroll, gestures, click | Kernel driver signing enforcement is software-only (no hypervisor) |
| Works without buying a third-party driver | Any cert in TrustedPublisher can load kernel drivers |
| No ongoing cost or subscription | A "Test Mode" watermark is permanently visible on the desktop |
| Reversible — see instructions above | HVCI/Credential Guard protections are reduced or disabled |

**This setup is reasonable for:**
- Personal machines where you control what software is installed
- Development or lab environments
- Machines that were already running without HVCI enabled

**This setup is NOT recommended for:**
- Corporate/managed machines (may violate policy; HVCI is often required)
- Machines storing sensitive credentials, secrets, or financial data where
  kernel-level isolation matters
- Machines exposed to untrusted software or users

---

## Uninstalling

To fully remove the driver and undo all system changes:

```powershell
# 1. Find the published driver name and remove it
pnputil /enum-drivers | Select-String "AppleWirelessMouse"
# Replace oem2.inf with the actual published name shown above:
pnputil /delete-driver oem2.inf /uninstall

# 2. Turn off test-signing mode (requires reboot)
bcdedit /set testsigning off

# 3. Re-enable HVCI (requires reboot)
$key = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
Set-ItemProperty -Path $key -Name "Enabled" -Value 1 -Type DWord

# 4. Remove the certificate from all stores
$thumb = (Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match "MagicMouseDriver" }).Thumbprint
foreach ($store in @("My","Root","TrustedPublisher")) {
    Get-ChildItem "Cert:\LocalMachine\$store" |
        Where-Object { $_.Thumbprint -eq $thumb } |
        Remove-Item -ErrorAction SilentlyContinue
}

# 5. Reboot
Restart-Computer
```

Alternatively, if you created a restore point when prompted by the script,
use **Settings → System → Recovery → Open System Restore** to roll back all
changes in one step.

---

## Legal Notice

This project contains only PowerShell scripts. No Apple-owned files are
included or distributed.

The Boot Camp driver package is downloaded at runtime directly from Apple's
software update servers (`swcdn.apple.com`). That software is Apple's
proprietary property and is subject to Apple's license terms. By running this
script you are responsible for ensuring your use of Apple's software complies
with those terms.

This project is not affiliated with, endorsed by, or sponsored by Apple Inc.
Apple, Magic Mouse, and Boot Camp are trademarks of Apple Inc.

---

## How It Works

The Apple Magic Mouse communicates over Bluetooth HID. Without the Apple
driver, Windows loads its generic HID mouse driver — which works for basic
clicking and movement but loses scroll wheel emulation and gesture support.

Apple's Boot Camp driver (`AppleWirelessMouse.sys`) is a **kernel-mode HID
lower filter driver**. It sits below the standard HID stack and translates the
Magic Mouse's raw touch sensor data into standard scroll and pointer events
Windows understands.

The driver binary is compiled and signed by Apple. This script:
1. Rebuilds the **catalog file** (`.cat`) from the current driver files using `New-FileCatalog` — necessary because we patch the INF to add USB-C hardware IDs, which changes its hash
2. Signs the new catalog with a locally generated certificate
3. Leaves the `.sys` binary untouched — Apple's original binary is preserved; its integrity is guaranteed by its hash in the catalog

---

## Testing / Development

`Test-MagicMouseDriver.ps1` verifies the driver installation without needing
a physical Magic Mouse. It requires `devcon.exe` from the Windows Driver Kit:

```powershell
winget install Microsoft.WindowsWDK.10.0.26100
```

**Run as Administrator after running Setup-MagicMouse.ps1:**
```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Test-MagicMouseDriver.ps1
```

**What is tested:**

| # | Test | What it checks |
|---|---|---|
| 1 | Tools present | `devcon.exe` and `signtool.exe` are available |
| 2 | Driver staged | Driver package is in the Windows driver store |
| 3 | Signature valid | `.cat` passes `signtool verify /pa` |
| 4 | INF validation | Hardware IDs (MM1, MM2, USB-C), service type, binary reference |
| 5 | Driver store coverage | Staged package covers Apple Wireless Mouse hardware IDs |
| 6 | Hardware binding | Device status OK (skipped automatically if no mouse is paired) |

The script exits with code `0` on full pass, or the number of failures —
suitable for use in CI pipelines.

---

## License

MIT — see [LICENSE](LICENSE).

The scripts in this repository are MIT licensed. Apple's Boot Camp drivers,
downloaded separately at runtime, are not covered by this license.
