# Example runner for a practical balanced cleanup.
# Open PowerShell as Administrator from the repository root and run:
# .\scripts\run-balanced.ps1

Set-ExecutionPolicy -Scope Process Bypass -Force
& "$PSScriptRoot\..\WindowsDebloat.ps1" -Apply -Profile Balanced -RemoveOneDrive -RemoveCopilot -CleanDisk
