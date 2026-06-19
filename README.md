# Apple Magic Mouse Driver for Windows

Installs Apple's Magic Mouse driver on Windows by fetching it directly from
Apple's Boot Camp CDN, signing it with a machine-generated certificate, and
configuring the system to load it.

---

## Quick Start

No git, no pre-installed tools required. Open PowerShell **as Administrator**
and paste this single command:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/chrischip/magic-mouse-windows/main/Setup-MagicMouse.ps1 | iex
```

> **How to open an elevated PowerShell:**
> Press `Win`, type `powershell`, right-click **Windows PowerShell** →
> **Run as administrator**, then paste the command above.

The script will download everything it needs (~700 MB from Apple's servers),
sign the driver with a certificate it generates for your machine, configure
Windows, and ask whether to reboot.

After rebooting:
1. Pair your Magic Mouse via **Settings → Bluetooth → Add device**
2. It should appear as **Apple Wireless Mouse** in Device Manager under
   *Mice and other pointing devices*

---

## What the Script Does

1. Downloads **7-Zip** (if not installed) — needed to unpack Apple's pkg/dmg format
2. Fetches the **Boot Camp ESD** (~700 MB) from Apple's software update servers
3. Extracts the `AppleWirelessMouse` driver (`INF` + `SYS` + `CAT`)
4. Generates a **self-signed code-signing certificate unique to your machine**
5. Signs the driver package with that certificate
6. Disables **HVCI (Memory Integrity)** if it is currently enabled
7. Enables **Windows test-signing mode**
8. Installs the certificate into the system trust stores
9. Stages the driver with `pnputil`
10. Offers to reboot

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
# Find and remove from all three stores
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
# 1. Remove the driver from the Windows driver store
#    (find the published name first)
pnputil /enum-drivers | Select-String -A5 "AppleWirelessMouse"
# Then delete it (replace oem2.inf with the actual published name):
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

The driver binary is compiled and signed by Apple. This script re-signs the
**catalog file** (which is the trust anchor Windows checks) with a locally
generated certificate, without modifying the driver binary itself.

---

## License

MIT — see [LICENSE](LICENSE).

The scripts in this repository are MIT licensed. Apple's Boot Camp drivers,
downloaded separately at runtime, are not covered by this license.
