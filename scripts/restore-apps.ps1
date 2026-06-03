# Example restore runner. Uses the newest manifest automatically.
# Add -UseWingetFallback when local Appx payloads are gone and online restore is acceptable.

Set-ExecutionPolicy -Scope Process Bypass -Force
& "$PSScriptRoot\..\WindowsReclaim.ps1" -RestoreApps -RestoreServices -RestoreTasks -Apply
