# Restore guide

WindowsReclaim creates a restore manifest for every `-Apply` run. The manifest contains:

- Removed Appx package names and local Appx manifest paths when available
- Removed provisioned Appx package names
- Previous service startup modes
- Previous scheduled task states
- Registry value snapshots for changed values
- Optional feature state snapshots

## Restore apps locally

```powershell
.\WindowsReclaim.ps1 -RestoreApps -Apply
```

This uses the newest manifest in:

```text
C:\ProgramData\WindowsReclaim\Backups
```

## Restore apps from a specific manifest

```powershell
.\WindowsReclaim.ps1 -RestoreApps -Apply -RestoreManifest "C:\ProgramData\WindowsReclaim\Backups\WindowsReclaim_YYYYMMDD_HHMMSS.json"
```

## Restore with winget fallback

Use this if local Appx payloads are gone:

```powershell
.\WindowsReclaim.ps1 -RestoreApps -Apply -UseWingetFallback -AcceptWingetAgreements
```

## Reinstall specific apps

```powershell
.\WindowsReclaim.ps1 -InstallApps Calculator,Photos,Notepad,Store -Apply -UseWingetFallback -AcceptWingetAgreements
```

## Restore services and tasks

```powershell
.\WindowsReclaim.ps1 -RestoreServices -RestoreTasks -Apply -RestoreManifest "C:\ProgramData\WindowsReclaim\Backups\WindowsReclaim_YYYYMMDD_HHMMSS.json"
```

## Why some apps cannot be restored fully offline

PowerShell can register an Appx/MSIX package from an existing local `AppxManifest.xml`. If the actual package payload has been deleted from disk, Windows needs another package source such as Microsoft Store, winget, an original MSIX/Appx package, or a Windows image source.

For future-user provisioning, Windows may need the original package and license files. Re-registering a local manifest can restore an app for the current system/user, but it does not always recreate the original provisioned app state for every new user.
