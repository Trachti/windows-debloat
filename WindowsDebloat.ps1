#requires -version 5.1
#requires -RunAsAdministrator
<#!
.SYNOPSIS
  Reclaim resources on Windows 11, Windows Server 2022, and Windows Server 2025.

.DESCRIPTION
  WindowsDebloat removes consumer Appx packages, disables selected background services,
  disables selected telemetry and compatibility scheduled tasks, applies privacy and
  consumer-feature policies, and can clean temporary/component-store files.

  The script is intentionally reversible where Windows allows it:
  - Every apply run creates a JSON manifest under ProgramData.
  - App restore first tries local Appx registration from the saved manifest.
  - If the local payload is gone, it can optionally use winget as a fallback.
  - Service and scheduled-task startup/state changes can be restored from the manifest.

  Default behavior is dry-run only. Pass -Apply to change the system.

.EXAMPLE
  .\WindowsDebloat.ps1
  Shows the Balanced plan without making changes.

.EXAMPLE
  .\WindowsDebloat.ps1 -Apply -Profile Balanced -RemoveOneDrive -RemoveCopilot -CleanDisk
  Applies the recommended cleanup profile.

.EXAMPLE
  .\WindowsDebloat.ps1 -Apply -Profile Extreme -RemoveOneDrive -RemoveCopilot -RemoveWidgets -DisableSearchIndexing -DisablePrintSpooler -DisableHibernation -CleanDisk -CleanComponentStore
  Applies a much more aggressive local-first workstation/server cleanup.

.EXAMPLE
  .\WindowsDebloat.ps1 -RestoreApps -Apply -RestoreManifest "C:\ProgramData\WindowsDebloat\Backups\WindowsDebloat_20260603_123000.json"
  Restores removed apps where local Appx payloads are still present.

.EXAMPLE
  .\WindowsDebloat.ps1 -InstallApps Calculator,Photos,Notepad -Apply -UseWingetFallback -AcceptWingetAgreements
  Reinstalls selected known apps using local registration first and winget if needed.
#>

[CmdletBinding(DefaultParameterSetName = 'Debloat')]
param(
    [Parameter(ParameterSetName = 'Debloat')]
    [ValidateSet('Safe', 'Balanced', 'Extreme')]
    [string]$Profile = 'Balanced',

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$RemoveOneDrive,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$RemoveCopilot,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$RemoveWidgets,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$RemoveStore,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$DisablePrintSpooler,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$DisableSearchIndexing,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$DisableBluetooth,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$DisableHibernation,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$DisableLegacyFeatures,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$CleanDisk,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$CleanComponentStore,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$ResetComponentBase,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$CreateRestorePoint,

    [Parameter(ParameterSetName = 'Debloat')]
    [switch]$ForceUnsupportedOS,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$RestoreApps,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$RestoreServices,

    [Parameter(ParameterSetName = 'Restore')]
    [switch]$RestoreTasks,

    [Parameter(ParameterSetName = 'Install')]
    [string[]]$InstallApps,

    [Parameter(ParameterSetName = 'Restore')]
    [Parameter(ParameterSetName = 'Install')]
    [string]$RestoreManifest,

    [Parameter(ParameterSetName = 'Restore')]
    [Parameter(ParameterSetName = 'Install')]
    [switch]$UseWingetFallback,

    [Parameter(ParameterSetName = 'Restore')]
    [Parameter(ParameterSetName = 'Install')]
    [switch]$AcceptWingetAgreements,

    [Parameter(ParameterSetName = 'Debloat')]
    [Parameter(ParameterSetName = 'Restore')]
    [Parameter(ParameterSetName = 'Install')]
    [switch]$Apply,

    [Parameter(ParameterSetName = 'Debloat')]
    [Parameter(ParameterSetName = 'Restore')]
    [Parameter(ParameterSetName = 'Install')]
    [string]$LogRoot = "$env:ProgramData\WindowsDebloat"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$script:IsDryRun = -not $Apply
$script:StartedAt = Get-Date
$script:RunStamp = $script:StartedAt.ToString('yyyyMMdd_HHmmss')
$script:BackupDir = Join-Path $LogRoot 'Backups'
$script:LogDir = Join-Path $LogRoot 'Logs'
$script:ManifestPath = Join-Path $script:BackupDir ("WindowsDebloat_{0}.json" -f $script:RunStamp)
$script:TranscriptPath = Join-Path $script:LogDir ("WindowsDebloat_{0}.log" -f $script:RunStamp)
$script:ActionCount = 0
$script:WarningCount = 0

$KnownRestoreApps = @{
    'Calculator'     = @{ Appx = @('Microsoft.WindowsCalculator'); WingetId = '9WZDNCRFHVN5'; Source = 'msstore' }
    'Camera'         = @{ Appx = @('Microsoft.WindowsCamera'); WingetId = '9WZDNCRFJBBG'; Source = 'msstore' }
    'Clipchamp'      = @{ Appx = @('Clipchamp.Clipchamp'); WingetId = '9P1J8S7CCWWT'; Source = 'msstore' }
    'HEIF'           = @{ Appx = @('Microsoft.HEIFImageExtension'); WingetId = '9PMMSR1CGPWG'; Source = 'msstore' }
    'MediaPlayer'    = @{ Appx = @('Microsoft.ZuneMusic'); WingetId = '9WZDNCRFJ3PT'; Source = 'msstore' }
    'Notepad'        = @{ Appx = @('Microsoft.WindowsNotepad'); WingetId = '9MSMLRH6LZF3'; Source = 'msstore' }
    'OneDrive'       = @{ Appx = @(); WingetId = 'Microsoft.OneDrive'; Source = 'winget' }
    'Outlook'        = @{ Appx = @('Microsoft.OutlookForWindows'); WingetId = '9NRX63209R7B'; Source = 'msstore' }
    'Paint'          = @{ Appx = @('Microsoft.Paint', 'Microsoft.MSPaint'); WingetId = '9PCFS5B6T72H'; Source = 'msstore' }
    'Photos'         = @{ Appx = @('Microsoft.Windows.Photos'); WingetId = '9WZDNCRFJBH4'; Source = 'msstore' }
    'PowerAutomate'  = @{ Appx = @('Microsoft.PowerAutomateDesktop'); WingetId = '9NFTCH6J7FHV'; Source = 'msstore' }
    'QuickAssist'    = @{ Appx = @('MicrosoftCorporationII.QuickAssist'); WingetId = '9P7BP5VNWKX5'; Source = 'msstore' }
    'SnippingTool'   = @{ Appx = @('Microsoft.ScreenSketch'); WingetId = '9MZ95KL8MR0L'; Source = 'msstore' }
    'StickyNotes'    = @{ Appx = @('Microsoft.MicrosoftStickyNotes'); WingetId = '9NBLGGH4QGHW'; Source = 'msstore' }
    'Store'          = @{ Appx = @('Microsoft.WindowsStore'); WingetId = '9WZDNCRFJBMP'; Source = 'msstore' }
    'Teams'          = @{ Appx = @('MSTeams', 'MicrosoftTeams'); WingetId = 'Microsoft.Teams'; Source = 'winget' }
    'Terminal'       = @{ Appx = @('Microsoft.WindowsTerminal'); WingetId = 'Microsoft.WindowsTerminal'; Source = 'winget' }
    'ToDo'           = @{ Appx = @('Microsoft.Todos'); WingetId = '9NBLGGH5R558'; Source = 'msstore' }
    'VP9'            = @{ Appx = @('Microsoft.VP9VideoExtensions'); WingetId = '9N4D0MSMP0PT'; Source = 'msstore' }
    'WebP'           = @{ Appx = @('Microsoft.WebpImageExtension'); WingetId = '9PG2DK419DRG'; Source = 'msstore' }
    'Xbox'           = @{ Appx = @('Microsoft.GamingApp', 'Microsoft.XboxApp'); WingetId = '9MV0B5HZVK9Z'; Source = 'msstore' }
}

$NeverDisableServices = @(
    'AppIDSvc', 'Appinfo', 'AudioEndpointBuilder', 'Audiosrv', 'BFE', 'BITS', 'BrokerInfrastructure',
    'CertPropSvc', 'COMSysApp', 'CoreMessagingRegistrar', 'CryptSvc', 'DcomLaunch', 'Dhcp', 'Dnscache',
    'DNS', 'DPS', 'EventLog', 'EventSystem', 'gpsvc', 'iphlpsvc', 'KDC', 'LanmanServer', 'LanmanWorkstation',
    'LicenseManager', 'LSM', 'mpssvc', 'MpsSvc', 'Netlogon', 'Netman', 'netprofm', 'NlaSvc', 'nsi', 'NTDS',
    'PlugPlay', 'Power', 'ProfSvc', 'RpcEptMapper', 'RpcSs', 'SamSs', 'Schedule', 'SecurityHealthService',
    'SENS', 'SessionEnv', 'ShellHWDetection', 'sppsvc', 'SystemEventsBroker', 'TermService', 'Themes',
    'TimeBrokerSvc', 'TokenBroker', 'TrustedInstaller', 'UmRdpService', 'UsoSvc', 'VMAuthdService', 'vmcompute',
    'vmms', 'W32Time', 'Wcmsvc', 'WdNisSvc', 'WinDefend', 'Winmgmt', 'WinRM', 'WlanSvc', 'wlidsvc', 'WpnService',
    'wscsvc', 'wuauserv'
)

$SafeAppxPatterns = @(
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.People',
    'Microsoft.SkypeApp',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.ZuneVideo'
)

$BalancedAppxPatterns = @(
    'Clipchamp.Clipchamp',
    'Microsoft.3DBuilder',
    'Microsoft.549981C3F5F10',
    'Microsoft.BingFoodAndDrink',
    'Microsoft.BingHealthAndFitness',
    'Microsoft.BingSports',
    'Microsoft.BingTravel',
    'Microsoft.CommsPhone',
    'Microsoft.GamingApp',
    'Microsoft.MixedReality.Portal',
    'Microsoft.Office.OneNote',
    'Microsoft.OneConnect',
    'Microsoft.OutlookForWindows',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos',
    'Microsoft.Wallet',
    'Microsoft.WindowsCommunicationsApps',
    'Microsoft.Xbox*',
    'Microsoft.YourPhone',
    'MicrosoftTeams',
    'MSTeams'
)

$ExtremeAppxPatterns = @(
    'Microsoft.BingSearch',
    'Microsoft.Copilot',
    'Microsoft.MicrosoftStickyNotes',
    'Microsoft.ScreenSketch',
    'Microsoft.Windows.Photos',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsCamera',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.ZuneMusic',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist'
)

$SafeServices = @(
    @{ Name = 'DiagTrack'; Reason = 'Connected User Experiences and Telemetry' },
    @{ Name = 'dmwappushservice'; Reason = 'WAP push telemetry routing' },
    @{ Name = 'MapsBroker'; Reason = 'Downloaded Maps Manager' },
    @{ Name = 'RetailDemo'; Reason = 'Retail demo mode' },
    @{ Name = 'RemoteRegistry'; Reason = 'Remote registry access' },
    @{ Name = 'WerSvc'; Reason = 'Windows Error Reporting background uploads' },
    @{ Name = 'wisvc'; Reason = 'Windows Insider Service' }
)

$BalancedServices = @(
    @{ Name = 'Fax'; Reason = 'Fax service' },
    @{ Name = 'WalletService'; Reason = 'Wallet background service' },
    @{ Name = 'PhoneSvc'; Reason = 'Phone link service' },
    @{ Name = 'MixedRealityOpenXRSvc'; Reason = 'Mixed Reality OpenXR service' },
    @{ Name = 'WMPNetworkSvc'; Reason = 'Windows Media Player sharing' },
    @{ Name = 'XblAuthManager'; Reason = 'Xbox Live authentication' },
    @{ Name = 'XblGameSave'; Reason = 'Xbox game save sync' },
    @{ Name = 'XboxGipSvc'; Reason = 'Xbox accessory service' },
    @{ Name = 'XboxNetApiSvc'; Reason = 'Xbox networking service' },
    @{ Name = 'PcaSvc'; Reason = 'Program Compatibility Assistant' }
)

$ExtremeServices = @(
    @{ Name = 'SysMain'; Reason = 'SysMain prefetch/superfetch' },
    @{ Name = 'TabletInputService'; Reason = 'Touch keyboard and handwriting' },
    @{ Name = 'lfsvc'; Reason = 'Geolocation service' },
    @{ Name = 'WbioSrvc'; Reason = 'Windows biometric service' },
    @{ Name = 'icssvc'; Reason = 'Mobile hotspot service' },
    @{ Name = 'SEMgrSvc'; Reason = 'Payments and NFC secure elements' }
)

$PerUserServicePatternsBalanced = @(
    @{ Pattern = 'CDPUserSvc_*'; Reason = 'Connected Devices Platform per-user sync' },
    @{ Pattern = 'OneSyncSvc_*'; Reason = 'Mail, calendar and contact sync' },
    @{ Pattern = 'PimIndexMaintenanceSvc_*'; Reason = 'Contact data indexing' },
    @{ Pattern = 'UnistoreSvc_*'; Reason = 'User data storage service' },
    @{ Pattern = 'UserDataSvc_*'; Reason = 'User data access service' }
)

$PerUserServicePatternsExtreme = @(
    @{ Pattern = 'MessagingService_*'; Reason = 'Messaging per-user service' },
    @{ Pattern = 'BluetoothUserService_*'; Reason = 'Bluetooth per-user service' },
    @{ Pattern = 'PrintWorkflowUserSvc_*'; Reason = 'Print workflow per-user service' },
    @{ Pattern = 'WpnUserService_*'; Reason = 'Push notification per-user service' }
)

$ScheduledTasks = @(
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' },
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'ProgramDataUpdater' },
    @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'StartupAppTask' },
    @{ Path = '\Microsoft\Windows\Autochk\'; Name = 'Proxy' },
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' },
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'KernelCeipTask' },
    @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' },
    @{ Path = '\Microsoft\Windows\DiskDiagnostic\'; Name = 'Microsoft-Windows-DiskDiagnosticDataCollector' },
    @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClient' },
    @{ Path = '\Microsoft\Windows\Feedback\Siuf\'; Name = 'DmClientOnScenarioDownload' },
    @{ Path = '\Microsoft\Windows\Maps\'; Name = 'MapsToastTask' },
    @{ Path = '\Microsoft\Windows\Maps\'; Name = 'MapsUpdateTask' },
    @{ Path = '\Microsoft\Windows\Windows Error Reporting\'; Name = 'QueueReporting' }
)

$ExtremeScheduledTasks = @(
    @{ Path = '\Microsoft\Windows\CloudExperienceHost\'; Name = 'CreateObjectTask' },
    @{ Path = '\Microsoft\Windows\UpdateOrchestrator\'; Name = 'USO_UxBroker' }
)

$LegacyOptionalFeatures = @(
    'SMB1Protocol',
    'WorkFolders-Client',
    'WindowsMediaPlayer',
    'Printing-XPSServices-Features',
    'Printing-Foundation-InternetPrinting-Client'
)

$script:Manifest = [ordered]@{
    SchemaVersion = '1.1'
    Tool = 'WindowsDebloat'
    CreatedAt = $script:StartedAt.ToString('o')
    ComputerName = $env:COMPUTERNAME
    UserName = [Environment]::UserName
    Apply = [bool]$Apply
    Profile = $Profile
    Os = $null
    RemovedAppx = @()
    RemovedProvisionedAppx = @()
    ServiceChanges = @()
    ScheduledTaskChanges = @()
    RegistryChanges = @()
    OptionalFeatureChanges = @()
    Notes = @()
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Cyan
}

function Write-DryRun {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[DRY-RUN] $Text" -ForegroundColor Yellow
}

function Write-Changed {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[OK] $Text" -ForegroundColor Green
}

function Write-Skip {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[SKIP] $Text" -ForegroundColor DarkGray
}

function Write-ReclaimWarning {
    param([Parameter(Mandatory)][string]$Text)
    $script:WarningCount++
    Write-Warning $Text
}

function Invoke-ReclaimAction {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    $script:ActionCount++
    if ($script:IsDryRun) {
        Write-DryRun $Description
        return
    }

    Write-Info $Description
    try {
        & $Action
        Write-Changed $Description
    }
    catch {
        Write-ReclaimWarning ("Failed: {0} :: {1}" -f $Description, $_.Exception.Message)
    }
}

function Ensure-Directories {
    foreach ($path in @($LogRoot, $script:BackupDir, $script:LogDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }
}

function Start-Logging {
    if ($script:IsDryRun) { return }
    Ensure-Directories
    try {
        Start-Transcript -Path $script:TranscriptPath -Force | Out-Null
    }
    catch {
        Write-ReclaimWarning ("Could not start transcript: {0}" -f $_.Exception.Message)
    }
}

function Stop-Logging {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
        # Transcript may not have started. Ignore.
    }
}

function Get-OsInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $build = [int]$os.BuildNumber
    $isServer = ($os.ProductType -ne 1)
    $supported = $false
    $family = 'Unknown'

    if (-not $isServer -and $build -ge 22000) {
        $supported = $true
        $family = 'Windows 11'
    }
    elseif ($isServer -and $build -eq 20348) {
        $supported = $true
        $family = 'Windows Server 2022'
    }
    elseif ($isServer -and $build -ge 26100) {
        $supported = $true
        $family = 'Windows Server 2025'
    }

    [pscustomobject]@{
        Caption = $os.Caption
        Version = $os.Version
        BuildNumber = $build
        ProductType = $os.ProductType
        IsServer = $isServer
        Family = $family
        Supported = $supported
    }
}

function Assert-SupportedOS {
    $info = Get-OsInfo
    $script:Manifest['Os'] = $info
    Write-Info ("Detected OS: {0} / Version {1} / Build {2}" -f $info.Caption, $info.Version, $info.BuildNumber)

    if (-not $info.Supported -and -not $ForceUnsupportedOS) {
        throw "Unsupported OS detected. This script targets Windows 11, Windows Server 2022, and Windows Server 2025. Use -ForceUnsupportedOS if you know what you are doing."
    }
}

function Add-ManifestNote {
    param([string]$Text)
    $script:Manifest['Notes'] += $Text
}

function Export-Manifest {
    if ($script:IsDryRun) {
        Write-Info "Dry-run mode: manifest was not written. Pass -Apply to save a restore manifest."
        return
    }

    $script:Manifest['CompletedAt'] = (Get-Date).ToString('o')
    $script:Manifest['ActionCount'] = $script:ActionCount
    $script:Manifest['WarningCount'] = $script:WarningCount

    try {
        $json = $script:Manifest | ConvertTo-Json -Depth 12
        Set-Content -Path $script:ManifestPath -Value $json -Encoding UTF8 -Force
        Write-Changed "Restore manifest saved: $script:ManifestPath"
    }
    catch {
        Write-ReclaimWarning ("Could not write manifest: {0}" -f $_.Exception.Message)
    }
}

function Get-LatestManifestPath {
    if (-not [string]::IsNullOrWhiteSpace($RestoreManifest)) {
        return $RestoreManifest
    }

    if (-not (Test-Path -LiteralPath $script:BackupDir)) {
        return $null
    }

    $latest = Get-ChildItem -Path $script:BackupDir -Filter 'WindowsDebloat_*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $latest) {
        return $null
    }

    return $latest.FullName
}

function Import-Manifest {
    $path = Get-LatestManifestPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw 'No restore manifest was provided and no previous manifest was found.'
    }
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Restore manifest not found: $path"
    }

    Write-Info "Using restore manifest: $path"
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Test-ProtectedServiceName {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($protected in $NeverDisableServices) {
        if ($Name -like $protected) {
            return $true
        }
    }
    return $false
}

function Get-ServiceStartMode {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction Stop
        if ($null -ne $svc) { return $svc.StartMode }
    }
    catch {
        return $null
    }
    return $null
}

function Convert-StartModeToStartupType {
    param([string]$StartMode)
    switch ($StartMode) {
        'Auto' { return 'Automatic' }
        'Manual' { return 'Manual' }
        'Disabled' { return 'Disabled' }
        default { return 'Manual' }
    }
}

function Disable-ServiceSafe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Reason = ''
    )

    if (Test-ProtectedServiceName -Name $Name) {
        Write-Skip "Protected service: $Name"
        return
    }

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Skip "Service not found: $Name"
        return
    }

    $startMode = Get-ServiceStartMode -Name $Name
    $entry = [ordered]@{
        Name = $Name
        DisplayName = $svc.DisplayName
        PreviousStatus = $svc.Status.ToString()
        PreviousStartMode = $startMode
        NewStartMode = 'Disabled'
        Reason = $Reason
    }
    $script:Manifest['ServiceChanges'] += $entry

    $label = if ([string]::IsNullOrWhiteSpace($Reason)) { $Name } else { "$Name - $Reason" }
    Invoke-ReclaimAction "Stop and disable service: $label" {
        $current = Get-Service -Name $Name -ErrorAction Stop
        if ($current.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $Name -Force -ErrorAction Stop
            }
            catch {
                Write-ReclaimWarning ("Could not stop service {0}: {1}" -f $Name, $_.Exception.Message)
            }
        }

        try {
            Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
        }
        catch {
            & sc.exe config $Name start= disabled | Out-Null
        }
    }
}

function Disable-ServicePatternSafe {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [string]$Reason = ''
    )

    $services = @(Get-Service -Name $Pattern -ErrorAction SilentlyContinue)
    if ($services.Count -eq 0) {
        Write-Skip "Service pattern not found: $Pattern"
        return
    }

    foreach ($svc in $services) {
        Disable-ServiceSafe -Name $svc.Name -Reason $Reason
    }
}

function Restore-ServicesFromManifest {
    param([Parameter(Mandatory)]$Manifest)

    $items = @($Manifest.ServiceChanges)
    if ($items.Count -eq 0) {
        Write-Skip 'No service changes found in manifest.'
        return
    }

    foreach ($item in $items) {
        $name = [string]$item.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $startup = Convert-StartModeToStartupType -StartMode ([string]$item.PreviousStartMode)
        Invoke-ReclaimAction "Restore service startup type: $name -> $startup" {
            try {
                Set-Service -Name $name -StartupType $startup -ErrorAction Stop
            }
            catch {
                $scMode = switch ($startup) {
                    'Automatic' { 'auto' }
                    'Manual' { 'demand' }
                    'Disabled' { 'disabled' }
                    default { 'demand' }
                }
                & sc.exe config $name start= $scMode | Out-Null
            }
        }
    }
}

function Get-ScheduledTaskStateSafe {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName
    )

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
        return $task.State.ToString()
    }
    catch {
        return $null
    }
}

function Disable-ScheduledTaskSafe {
    param(
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$TaskName
    )

    $state = Get-ScheduledTaskStateSafe -TaskPath $TaskPath -TaskName $TaskName
    if ($null -eq $state) {
        Write-Skip "Scheduled task not found: $TaskPath$TaskName"
        return
    }

    $script:Manifest['ScheduledTaskChanges'] += [ordered]@{
        TaskPath = $TaskPath
        TaskName = $TaskName
        PreviousState = $state
        NewState = 'Disabled'
    }

    Invoke-ReclaimAction "Disable scheduled task: $TaskPath$TaskName" {
        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
    }
}

function Restore-TasksFromManifest {
    param([Parameter(Mandatory)]$Manifest)

    $items = @($Manifest.ScheduledTaskChanges)
    if ($items.Count -eq 0) {
        Write-Skip 'No scheduled task changes found in manifest.'
        return
    }

    foreach ($item in $items) {
        if ([string]::IsNullOrWhiteSpace($item.TaskName)) { continue }
        if ($item.PreviousState -eq 'Disabled') { continue }
        Invoke-ReclaimAction "Re-enable scheduled task: $($item.TaskPath)$($item.TaskName)" {
            Enable-ScheduledTask -TaskPath $item.TaskPath -TaskName $item.TaskName -ErrorAction Stop | Out-Null
        }
    }
}

function Get-RegistryValueSnapshot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $exists = $false
    $value = $null
    try {
        if (Test-Path -LiteralPath $Path) {
            $props = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
            if ($props.PSObject.Properties.Name -contains $Name) {
                $exists = $true
                $value = $props.$Name
            }
        }
    }
    catch {
        $exists = $false
    }

    [ordered]@{
        Path = $Path
        Name = $Name
        Exists = $exists
        Value = $value
    }
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )

    $snapshot = Get-RegistryValueSnapshot -Path $Path -Name $Name
    $script:Manifest['RegistryChanges'] += [ordered]@{
        Path = $Path
        Name = $Name
        Type = 'DWord'
        PreviousExists = $snapshot.Exists
        PreviousValue = $snapshot.Value
        NewValue = $Value
    }

    Invoke-ReclaimAction "Set registry DWORD: $Path\$Name = $Value" {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -PropertyType DWord -Value $Value -Force | Out-Null
    }
}

function Set-RegistryString {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $snapshot = Get-RegistryValueSnapshot -Path $Path -Name $Name
    $script:Manifest['RegistryChanges'] += [ordered]@{
        Path = $Path
        Name = $Name
        Type = 'String'
        PreviousExists = $snapshot.Exists
        PreviousValue = $snapshot.Value
        NewValue = $Value
    }

    Invoke-ReclaimAction "Set registry String: $Path\$Name = $Value" {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force | Out-Null
        }
        New-ItemProperty -Path $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
    }
}

function Find-RestoreKeyForAppxName {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($key in $KnownRestoreApps.Keys) {
        foreach ($candidate in @($KnownRestoreApps[$key].Appx)) {
            if ($Name -like $candidate) {
                return $key
            }
        }
    }
    return $null
}

function Add-AppxManifestEntry {
    param($Package)

    $manifestPath = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($Package.InstallLocation)) {
            $candidate = Join-Path $Package.InstallLocation 'AppxManifest.xml'
            if (Test-Path -LiteralPath $candidate) { $manifestPath = $candidate }
        }
    }
    catch {
        $manifestPath = $null
    }

    $script:Manifest['RemovedAppx'] += [ordered]@{
        Name = $Package.Name
        PackageFullName = $Package.PackageFullName
        PackageFamilyName = $Package.PackageFamilyName
        Version = $Package.Version.ToString()
        Publisher = $Package.Publisher
        Architecture = $Package.Architecture.ToString()
        InstallLocation = $Package.InstallLocation
        AppxManifestPath = $manifestPath
        RestoreKey = (Find-RestoreKeyForAppxName -Name $Package.Name)
    }
}

function Add-ProvisionedAppxManifestEntry {
    param($Package)

    $script:Manifest['RemovedProvisionedAppx'] += [ordered]@{
        DisplayName = $Package.DisplayName
        PackageName = $Package.PackageName
        Version = $Package.Version
        Architecture = $Package.Architecture
        ResourceId = $Package.ResourceId
        Region = $Package.Region
        InstallLocation = $Package.InstallLocation
        RestoreKey = (Find-RestoreKeyForAppxName -Name $Package.DisplayName)
    }
}

function Remove-AppxByPattern {
    param([Parameter(Mandatory)][string]$Pattern)

    $installed = @()
    try {
        $installed = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $Pattern })
    }
    catch {
        Write-ReclaimWarning ("Could not enumerate installed Appx packages for pattern {0}: {1}" -f $Pattern, $_.Exception.Message)
    }

    foreach ($pkg in $installed) {
        Add-AppxManifestEntry -Package $pkg
        $fullName = $pkg.PackageFullName
        Invoke-ReclaimAction "Remove Appx package for all users: $($pkg.Name)" {
            Remove-AppxPackage -Package $fullName -AllUsers -ErrorAction Stop
        }
    }

    $provisioned = @()
    try {
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $Pattern })
    }
    catch {
        Write-ReclaimWarning ("Could not enumerate provisioned Appx packages for pattern {0}: {1}" -f $Pattern, $_.Exception.Message)
    }

    foreach ($pkg in $provisioned) {
        Add-ProvisionedAppxManifestEntry -Package $pkg
        $packageName = $pkg.PackageName
        Invoke-ReclaimAction "Remove provisioned Appx package for new users: $($pkg.DisplayName)" {
            Remove-AppxProvisionedPackage -Online -PackageName $packageName -ErrorAction Stop | Out-Null
        }
    }

    if ($installed.Count -eq 0 -and $provisioned.Count -eq 0) {
        Write-Skip "Appx pattern not found: $Pattern"
    }
}

function Test-WingetAvailable {
    try {
        $cmd = Get-Command winget.exe -ErrorAction Stop
        return ($null -ne $cmd)
    }
    catch {
        return $false
    }
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = 'winget'
    )

    if (-not (Test-WingetAvailable)) {
        Write-ReclaimWarning 'winget.exe was not found. Install App Installer or restore from local Appx payload instead.'
        return
    }

    $args = @('install', '--id', $Id, '--exact', '--silent')
    if (-not [string]::IsNullOrWhiteSpace($Source)) {
        $args += @('--source', $Source)
    }
    if ($AcceptWingetAgreements) {
        $args += @('--accept-package-agreements', '--accept-source-agreements')
    }

    Invoke-ReclaimAction "Install app using winget: $Id" {
        $process = Start-Process -FilePath 'winget.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -ne 0) {
            throw "winget exited with code $($process.ExitCode)"
        }
    }
}

function Register-LocalAppxPackage {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return $false
    }

    Invoke-ReclaimAction "Register local Appx package: $Label" {
        Add-AppxPackage -Register $ManifestPath -DisableDevelopmentMode -ErrorAction Stop
    }
    return $true
}

function Restore-AppsFromManifest {
    param([Parameter(Mandatory)]$Manifest)

    $restoredKeys = New-Object System.Collections.Generic.HashSet[string]
    $appItems = @($Manifest.RemovedAppx)

    foreach ($item in $appItems) {
        $name = [string]$item.Name
        $manifestPath = [string]$item.AppxManifestPath
        $registered = $false
        if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
            $registered = Register-LocalAppxPackage -ManifestPath $manifestPath -Label $name
        }

        if (-not $registered -and $UseWingetFallback) {
            $key = [string]$item.RestoreKey
            if (-not [string]::IsNullOrWhiteSpace($key) -and $KnownRestoreApps.ContainsKey($key) -and -not $restoredKeys.Contains($key)) {
                $restoredKeys.Add($key) | Out-Null
                Invoke-WingetInstall -Id $KnownRestoreApps[$key].WingetId -Source $KnownRestoreApps[$key].Source
            }
            elseif ([string]::IsNullOrWhiteSpace($key)) {
                Write-Skip "No winget restore mapping for: $name"
            }
        }
        elseif (-not $registered) {
            Write-Skip "Local Appx manifest not found for: $name. Re-run with -UseWingetFallback if internet/winget restore is acceptable."
        }
    }

    $provisioned = @($Manifest.RemovedProvisionedAppx)
    if ($provisioned.Count -gt 0) {
        Write-Info 'Provisioned-app note: this script can re-register local Appx payloads for the current system/user. Re-provisioning for every future user may require original MSIX/Appx package files or a Windows image source.'
    }
}

function Install-KnownApps {
    param([string[]]$Names)

    foreach ($name in $Names) {
        if (-not $KnownRestoreApps.ContainsKey($name)) {
            Write-ReclaimWarning "Unknown app key: $name. Known keys: $($KnownRestoreApps.Keys -join ', ')"
            continue
        }

        $entry = $KnownRestoreApps[$name]
        $localRegistered = $false

        if (-not [string]::IsNullOrWhiteSpace($RestoreManifest)) {
            try {
                $manifest = Import-Manifest
                foreach ($item in @($manifest.RemovedAppx)) {
                    if ($item.RestoreKey -eq $name -and -not [string]::IsNullOrWhiteSpace($item.AppxManifestPath)) {
                        $localRegistered = Register-LocalAppxPackage -ManifestPath ([string]$item.AppxManifestPath) -Label ([string]$item.Name)
                        if ($localRegistered) { break }
                    }
                }
            }
            catch {
                Write-ReclaimWarning $_.Exception.Message
            }
        }

        if (-not $localRegistered) {
            if ($UseWingetFallback) {
                Invoke-WingetInstall -Id $entry.WingetId -Source $entry.Source
            }
            else {
                Write-Skip "App key '$name' needs -UseWingetFallback or a restore manifest with local Appx payload."
            }
        }
    }
}

function Remove-OneDrive {
    $paths = @(
        "$env:SystemRoot\System32\OneDriveSetup.exe",
        "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Invoke-ReclaimAction "Uninstall OneDrive using $path" {
                Start-Process -FilePath $path -ArgumentList '/uninstall' -Wait -NoNewWindow
            }
        }
    }

    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSync' -Value 1

    $folders = @(
        "$env:LOCALAPPDATA\Microsoft\OneDrive",
        "$env:ProgramData\Microsoft OneDrive",
        "$env:SystemDrive\OneDriveTemp"
    )
    foreach ($folder in $folders) {
        if (Test-Path -LiteralPath $folder) {
            Invoke-ReclaimAction "Remove OneDrive leftovers: $folder" {
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Apply-PrivacyAndLocalPolicies {
    Write-Section 'Privacy, local-first and consumer-feature policies'

    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableSoftLanding' -Value 1
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' -Name 'DisabledByGroupPolicy' -Value 1
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableActivityFeed' -Value 0
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'PublishUserActivities' -Value 0
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'UploadUserActivities' -Value 0
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Communications' -Name 'ConfigureChatAutoInstall' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarMn' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'ContentDeliveryAllowed' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'OemPreInstalledAppsEnabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'PreInstalledAppsEnabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'PreInstalledAppsEverEnabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338388Enabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338389Enabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338393Enabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-353698Enabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SystemPaneSuggestionsEnabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowSyncProviderNotifications' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'BingSearchEnabled' -Value 0
    Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'CortanaConsent' -Value 0
    Set-RegistryDword -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0
    Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0

    if ($RemoveCopilot -or $Profile -eq 'Extreme') {
        Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1
        Set-RegistryDword -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1
    }

    if ($RemoveWidgets -or $Profile -eq 'Extreme') {
        Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0
        Set-RegistryDword -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' -Name 'EnableFeeds' -Value 0
        Set-RegistryDword -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa' -Value 0
    }
}

function Remove-AppxBloat {
    Write-Section 'Appx package cleanup'
    $patterns = New-Object System.Collections.Generic.List[string]

    foreach ($p in $SafeAppxPatterns) { $patterns.Add($p) }
    if ($Profile -in @('Balanced', 'Extreme')) {
        foreach ($p in $BalancedAppxPatterns) { $patterns.Add($p) }
    }
    if ($Profile -eq 'Extreme') {
        foreach ($p in $ExtremeAppxPatterns) { $patterns.Add($p) }
    }
    if ($RemoveCopilot) {
        $patterns.Add('Microsoft.Copilot')
    }
    if ($RemoveWidgets) {
        $patterns.Add('MicrosoftWindows.Client.WebExperience')
    }
    if ($RemoveStore) {
        $patterns.Add('Microsoft.WindowsStore')
    }

    $patterns = @($patterns | Sort-Object -Unique)
    foreach ($pattern in $patterns) {
        Remove-AppxByPattern -Pattern $pattern
    }

    if ($RemoveStore) {
        Add-ManifestNote 'Microsoft Store was selected for removal. Restoring Store may require local Appx payload or winget/MS Store source availability.'
    }
}

function Disable-ServicesByProfile {
    Write-Section 'Service cleanup'

    foreach ($svc in $SafeServices) {
        Disable-ServiceSafe -Name $svc.Name -Reason $svc.Reason
    }

    if ($Profile -in @('Balanced', 'Extreme')) {
        foreach ($svc in $BalancedServices) {
            Disable-ServiceSafe -Name $svc.Name -Reason $svc.Reason
        }
        foreach ($svc in $PerUserServicePatternsBalanced) {
            Disable-ServicePatternSafe -Pattern $svc.Pattern -Reason $svc.Reason
        }
    }

    if ($Profile -eq 'Extreme') {
        foreach ($svc in $ExtremeServices) {
            Disable-ServiceSafe -Name $svc.Name -Reason $svc.Reason
        }
        foreach ($svc in $PerUserServicePatternsExtreme) {
            Disable-ServicePatternSafe -Pattern $svc.Pattern -Reason $svc.Reason
        }
    }

    if ($DisablePrintSpooler -or $Profile -eq 'Extreme') {
        Disable-ServiceSafe -Name 'Spooler' -Reason 'Print spooler explicitly disabled'
    }

    if ($DisableSearchIndexing -or $Profile -eq 'Extreme') {
        Disable-ServiceSafe -Name 'WSearch' -Reason 'Windows Search indexing explicitly disabled'
    }

    if ($DisableBluetooth -or $Profile -eq 'Extreme') {
        Disable-ServiceSafe -Name 'bthserv' -Reason 'Bluetooth support explicitly disabled'
        Disable-ServiceSafe -Name 'BthAvctpSvc' -Reason 'Bluetooth AVCTP support explicitly disabled'
        Disable-ServicePatternSafe -Pattern 'BluetoothUserService_*' -Reason 'Bluetooth per-user service explicitly disabled'
    }
}

function Disable-ScheduledTasksByProfile {
    Write-Section 'Scheduled task cleanup'
    foreach ($task in $ScheduledTasks) {
        Disable-ScheduledTaskSafe -TaskPath $task.Path -TaskName $task.Name
    }

    if ($Profile -eq 'Extreme') {
        foreach ($task in $ExtremeScheduledTasks) {
            Disable-ScheduledTaskSafe -TaskPath $task.Path -TaskName $task.Name
        }
    }
}

function Disable-LegacyOptionalFeatures {
    Write-Section 'Legacy optional Windows features'
    foreach ($feature in $LegacyOptionalFeatures) {
        $state = $null
        try {
            $info = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue
            if ($null -ne $info) { $state = $info.State.ToString() }
        }
        catch {
            $state = $null
        }

        if ($null -eq $state) {
            Write-Skip "Optional feature not found: $feature"
            continue
        }

        $script:Manifest['OptionalFeatureChanges'] += [ordered]@{
            FeatureName = $feature
            PreviousState = $state
            NewState = 'Disabled'
        }

        if ($state -eq 'Disabled') {
            Write-Skip "Optional feature already disabled: $feature"
            continue
        }

        Invoke-ReclaimAction "Disable optional Windows feature: $feature" {
            Disable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -ErrorAction Stop | Out-Null
        }
    }
}

function Invoke-DiskCleanup {
    Write-Section 'Disk cleanup'

    $paths = @(
        $env:TEMP,
        "$env:SystemRoot\Temp",
        "$env:SystemRoot\Prefetch",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Invoke-ReclaimAction "Clean directory contents: $path" {
                Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue |
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Invoke-ReclaimAction 'Clean Windows Update download cache when safe' {
        try { Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue } catch {}
        try { Stop-Service -Name bits -Force -ErrorAction SilentlyContinue } catch {}
        $downloadPath = "$env:SystemRoot\SoftwareDistribution\Download"
        if (Test-Path -LiteralPath $downloadPath) {
            Get-ChildItem -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        try { Start-Service -Name bits -ErrorAction SilentlyContinue } catch {}
        try { Start-Service -Name wuauserv -ErrorAction SilentlyContinue } catch {}
    }
}

function Invoke-ComponentStoreCleanup {
    Write-Section 'Component store cleanup'

    Invoke-ReclaimAction 'Run DISM component store cleanup' {
        $args = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
        if ($ResetComponentBase) {
            $args += '/ResetBase'
        }
        $process = Start-Process -FilePath 'dism.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -ne 0) {
            throw "DISM exited with code $($process.ExitCode)"
        }
    }

    if ($ResetComponentBase) {
        Add-ManifestNote 'DISM /ResetBase was used. Installed Windows updates may no longer be removable.'
    }
}

function Disable-HibernationFile {
    Write-Section 'Hibernation'
    Invoke-ReclaimAction 'Disable hibernation and remove hiberfil.sys' {
        & powercfg.exe /hibernate off
        if ($LASTEXITCODE -ne 0) {
            throw "powercfg exited with code $LASTEXITCODE"
        }
    }
}

function Create-SystemRestorePoint {
    Write-Section 'System restore point'
    Invoke-ReclaimAction 'Create system restore point' {
        Checkpoint-Computer -Description "WindowsDebloat $script:RunStamp" -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    }
}

function Stop-CommonConsumerProcesses {
    Write-Section 'Stop common consumer background processes'
    $names = @('OneDrive', 'Teams', 'ms-teams', 'Widgets', 'WidgetService', 'GameBar', 'GameBarFTServer', 'XboxAppServices')
    foreach ($name in $names) {
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        foreach ($proc in $procs) {
            $pid = $proc.Id
            Invoke-ReclaimAction "Stop process: $name ($pid)" {
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Show-ImportantWarnings {
    if ($Profile -eq 'Extreme') {
        Write-ReclaimWarning 'Extreme profile may disable search indexing, SysMain, touch keyboard, notifications, print workflow, Bluetooth user services and convenience apps. Use only on systems where this is intentional.'
    }
    if ($RemoveStore) {
        Write-ReclaimWarning 'Removing Microsoft Store can make app restoration harder. Keep the restore manifest and use -UseWingetFallback if local Appx payloads are gone.'
    }
    if ($ResetComponentBase) {
        Write-ReclaimWarning 'ResetComponentBase saves disk space but prevents uninstalling already-installed Windows updates.'
    }
}

function Invoke-DebloatRun {
    Assert-SupportedOS
    Show-ImportantWarnings

    Write-Section 'Run mode'
    if ($script:IsDryRun) {
        Write-DryRun 'No changes will be made. Pass -Apply to execute the plan.'
    }
    else {
        Write-Info 'Apply mode enabled. Changes will be written to this system.'
    }
    Write-Info "Profile: $Profile"

    if ($CreateRestorePoint) { Create-SystemRestorePoint }

    Stop-CommonConsumerProcesses
    Apply-PrivacyAndLocalPolicies
    Remove-AppxBloat

    if ($RemoveOneDrive -or $Profile -eq 'Extreme') {
        Write-Section 'OneDrive cleanup'
        Remove-OneDrive
    }

    Disable-ServicesByProfile
    Disable-ScheduledTasksByProfile

    if ($DisableLegacyFeatures -or $Profile -eq 'Extreme') {
        Disable-LegacyOptionalFeatures
    }

    if ($DisableHibernation -or $Profile -eq 'Extreme') {
        Disable-HibernationFile
    }

    if ($CleanDisk) {
        Invoke-DiskCleanup
    }

    if ($CleanComponentStore) {
        Invoke-ComponentStoreCleanup
    }

    Export-Manifest
}

function Invoke-RestoreRun {
    Assert-SupportedOS
    $manifest = Import-Manifest

    Write-Section 'Restore mode'
    if ($script:IsDryRun) {
        Write-DryRun 'No changes will be made. Pass -Apply to restore.'
    }

    if ($RestoreApps) { Restore-AppsFromManifest -Manifest $manifest }
    if ($RestoreServices) { Restore-ServicesFromManifest -Manifest $manifest }
    if ($RestoreTasks) { Restore-TasksFromManifest -Manifest $manifest }

    if (-not $RestoreApps -and -not $RestoreServices -and -not $RestoreTasks) {
        Write-ReclaimWarning 'No restore category selected. Use -RestoreApps, -RestoreServices, or -RestoreTasks.'
    }
}

function Invoke-InstallRun {
    Assert-SupportedOS
    Write-Section 'Install known apps mode'
    if ($script:IsDryRun) {
        Write-DryRun 'No changes will be made. Pass -Apply to install apps.'
    }
    Install-KnownApps -Names $InstallApps
}

try {
    Start-Logging

    switch ($PSCmdlet.ParameterSetName) {
        'Restore' { Invoke-RestoreRun }
        'Install' { Invoke-InstallRun }
        default { Invoke-DebloatRun }
    }

    Write-Section 'Summary'
    Write-Info "Actions planned/executed: $script:ActionCount"
    Write-Info "Warnings: $script:WarningCount"
    if (-not $script:IsDryRun) {
        Write-Info "Log: $script:TranscriptPath"
        Write-Info "Manifest: $script:ManifestPath"
    }
}
catch {
    Write-ReclaimWarning $_.Exception.Message
    throw
}
finally {
    Stop-Logging
}
