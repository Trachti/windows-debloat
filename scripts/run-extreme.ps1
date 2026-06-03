# Example runner for a very aggressive local-only cleanup.
# Review README.md before running this profile.
# Open PowerShell as Administrator from the repository root and run:
# .\scripts\run-extreme.ps1

Set-ExecutionPolicy -Scope Process Bypass -Force
& "$PSScriptRoot\..\WindowsReclaim.ps1" -Apply -Profile Extreme -RemoveOneDrive -RemoveCopilot -RemoveWidgets -DisableSearchIndexing -DisablePrintSpooler -DisableHibernation -DisableLegacyFeatures -CleanDisk -CleanComponentStore
