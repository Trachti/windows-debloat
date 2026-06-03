# WindowsDebloat

WindowsDebloat is an English, GitHub-ready PowerShell debloat and resource-reclaim script for:

- Windows 11
- Windows Server 2022
- Windows Server 2025

It removes consumer/bloat Appx packages, disables selected background services, turns off selected telemetry and compatibility scheduled tasks, applies local-first/privacy policies, and can clean temp files, Windows Update downloads, and the component store.

The script is **dry-run by default**. It does not change anything unless you pass `-Apply`.

## Safety design

WindowsDebloat is more aggressive than a basic debloat script, but it intentionally avoids disabling critical security, update, networking, domain, remote management, and server role services such as:

- Microsoft Defender and Windows Security services
- Windows Firewall / Base Filtering Engine
- Windows Update, BITS, Cryptographic Services, Update Orchestrator
- DNS Client, DHCP Client, Network Location Awareness, core RPC/Event Log services
- WinRM and RDP base services
- Domain Controller related services such as Netlogon, NTDS, KDC and DNS
- Hyper-V host services

For maximum safety, run it first in a VM or on a test machine.

## Quick start

Open PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\WindowsDebloat.ps1
```

The first run is a dry-run preview. To apply the recommended balanced cleanup:

```powershell
.\WindowsDebloat.ps1 -Apply -Profile Balanced -RemoveOneDrive -RemoveCopilot -CleanDisk
```

For a much stronger cleanup on a local-only workstation or minimal server:

```powershell
.\WindowsDebloat.ps1 -Apply -Profile Extreme -RemoveOneDrive -RemoveCopilot -RemoveWidgets -DisableSearchIndexing -DisablePrintSpooler -DisableHibernation -DisableLegacyFeatures -CleanDisk -CleanComponentStore
```

## Profiles

### Safe

Removes common consumer apps and disables low-risk telemetry/demo/background components.

### Balanced

Recommended default. Includes Safe plus Xbox, Teams consumer components, Phone Link, old media sharing, mixed reality, Office hub style apps, consumer sync services, and more suggestion/privacy cleanup.

### Extreme

For minimal local systems. Includes Balanced plus more apps, search indexing, SysMain, hibernation, optional legacy features, print workflow, Bluetooth user services and convenience components. Use this only when you know the system does not need those features.

## App restore and reinstall

Every `-Apply` debloat run writes a JSON restore manifest under:

```text
C:\ProgramData\WindowsDebloat\Backups
```

To restore apps from the latest manifest using local Appx package payloads:

```powershell
.\WindowsDebloat.ps1 -RestoreApps -Apply
```

To restore from a specific manifest:

```powershell
.\WindowsDebloat.ps1 -RestoreApps -Apply -RestoreManifest "C:\ProgramData\WindowsDebloat\Backups\WindowsDebloat_YYYYMMDD_HHMMSS.json"
```

If the local Appx payload is no longer present, WindowsDebloat can optionally use winget:

```powershell
.\WindowsDebloat.ps1 -RestoreApps -Apply -UseWingetFallback -AcceptWingetAgreements
```

Install specific known apps again:

```powershell
.\WindowsDebloat.ps1 -InstallApps Calculator,Photos,Notepad,Store -Apply -UseWingetFallback -AcceptWingetAgreements
```

Known app keys currently include:

`Calculator`, `Camera`, `Clipchamp`, `HEIF`, `MediaPlayer`, `Notepad`, `OneDrive`, `Outlook`, `Paint`, `Photos`, `PowerAutomate`, `QuickAssist`, `SnippingTool`, `StickyNotes`, `Store`, `Teams`, `Terminal`, `ToDo`, `VP9`, `WebP`, `Xbox`.

### Important restore limitation

Local restore works only when the Appx/MSIX payload still exists on disk, usually under `C:\Program Files\WindowsApps`. If a package has been fully removed, Windows may need Microsoft Store, winget, an original MSIX/Appx package, or a Windows image source to restore it. This is a Windows packaging limitation, not a script limitation.

## Restore service and scheduled-task changes

Restore service startup types from a manifest:

```powershell
.\WindowsDebloat.ps1 -RestoreServices -Apply -RestoreManifest "C:\ProgramData\WindowsDebloat\Backups\WindowsDebloat_YYYYMMDD_HHMMSS.json"
```

Restore scheduled tasks from a manifest:

```powershell
.\WindowsDebloat.ps1 -RestoreTasks -Apply -RestoreManifest "C:\ProgramData\WindowsDebloat\Backups\WindowsDebloat_YYYYMMDD_HHMMSS.json"
```

Restore apps, services and tasks together:

```powershell
.\WindowsDebloat.ps1 -RestoreApps -RestoreServices -RestoreTasks -Apply -UseWingetFallback -AcceptWingetAgreements
```

## Useful options

| Option | Description |
|---|---|
| `-Apply` | Actually make changes. Without this, the script is dry-run only. |
| `-Profile Safe\|Balanced\|Extreme` | Select cleanup intensity. Default is `Balanced`. |
| `-RemoveOneDrive` | Uninstall OneDrive and apply OneDrive block policies. |
| `-RemoveCopilot` | Disable Copilot policies and remove known Copilot package patterns where present. |
| `-RemoveWidgets` | Disable Widgets policies and remove WebExperience package where present. |
| `-RemoveStore` | Remove Microsoft Store package. Not recommended unless you accept harder restore. |
| `-DisablePrintSpooler` | Disable printing. Useful for servers that never print. |
| `-DisableSearchIndexing` | Disable Windows Search indexing. |
| `-DisableBluetooth` | Disable Bluetooth services. |
| `-DisableHibernation` | Run `powercfg /hibernate off` to remove hiberfil.sys. |
| `-DisableLegacyFeatures` | Disable legacy optional Windows features such as SMB1, XPS, Work Folders and Windows Media Player where present. |
| `-CleanDisk` | Clean temp, WER, prefetch and Windows Update download cache. |
| `-CleanComponentStore` | Run DISM component store cleanup. |
| `-ResetComponentBase` | Adds DISM `/ResetBase`. Saves more disk space but prevents uninstalling already-installed Windows updates. |
| `-CreateRestorePoint` | Create a System Restore point before applying changes. Usually not available on Server by default. |
| `-UseWingetFallback` | Allow winget restore/install if local Appx registration is not possible. |
| `-AcceptWingetAgreements` | Pass winget package/source agreement flags. |

## What it does not do

WindowsDebloat does **not** disable Defender, Firewall, Windows Update, core networking, RDP, WinRM, Domain Controller services, Hyper-V services, or other critical platform components. It also does not use unofficial Appx download sites.

## Logs and manifests

Logs:

```text
C:\ProgramData\WindowsDebloat\Logs
```

Restore manifests:

```text
C:\ProgramData\WindowsDebloat\Backups
```

Keep the manifest if you want the easiest rollback path.

## Recommended GitHub structure

```text
Windows-Debloat/
├─ WindowsDebloat.ps1
├─ README.md
├─ LICENSE
├─ CHANGELOG.md
├─ docs/
│  └─ restore.md
└─ .gitignore
```

## Disclaimer

Use at your own risk. Test before deploying widely. Server roles, line-of-business apps, VDI images, kiosk systems and domain-joined endpoints can depend on components that look unnecessary on a standalone workstation.
