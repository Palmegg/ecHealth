<# 
ecHealth
PowerShell 5.1 + WPF local endpoint troubleshooting application.
#>

param(
    [switch]$SilentScan
)

#region Modifiable Parameters
$script:Config = [ordered]@{
    EventLookbackDays                 = 14
    BiosAgeWarningDays                = 730
    LowDiskFreePercentWarning         = 15
    LowDiskFreeGBWarning              = 20
    MissingUpdateActivityDays         = 45
    MaxEventsPerChannel               = 80
    MaxDriverRowsPerClass             = 40
    ScoreDeductions                   = [ordered]@{
        PendingReboot                 = 8
        OldBios                       = 8
        LowDiskSpace                  = 10
        WindowsUpdateFailures         = 10
        MissingUpdateActivity         = 8
        CriticalSystemEvents          = 10
        BugCheckEvents                = 15
        UnexpectedShutdowns           = 10
        WHEAErrors                    = 12
        DiskErrors                    = 12
        NTFSErrors                    = 12
        IMEServiceNotRunning          = 12
        MissingIMELogs                = 8
        ProblemPnpDevices             = 8
        FailedScanSection             = 5
    }
}
#endregion Modifiable Parameters

#region Static Variables
$script:AppName = 'ecHealth'
$script:AppVersion = '1.1.1'
$script:RootPath = 'C:\ProgramData\EndpointHealthAnalyzer'
$script:ReportsPath = Join-Path $script:RootPath 'Reports'
$script:LogsPath = Join-Path $script:RootPath 'Logs'
$script:DataPath = Join-Path $script:RootPath 'Data'
$script:ReportPath = Join-Path $script:ReportsPath 'EndpointHealthReport.html'
$script:JsonReportPath = Join-Path $script:DataPath 'EndpointHealthReport.json'
$script:LogPath = Join-Path $script:LogsPath 'EndpointHealthAnalyzer.log'
$script:BaselinePath = Join-Path $script:DataPath 'Baseline.json'
$script:ProgressPath = Join-Path $script:DataPath 'ScanProgress.json'
$script:XamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
$script:TemplatePath = Join-Path $PSScriptRoot 'ReportTemplate.html'
$script:CurrentReport = $null
$script:LoadedBaseline = $null
$script:ScanProcess = $null
$script:ScanTimer = $null
$script:Controls = @{}
$script:FailedSections = New-Object System.Collections.ArrayList
#endregion Static Variables

#region Logging Functions
function Initialize-AppFolders {
    foreach ($path in @($script:RootPath, $script:ReportsPath, $script:LogsPath, $script:DataPath)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }
}

function Write-ToLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    try {
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    } catch {
        # Logging must never break scanning.
    }
}

function Write-DebugToLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-ToLog -Message $Message -Level 'INFO'
}

function Add-FailedSection {
    param([string]$Section, [string]$ErrorMessage)
    [void]$script:FailedSections.Add([pscustomobject]@{
        Section = $Section
        Error   = $ErrorMessage
    })
    Write-ToLog -Message "$Section failed: $ErrorMessage" -Level 'ERROR'
}
#endregion Logging Functions

#region GUI Loading Functions
function Import-Gui {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms

    if (-not (Test-Path -LiteralPath $script:XamlPath)) {
        throw "MainWindow.xaml was not found at $script:XamlPath"
    }

    [xml]$xaml = Get-Content -LiteralPath $script:XamlPath -Raw
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $script:Window = [Windows.Markup.XamlReader]::Load($reader)

    $names = @(
        'StartScanButton','ExportReportButton','OpenReportButton','OpenLogsButton','StatusText','ScanProgressBar',
        'VersionText',
        'HealthScoreText','HealthCategoryText','DeviceSummaryText','DeviceSubSummaryText',
        'CriticalCountText','WarningCountText','CriticalFindingsList','WarningsList',
        'LastScanResultText','DeviceDetailsText','WindowsUpdateText','IntuneText',
        'DriversFirmwareText','EventLogsText','DiskHardwareText','ComparisonText',
        'ExportBaselineButton','LoadBaselineButton','CompareBaselineButton',
        'ReportPathText','JsonPathText','LogPathText','ExportReportButton2',
        'OpenReportButton2','OpenLogsButton2','OpenOutputFolderButton'
    )

    foreach ($name in $names) {
        $script:Controls[$name] = $script:Window.FindName($name)
    }

    $script:Window.Title = "$script:AppName v$script:AppVersion"
    $script:Window.WindowStartupLocation = 'CenterScreen'
    if ($script:Controls.VersionText) {
        $script:Controls.VersionText.Text = "v$script:AppVersion"
    }

    $script:Controls.StartScanButton.Add_Click({ Start-ScanWorkflow })
    $script:Controls.ExportReportButton.Add_Click({ Export-HtmlReportCopy })
    $script:Controls.ExportReportButton2.Add_Click({ Export-HtmlReportCopy })
    $script:Controls.OpenReportButton.Add_Click({ Open-Report })
    $script:Controls.OpenReportButton2.Add_Click({ Open-Report })
    $script:Controls.OpenLogsButton.Add_Click({ Open-Logs })
    $script:Controls.OpenLogsButton2.Add_Click({ Open-Logs })
    $script:Controls.ExportBaselineButton.Add_Click({ Export-Baseline })
    $script:Controls.LoadBaselineButton.Add_Click({ Load-Baseline })
    $script:Controls.CompareBaselineButton.Add_Click({ Compare-BaselineFromGui })
    $script:Controls.OpenOutputFolderButton.Add_Click({ Start-Process -FilePath $script:RootPath })
}
#endregion GUI Loading Functions

#region GUI Helper Functions
function Invoke-Gui {
    param([scriptblock]$ScriptBlock)
    if ($script:Window) {
        $script:Window.Dispatcher.Invoke([Action]$ScriptBlock)
    }
}

function Set-GuiStatus {
    param([string]$Status, [int]$Progress)
    Invoke-Gui {
        $script:Controls.StatusText.Text = $Status
        $script:Controls.ScanProgressBar.Value = $Progress
    }
    try {
        $progressObject = [pscustomobject]@{
            Status    = $Status
            Progress  = $Progress
            UpdatedAt = Get-Date
            ProcessId = $PID
        }
        $progressObject | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:ProgressPath -Encoding UTF8
    } catch {
        Write-ToLog -Message "Unable to write progress file: $($_.Exception.Message)" -Level 'WARN'
    }
    Write-DebugToLog $Status
}

function Set-ButtonsForScan {
    param([bool]$IsScanning)
    Invoke-Gui {
        $script:Controls.StartScanButton.IsEnabled = -not $IsScanning
        foreach ($name in @('ExportReportButton','OpenReportButton','ExportReportButton2','OpenReportButton2','ExportBaselineButton','CompareBaselineButton')) {
            if ($script:Controls[$name]) { $script:Controls[$name].IsEnabled = (-not $IsScanning -and $null -ne $script:CurrentReport) }
        }
    }
}

function ConvertTo-DisplayJson {
    param($InputObject)
    try { return ($InputObject | ConvertTo-Json -Depth 8) } catch { return ($InputObject | Out-String) }
}

function Update-GuiWithReport {
    param([pscustomobject]$Report)

    $criticalItems = @($Report.CriticalFindings | ForEach-Object { "[{0}] {1} - {2}" -f $_.Category, $_.Title, $_.RecommendedAction })
    $warningItems = @($Report.Warnings | ForEach-Object { "[{0}] {1} - {2}" -f $_.Category, $_.Title, $_.RecommendedAction })
    $summary = @"
Scan completed: $($Report.Metadata.GeneratedAt)
Report: $script:ReportPath
JSON: $script:JsonReportPath
Failed sections: $(@($Report.Metadata.FailedSections).Count)
"@

    Invoke-Gui {
        $script:Controls.HealthScoreText.Text = [string]$Report.HealthScore.Score
        $script:Controls.HealthCategoryText.Text = $Report.HealthScore.Category
        $script:Controls.DeviceSummaryText.Text = "$($Report.Device.ComputerName)"
        $script:Controls.DeviceSubSummaryText.Text = "$($Report.Hardware.Manufacturer) $($Report.Hardware.Model) | $($Report.Device.OSBuild)"
        $script:Controls.CriticalCountText.Text = [string]@($Report.CriticalFindings).Count
        $script:Controls.WarningCountText.Text = [string]@($Report.Warnings).Count
        $script:Controls.CriticalFindingsList.Items.Clear()
        $script:Controls.WarningsList.Items.Clear()
        foreach ($item in $criticalItems) { [void]$script:Controls.CriticalFindingsList.Items.Add($item) }
        foreach ($item in $warningItems) { [void]$script:Controls.WarningsList.Items.Add($item) }
        if ($criticalItems.Count -eq 0) { [void]$script:Controls.CriticalFindingsList.Items.Add('No critical findings detected.') }
        if ($warningItems.Count -eq 0) { [void]$script:Controls.WarningsList.Items.Add('No warnings detected.') }
        $script:Controls.LastScanResultText.Text = $summary
        $script:Controls.DeviceDetailsText.Text = ConvertTo-DisplayJson $Report.Device
        $script:Controls.WindowsUpdateText.Text = ConvertTo-DisplayJson $Report.WindowsUpdate
        $script:Controls.IntuneText.Text = ConvertTo-DisplayJson $Report.Intune
        $script:Controls.DriversFirmwareText.Text = ConvertTo-DisplayJson $Report.DriversFirmware
        $script:Controls.EventLogsText.Text = ConvertTo-DisplayJson $Report.EventLogs
        $script:Controls.DiskHardwareText.Text = ConvertTo-DisplayJson $Report.DiskHardware
        $script:Controls.ComparisonText.Text = ConvertTo-DisplayJson $Report.Comparison
        foreach ($name in @('ExportReportButton','OpenReportButton','ExportReportButton2','OpenReportButton2','ExportBaselineButton','CompareBaselineButton')) {
            $script:Controls[$name].IsEnabled = $true
        }
    }
}
#endregion GUI Helper Functions

#region Collection Functions
function Invoke-SafeSection {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )
    Write-ToLog -Message "Starting section: $Name"
    try {
        $result = & $ScriptBlock
        Write-ToLog -Message "Completed section: $Name"
        return $result
    } catch {
        Add-FailedSection -Section $Name -ErrorMessage $_.Exception.Message
        return $DefaultValue
    }
}

function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-CurrentLoggedOnUser {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        return $cs.UserName
    } catch {
        return $null
    }
}

function Get-PendingRebootStatus {
    $checks = [ordered]@{
        ComponentBasedServicing = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WindowsUpdate           = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        PendingFileRename       = $false
        ComputerRename          = $false
    }
    try {
        $session = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        $checks.PendingFileRename = $null -ne $session.PendingFileRenameOperations
    } catch { }
    try {
        $active = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop
        $pending = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop
        $checks.ComputerRename = $active.ComputerName -ne $pending.ComputerName
    } catch { }

    [pscustomobject]@{
        IsPending = ($checks.Values -contains $true)
        Checks    = [pscustomobject]$checks
    }
}

function Get-DsRegStatus {
    $result = [ordered]@{
        AzureAdJoined  = $null
        EnterpriseJoined = $null
        DomainJoined   = $null
        TenantName     = $null
        TenantId       = $null
        RawAvailable   = $false
    }
    try {
        $raw = & dsregcmd.exe /status 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            $result.RawAvailable = $true
            foreach ($line in $raw) {
                if ($line -match '^\s*AzureAdJoined\s*:\s*(.+)$') { $result.AzureAdJoined = $matches[1].Trim() }
                if ($line -match '^\s*EnterpriseJoined\s*:\s*(.+)$') { $result.EnterpriseJoined = $matches[1].Trim() }
                if ($line -match '^\s*DomainJoined\s*:\s*(.+)$') { $result.DomainJoined = $matches[1].Trim() }
                if ($line -match '^\s*TenantName\s*:\s*(.+)$') { $result.TenantName = $matches[1].Trim() }
                if ($line -match '^\s*TenantId\s*:\s*(.+)$') { $result.TenantId = $matches[1].Trim() }
            }
        }
    } catch { }
    [pscustomobject]$result
}

function Get-MdmEnrollmentIndicators {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Enrollments',
        'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts',
        'HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked'
    )
    $items = @()
    foreach ($path in $paths) {
        try {
            if (Test-Path $path) {
                $children = @(Get-ChildItem -Path $path -ErrorAction SilentlyContinue)
                $items += [pscustomobject]@{ Path = $path; Exists = $true; ChildCount = $children.Count }
            } else {
                $items += [pscustomobject]@{ Path = $path; Exists = $false; ChildCount = 0 }
            }
        } catch {
            $items += [pscustomobject]@{ Path = $path; Exists = $null; ChildCount = 0; Error = $_.Exception.Message }
        }
    }
    [pscustomobject]@{
        Indicators = $items
        IsLikelyMdmEnrolled = (@($items | Where-Object { $_.Exists -and $_.ChildCount -gt 0 }).Count -gt 0)
    }
}

function Get-DeviceIdentity {
    Invoke-SafeSection -Name 'Device identity' -DefaultValue ([pscustomobject]@{ SectionFailed = $true }) -ScriptBlock {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $dsreg = Get-DsRegStatus
        $pending = Get-PendingRebootStatus
        $installDate = $os.InstallDate
        $lastBoot = $os.LastBootUpTime
        $uptime = New-TimeSpan -Start $lastBoot -End (Get-Date)
        $mdm = Get-MdmEnrollmentIndicators

        [pscustomobject]@{
            ComputerName              = $env:COMPUTERNAME
            RunningAccount            = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            CurrentLoggedOnUser       = Get-CurrentLoggedOnUser
            IsAdministrator           = Test-IsAdmin
            DomainJoined              = [bool]$cs.PartOfDomain
            Domain                    = $cs.Domain
            AzureAdJoined             = $dsreg.AzureAdJoined
            EntraJoined               = $dsreg.AzureAdJoined
            EnterpriseJoined          = $dsreg.EnterpriseJoined
            HybridJoinedLikely        = (($cs.PartOfDomain -eq $true) -and ($dsreg.AzureAdJoined -eq 'YES'))
            TenantName                = $dsreg.TenantName
            TenantId                  = $dsreg.TenantId
            IntuneEnrollmentLikely    = $mdm.IsLikelyMdmEnrolled
            MdmEnrollmentIndicators   = $mdm.Indicators
            OSName                    = $os.Caption
            OSVersion                 = $os.Version
            OSBuild                   = $os.BuildNumber
            OSArchitecture            = $os.OSArchitecture
            InstallDate               = $installDate
            LastBootTime              = $lastBoot
            Uptime                    = '{0}d {1}h {2}m' -f [int]$uptime.TotalDays, $uptime.Hours, $uptime.Minutes
            PendingReboot             = $pending.IsPending
            PendingRebootDetails      = $pending.Checks
        }
    }
}

function Get-EndpointHardware {
    Invoke-SafeSection -Name 'Hardware' -DefaultValue ([pscustomobject]@{ SectionFailed = $true }) -ScriptBlock {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        $logical = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        $systemDrive = $logical | Where-Object { $_.DeviceID -eq $env:SystemDrive } | Select-Object -First 1
        $disks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue | Select-Object Model,SerialNumber,Size,MediaType,InterfaceType,Status)
        $battery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object Name,BatteryStatus,EstimatedChargeRemaining,Status)
        $physicalDisks = @()
        try {
            if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
                $physicalDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Select-Object FriendlyName,MediaType,HealthStatus,OperationalStatus,Size)
            }
        } catch { }
        $tpm = $null
        try {
            if (Get-Command Get-Tpm -ErrorAction SilentlyContinue) {
                $tpm = Get-Tpm -ErrorAction SilentlyContinue
            }
        } catch { }
        $biosDate = $bios.ReleaseDate
        $biosAgeDays = if ($biosDate) { [int]((Get-Date) - $biosDate).TotalDays } else { $null }

        [pscustomobject]@{
            Manufacturer           = $cs.Manufacturer
            Model                  = $cs.Model
            SerialNumber           = $bios.SerialNumber
            CPUName                = $cpu.Name
            CPUCoreCount           = $cpu.NumberOfCores
            CPULogicalProcessors   = $cpu.NumberOfLogicalProcessors
            RAMTotalGB             = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 2)
            SystemDrive            = $env:SystemDrive
            SystemDriveSizeGB      = if ($systemDrive) { [math]::Round($systemDrive.Size / 1GB, 2) } else { $null }
            SystemDriveFreeGB      = if ($systemDrive) { [math]::Round($systemDrive.FreeSpace / 1GB, 2) } else { $null }
            SystemDriveFreePercent = if ($systemDrive -and $systemDrive.Size) { [math]::Round(($systemDrive.FreeSpace / $systemDrive.Size) * 100, 2) } else { $null }
            Disks                  = $disks
            PhysicalDiskHealth     = $physicalDisks
            Battery                = $battery
            TPM                    = if ($tpm) { $tpm | Select-Object TpmPresent,TpmReady,TpmEnabled,TpmActivated,ManufacturerIdTxt,ManagedAuthLevel } else { $null }
            BIOSVersion            = @($bios.SMBIOSBIOSVersion, $bios.Version | Where-Object { $_ })[0]
            BIOSReleaseDate        = $biosDate
            BIOSAgeDays            = $biosAgeDays
            BIOSAgeWarning         = ($biosAgeDays -ne $null -and $biosAgeDays -gt $script:Config.BiosAgeWarningDays)
        }
    }
}

function Test-EventLogExists {
    param([string]$LogName)
    try {
        $null = Get-WinEvent -ListLog $LogName -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-RecentEvents {
    param(
        [string]$LogName,
        [int[]]$Levels = @(1,2,3),
        [int]$MaxEvents = $script:Config.MaxEventsPerChannel
    )
    if (-not (Test-EventLogExists -LogName $LogName)) {
        return [pscustomobject]@{
            LogName = $LogName
            Exists = $false
            Events = @()
            Counts = [pscustomobject]@{ Critical = 0; Error = 0; Warning = 0 }
        }
    }

    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName   = $LogName
            StartTime = (Get-Date).AddDays(-1 * $script:Config.EventLookbackDays)
            Level     = $Levels
        } -MaxEvents $MaxEvents -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                TimeCreated  = $_.TimeCreated
                Id           = $_.Id
                LevelDisplay = $_.LevelDisplayName
                ProviderName = $_.ProviderName
                Message      = ($_.Message -replace '\s+', ' ').Trim()
            }
        })
    } catch {
        Write-ToLog -Message "Unable to read $LogName events: $($_.Exception.Message)" -Level 'WARN'
        $events = @()
    }

    [pscustomobject]@{
        LogName = $LogName
        Exists = $true
        Events = $events
        Counts = [pscustomobject]@{
            Critical = @($events | Where-Object { $_.LevelDisplay -eq 'Critical' }).Count
            Error    = @($events | Where-Object { $_.LevelDisplay -eq 'Error' }).Count
            Warning  = @($events | Where-Object { $_.LevelDisplay -eq 'Warning' }).Count
        }
    }
}

function Get-WindowsUpdateData {
    Invoke-SafeSection -Name 'Windows Update' -DefaultValue ([pscustomobject]@{ SectionFailed = $true }) -ScriptBlock {
        $wuEvents = Get-RecentEvents -LogName 'Microsoft-Windows-WindowsUpdateClient/Operational' -Levels @(1,2,3,4) -MaxEvents 120
        $failedEvents = @($wuEvents.Events | Where-Object { $_.LevelDisplay -in @('Error','Critical') -or $_.Id -in @(20,25,31,34,35) })
        $latestActivity = @($wuEvents.Events | Sort-Object TimeCreated -Descending | Select-Object -First 1)
        $latestHotfix = $null
        try { $latestHotfix = Get-HotFix -ErrorAction SilentlyContinue | Sort-Object InstalledOn -Descending | Select-Object -First 1 } catch { }
        $policyPaths = @(
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate',
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
            'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
        )
        $policy = @()
        foreach ($path in $policyPaths) {
            if (Test-Path $path) {
                $props = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                $policy += [pscustomobject]@{
                    Path       = $path
                    Properties = ($props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.Value } })
                }
            }
        }
        $pendingUpdates = @()
        try {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $result = $searcher.Search("IsInstalled=0 and Type='Software'")
            foreach ($update in $result.Updates) {
                $pendingUpdates += [pscustomobject]@{ Title = $update.Title; IsDownloaded = $update.IsDownloaded; RebootRequired = $update.RebootRequired }
            }
        } catch {
            Write-ToLog -Message "Pending update COM query unavailable: $($_.Exception.Message)" -Level 'WARN'
        }

        $lastActivityDate = if ($latestActivity.Count -gt 0) { $latestActivity[0].TimeCreated } else { $null }
        [pscustomobject]@{
            LastWindowsUpdateScan                = $lastActivityDate
            LastSuccessfulUpdateInstallation     = if ($latestHotfix) { $latestHotfix.InstalledOn } else { $null }
            LastSuccessfulHotFix                 = if ($latestHotfix) { [pscustomobject]@{ HotFixID = $latestHotfix.HotFixID; Description = $latestHotfix.Description; InstalledOn = $latestHotfix.InstalledOn; InstalledBy = $latestHotfix.InstalledBy } } else { $null }
            PendingUpdates                       = $pendingUpdates
            PendingUpdateCount                   = @($pendingUpdates).Count
            FailedWindowsUpdateEvents            = $failedEvents
            FailedWindowsUpdateEventCount        = @($failedEvents).Count
            WindowsUpdatePolicySourceRegistry    = $policy
            RecentWindowsUpdateClientEvents      = $wuEvents
            MissingRecentUpdateActivity          = ($null -eq $lastActivityDate -or $lastActivityDate -lt (Get-Date).AddDays(-1 * $script:Config.MissingUpdateActivityDays))
        }
    }
}

function Get-IntuneData {
    Invoke-SafeSection -Name 'Intune' -DefaultValue ([pscustomobject]@{ SectionFailed = $true }) -ScriptBlock {
        $service = $null
        try { $service = Get-Service -Name 'IntuneManagementExtension' -ErrorAction SilentlyContinue } catch { }
        $logFolder = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
        $expectedLogs = @('IntuneManagementExtension.log','AgentExecutor.log','AppWorkload.log','ClientHealth.log','Win32AppInventory.log')
        $files = @()
        if (Test-Path -LiteralPath $logFolder) {
            $files = @(Get-ChildItem -LiteralPath $logFolder -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 40 | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName; SizeKB = [math]::Round($_.Length / 1KB, 1); LastWriteTime = $_.LastWriteTime }
            })
        }
        $presence = foreach ($name in $expectedLogs) {
            $match = $files | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            [pscustomobject]@{ Name = $name; Present = $null -ne $match; LastWriteTime = if ($match) { $match.LastWriteTime } else { $null } }
        }
        $deviceMgmtEvents = Get-RecentEvents -LogName 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin' -Levels @(1,2,3) -MaxEvents 100
        $autopilotEvents = Get-RecentEvents -LogName 'Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot' -Levels @(1,2,3,4) -MaxEvents 60
        $mdm = Get-MdmEnrollmentIndicators

        [pscustomobject]@{
            IMEServiceName                 = 'IntuneManagementExtension'
            IMEServiceStatus               = if ($service) { $service.Status.ToString() } else { 'NotInstalledOrNotFound' }
            IMEServiceStartType            = if ($service) { $service.StartType.ToString() } else { $null }
            IMELogFolder                   = $logFolder
            IMELogFolderExists             = Test-Path -LiteralPath $logFolder
            RecentIMELogFiles              = $files
            ExpectedIMELogs                = $presence
            LatestIMELogModified           = if ($files.Count -gt 0) { ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime } else { $null }
            MDMEnrollmentRegistryIndicators = $mdm
            DeviceManagementEvents         = $deviceMgmtEvents
            AutopilotEvents                = $autopilotEvents
            AutopilotEventChannelPresent   = $autopilotEvents.Exists
        }
    }
}

function Get-DriversFirmwareData {
    param([pscustomobject]$Hardware)
    Invoke-SafeSection -Name 'Drivers and firmware' -DefaultValue ([pscustomobject]@{ SectionFailed = $true }) -ScriptBlock {
        $problemDevices = @()
        try {
            if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
                $problemDevices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -notin @('OK','Unknown') } | Select-Object Status,Class,FriendlyName,InstanceId,Problem)
            }
        } catch {
            Write-ToLog -Message "Problem PnP query unavailable: $($_.Exception.Message)" -Level 'WARN'
        }

        $signedDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue)
        function Select-DriversByClass {
            param([string[]]$Classes)
            @($signedDrivers | Where-Object { $_.DeviceClass -in $Classes } | Sort-Object DeviceName | Select-Object -First $script:Config.MaxDriverRowsPerClass DeviceName,DeviceClass,DriverVersion,DriverDate,Manufacturer,InfName)
        }

        [pscustomobject]@{
            BIOSVersion            = $Hardware.BIOSVersion
            BIOSReleaseDate        = $Hardware.BIOSReleaseDate
            BIOSAgeDays            = $Hardware.BIOSAgeDays
            BIOSAgeWarning         = $Hardware.BIOSAgeWarning
            ProblemPnpDevices      = $problemDevices
            ProblemPnpDeviceCount  = @($problemDevices).Count
            DisplayAdapters        = Select-DriversByClass -Classes @('DISPLAY')
            NetworkAdapters        = Select-DriversByClass -Classes @('NET')
            StorageControllers     = Select-DriversByClass -Classes @('SCSIAdapter','HDC','Storage')
            SystemChipsetDevices   = Select-DriversByClass -Classes @('System','MEDIA','USB')
        }
    }
}

function Get-EventLogAnalysis {
    Invoke-SafeSection -Name 'Event logs' -DefaultValue ([pscustomobject]@{ SectionFailed = $true }) -ScriptBlock {
        $channels = @(
            'System',
            'Application',
            'Setup',
            'Microsoft-Windows-WindowsUpdateClient/Operational',
            'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin',
            'Microsoft-Windows-ModernDeployment-Diagnostics-Provider/Autopilot'
        )
        $results = foreach ($channel in $channels) { Get-RecentEvents -LogName $channel -Levels @(1,2,3) -MaxEvents $script:Config.MaxEventsPerChannel }
        $allEvents = @($results | ForEach-Object { $_.Events })
        [pscustomobject]@{
            LookbackDays                = $script:Config.EventLookbackDays
            Channels                    = $results
            CriticalEventCount          = @($allEvents | Where-Object { $_.LevelDisplay -eq 'Critical' }).Count
            ErrorEventCount             = @($allEvents | Where-Object { $_.LevelDisplay -eq 'Error' }).Count
            WarningEventCount           = @($allEvents | Where-Object { $_.LevelDisplay -eq 'Warning' }).Count
            BugCheckEvents              = @($allEvents | Where-Object { $_.Id -eq 1001 -and $_.ProviderName -match 'BugCheck' })
            UnexpectedShutdowns         = @($allEvents | Where-Object { $_.Id -eq 41 -and $_.ProviderName -match 'Kernel-Power' })
            DiskErrors                  = @($allEvents | Where-Object { $_.ProviderName -match 'disk|storahci|stornvme|iaStor|Ntfs' -or $_.Message -match '\bdisk\b|storage|bad block' })
            NTFSErrors                  = @($allEvents | Where-Object { $_.ProviderName -match 'Ntfs' })
            WHEAErrors                  = @($allEvents | Where-Object { $_.ProviderName -match 'WHEA' })
            DisplayDriverCrashes        = @($allEvents | Where-Object { $_.ProviderName -match 'Display' -or $_.Message -match 'display driver|nvlddmkm|amdwddmg|igfx' })
            ApplicationCrashes          = @($allEvents | Where-Object { $_.ProviderName -match 'Application Error|Windows Error Reporting' })
            MSIInstallerFailures        = @($allEvents | Where-Object { $_.ProviderName -match 'MsiInstaller' -and $_.LevelDisplay -in @('Error','Warning') })
            WindowsUpdateFailures       = @($allEvents | Where-Object { $_.ProviderName -match 'WindowsUpdateClient' -and $_.LevelDisplay -in @('Error','Critical') })
            IntuneErrors                = @($allEvents | Where-Object { $_.ProviderName -match 'DeviceManagement|Enterprise-Diagnostics' -and $_.LevelDisplay -in @('Error','Critical') })
            ServiceControlManagerErrors = @($allEvents | Where-Object { $_.ProviderName -match 'Service Control Manager' -and $_.LevelDisplay -in @('Error','Critical') })
        }
    }
}

function Get-DiskHardwareHealth {
    param([pscustomobject]$Hardware, [pscustomobject]$EventLogs)
    Invoke-SafeSection -Name 'Disk and hardware health' -DefaultValue ([pscustomobject]@{ SectionFailed = $true }) -ScriptBlock {
        $reliability = @()
        try {
            $reliability = @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue | Select-Object InstanceName,PredictFailure,Reason)
        } catch {
            Write-ToLog -Message "SMART reliability query unavailable: $($_.Exception.Message)" -Level 'WARN'
        }
        [pscustomobject]@{
            SystemDriveFreeGB        = $Hardware.SystemDriveFreeGB
            SystemDriveFreePercent   = $Hardware.SystemDriveFreePercent
            LowDiskSpace             = (($Hardware.SystemDriveFreePercent -ne $null -and $Hardware.SystemDriveFreePercent -lt $script:Config.LowDiskFreePercentWarning) -or ($Hardware.SystemDriveFreeGB -ne $null -and $Hardware.SystemDriveFreeGB -lt $script:Config.LowDiskFreeGBWarning))
            PhysicalDiskHealth       = $Hardware.PhysicalDiskHealth
            StorageReliability       = $reliability
            DiskRelatedEventCount    = @($EventLogs.DiskErrors).Count
            NTFSEventCount           = @($EventLogs.NTFSErrors).Count
            WHEAEventCount           = @($EventLogs.WHEAErrors).Count
            Battery                  = $Hardware.Battery
            BatteryAvailable         = @($Hardware.Battery).Count -gt 0
        }
    }
}
#endregion Collection Functions

#region Analysis Functions
function New-Finding {
    param(
        [string]$Category,
        [ValidateSet('Critical','Warning')][string]$Severity,
        [string]$Title,
        [string]$Description,
        [string]$Evidence,
        [string]$RecommendedAction
    )
    [pscustomobject]@{
        Category          = $Category
        Severity          = $Severity
        Title             = $Title
        Description       = $Description
        Evidence          = $Evidence
        RecommendedAction = $RecommendedAction
    }
}

function Invoke-EndpointAnalysis {
    param([pscustomobject]$Report)

    $critical = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList

    if ($Report.Device.PendingReboot) {
        [void]$warnings.Add((New-Finding 'Device' 'Warning' 'Pending reboot detected' 'The endpoint has one or more reboot indicators present.' (ConvertTo-DisplayJson $Report.Device.PendingRebootDetails) 'Reboot the device before continuing with update or app deployment troubleshooting.'))
    }
    if (-not $Report.Device.IsAdministrator) {
        [void]$warnings.Add((New-Finding 'Execution' 'Warning' 'Application is not elevated' 'The scan is running without local administrator rights, so some data may be incomplete.' $Report.Device.RunningAccount 'Rerun PowerShell as administrator for a complete scan.'))
    }
    if ($Report.Hardware.BIOSAgeWarning) {
        [void]$warnings.Add((New-Finding 'Firmware' 'Warning' 'BIOS is older than configured threshold' "BIOS age is greater than $($script:Config.BiosAgeWarningDays) days." "BIOS date: $($Report.Hardware.BIOSReleaseDate); age: $($Report.Hardware.BIOSAgeDays) days" 'Review OEM firmware update guidance and update BIOS where appropriate.'))
    }
    if ($Report.DiskHardware.LowDiskSpace) {
        [void]$critical.Add((New-Finding 'Disk' 'Critical' 'Low system drive free space' 'The system drive is below the configured free space threshold.' "$($Report.DiskHardware.SystemDriveFreeGB) GB free; $($Report.DiskHardware.SystemDriveFreePercent)% free" 'Free disk space, remove stale content, and verify Windows Update cache health.'))
    }
    if ($Report.WindowsUpdate.FailedWindowsUpdateEventCount -gt 0) {
        [void]$critical.Add((New-Finding 'Windows Update' 'Critical' 'Recent Windows Update failures detected' 'Windows Update Client logged recent failures.' "$($Report.WindowsUpdate.FailedWindowsUpdateEventCount) failed update events in the lookback window" 'Review WindowsUpdateClient operational events and policy source, then repair Windows Update components if needed.'))
    }
    if ($Report.WindowsUpdate.MissingRecentUpdateActivity) {
        [void]$warnings.Add((New-Finding 'Windows Update' 'Warning' 'Missing recent update activity' 'No recent Windows Update activity was found within the configured activity window.' "Last activity: $($Report.WindowsUpdate.LastWindowsUpdateScan)" 'Confirm update policy source, network access to update endpoints, and scheduled scan behavior.'))
    }
    if (@($Report.EventLogs.BugCheckEvents).Count -gt 0) {
        [void]$critical.Add((New-Finding 'Stability' 'Critical' 'BugCheck events detected' 'The device recorded crash events during the event lookback window.' "$(@($Report.EventLogs.BugCheckEvents).Count) BugCheck events" 'Review memory dump files, driver versions, firmware, and hardware reliability.'))
    }
    if (@($Report.EventLogs.UnexpectedShutdowns).Count -gt 0) {
        [void]$critical.Add((New-Finding 'Stability' 'Critical' 'Unexpected shutdowns detected' 'Kernel-Power unexpected shutdown events were found.' "$(@($Report.EventLogs.UnexpectedShutdowns).Count) unexpected shutdown events" 'Check power, thermal, firmware, battery, driver, and crash dump evidence.'))
    }
    if (@($Report.EventLogs.WHEAErrors).Count -gt 0) {
        [void]$critical.Add((New-Finding 'Hardware' 'Critical' 'WHEA hardware errors detected' 'Windows Hardware Error Architecture events indicate possible hardware or firmware instability.' "$(@($Report.EventLogs.WHEAErrors).Count) WHEA events" 'Update firmware and drivers, run OEM diagnostics, and inspect CPU, memory, PCIe, and storage health.'))
    }
    if (@($Report.EventLogs.DiskErrors).Count -gt 0) {
        [void]$critical.Add((New-Finding 'Disk' 'Critical' 'Disk or storage errors detected' 'Recent disk/storage provider errors were found.' "$(@($Report.EventLogs.DiskErrors).Count) disk-related events" 'Check SMART/storage health, cabling where applicable, firmware, and file system integrity.'))
    }
    if (@($Report.EventLogs.NTFSErrors).Count -gt 0) {
        [void]$critical.Add((New-Finding 'Disk' 'Critical' 'NTFS errors detected' 'NTFS provider errors were found in recent event logs.' "$(@($Report.EventLogs.NTFSErrors).Count) NTFS events" 'Run file system checks and investigate underlying storage health.'))
    }
    if ($Report.Intune.IMEServiceStatus -notin @('Running')) {
        $severity = if ($Report.Device.IntuneEnrollmentLikely) { 'Critical' } else { 'Warning' }
        $target = if ($severity -eq 'Critical') { $critical } else { $warnings }
        [void]$target.Add((New-Finding 'Intune' $severity 'Intune Management Extension service is not running' 'IME service is missing or not running.' "Service status: $($Report.Intune.IMEServiceStatus)" 'Restart or reinstall the Intune Management Extension and confirm the device is correctly enrolled.'))
    }
    if ($Report.Device.IntuneEnrollmentLikely -and -not $Report.Intune.IMELogFolderExists) {
        [void]$critical.Add((New-Finding 'Intune' 'Critical' 'IME logs missing on likely Intune-enrolled device' 'MDM enrollment indicators exist, but the IME log folder was not found.' $Report.Intune.IMELogFolder 'Confirm Win32 app management enrollment and Intune Management Extension installation.'))
    }
    if ($Report.DriversFirmware.ProblemPnpDeviceCount -gt 0) {
        [void]$warnings.Add((New-Finding 'Drivers' 'Warning' 'Problematic PnP devices detected' 'One or more present PnP devices are not reporting an OK status.' "$($Report.DriversFirmware.ProblemPnpDeviceCount) devices" 'Review Device Manager, driver package health, and vendor driver updates.'))
    }
    foreach ($section in @($Report.Metadata.FailedSections)) {
        [void]$warnings.Add((New-Finding 'Scan' 'Warning' "Scan section failed: $($section.Section)" 'A scan section could not be completed, but the scan continued.' $section.Error 'Rerun as administrator and inspect the application log for details.'))
    }

    $Report.CriticalFindings = @($critical)
    $Report.Warnings = @($warnings)
    return $Report
}
#endregion Analysis Functions

#region Health Score Functions
function Get-HealthCategory {
    param([int]$Score)
    if ($Score -ge 90) { return 'Healthy' }
    if ($Score -ge 70) { return 'Needs attention' }
    if ($Score -ge 40) { return 'Problematic' }
    return 'Critical'
}

function Get-HealthScore {
    param([pscustomobject]$Report)
    $score = 100
    $deductions = New-Object System.Collections.ArrayList
    $deduct = {
        param([string]$Reason, [int]$Points)
        if ($Points -gt 0) {
            [void]$deductions.Add([pscustomobject]@{ Reason = $Reason; Points = $Points })
        }
    }

    if ($Report.Device.PendingReboot) { & $deduct 'Pending reboot' $script:Config.ScoreDeductions.PendingReboot }
    if ($Report.Hardware.BIOSAgeWarning) { & $deduct 'Old BIOS' $script:Config.ScoreDeductions.OldBios }
    if ($Report.DiskHardware.LowDiskSpace) { & $deduct 'Low disk space' $script:Config.ScoreDeductions.LowDiskSpace }
    if ($Report.WindowsUpdate.FailedWindowsUpdateEventCount -gt 0) { & $deduct 'Windows Update failures' $script:Config.ScoreDeductions.WindowsUpdateFailures }
    if ($Report.WindowsUpdate.MissingRecentUpdateActivity) { & $deduct 'Missing recent update activity' $script:Config.ScoreDeductions.MissingUpdateActivity }
    if ($Report.EventLogs.CriticalEventCount -gt 0) { & $deduct 'Critical system/application events' $script:Config.ScoreDeductions.CriticalSystemEvents }
    if (@($Report.EventLogs.BugCheckEvents).Count -gt 0) { & $deduct 'BugCheck events' $script:Config.ScoreDeductions.BugCheckEvents }
    if (@($Report.EventLogs.UnexpectedShutdowns).Count -gt 0) { & $deduct 'Unexpected shutdowns' $script:Config.ScoreDeductions.UnexpectedShutdowns }
    if (@($Report.EventLogs.WHEAErrors).Count -gt 0) { & $deduct 'WHEA errors' $script:Config.ScoreDeductions.WHEAErrors }
    if (@($Report.EventLogs.DiskErrors).Count -gt 0) { & $deduct 'Disk errors' $script:Config.ScoreDeductions.DiskErrors }
    if (@($Report.EventLogs.NTFSErrors).Count -gt 0) { & $deduct 'NTFS errors' $script:Config.ScoreDeductions.NTFSErrors }
    if ($Report.Intune.IMEServiceStatus -ne 'Running' -and $Report.Device.IntuneEnrollmentLikely) { & $deduct 'IME service not running' $script:Config.ScoreDeductions.IMEServiceNotRunning }
    if ($Report.Device.IntuneEnrollmentLikely -and -not $Report.Intune.IMELogFolderExists) { & $deduct 'Missing IME logs' $script:Config.ScoreDeductions.MissingIMELogs }
    if ($Report.DriversFirmware.ProblemPnpDeviceCount -gt 0) { & $deduct 'Problematic PnP devices' $script:Config.ScoreDeductions.ProblemPnpDevices }
    foreach ($section in @($Report.Metadata.FailedSections)) { & $deduct "Failed scan section: $($section.Section)" $script:Config.ScoreDeductions.FailedScanSection }

    $score = 100 - (@($deductions) | Measure-Object -Property Points -Sum).Sum
    $final = [math]::Max(0, [math]::Min(100, $score))
    [pscustomobject]@{
        Score      = [int]$final
        Category   = Get-HealthCategory -Score $final
        Deductions = @($deductions)
        Rules      = $script:Config.ScoreDeductions
    }
}
#endregion Health Score Functions

#region HTML Report Functions
function ConvertTo-HtmlEncoded {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-HtmlTable {
    param($InputObject)
    $rows = New-Object System.Collections.ArrayList
    if ($null -eq $InputObject) { return '<p class="small">No data available.</p>' }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        foreach ($item in @($InputObject)) {
            if ($null -eq $item) { continue }
            $props = $item.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' }
            $cells = foreach ($p in $props) { '<td>{0}</td>' -f (ConvertTo-HtmlEncoded (($p.Value | Out-String).Trim())) }
            [void]$rows.Add('<tr>{0}</tr>' -f ($cells -join ''))
        }
        $first = @($InputObject | Select-Object -First 1)
        if ($first.Count -eq 0) { return '<p class="small">No rows found.</p>' }
        $headers = $first[0].PSObject.Properties | Where-Object { $_.MemberType -match 'Property' } | ForEach-Object { '<th>{0}</th>' -f (ConvertTo-HtmlEncoded $_.Name) }
        return '<table><thead><tr>{0}</tr></thead><tbody>{1}</tbody></table>' -f ($headers -join ''), ($rows -join '')
    }

    foreach ($p in $InputObject.PSObject.Properties) {
        if ($p.Name -match '^PS') { continue }
        $value = if ($p.Value -is [System.Collections.IEnumerable] -and -not ($p.Value -is [string])) { ConvertTo-DisplayJson $p.Value } else { $p.Value }
        [void]$rows.Add('<tr><th>{0}</th><td>{1}</td></tr>' -f (ConvertTo-HtmlEncoded $p.Name), (ConvertTo-HtmlEncoded (($value | Out-String).Trim())))
    }
    '<table><tbody>{0}</tbody></table>' -f ($rows -join '')
}

function Convert-FindingsToHtml {
    param($Findings, [bool]$Critical)
    if (@($Findings).Count -eq 0) { return '<p class="small">None detected.</p>' }
    $class = if ($Critical) { 'finding criticalFinding' } else { 'finding' }
    (@($Findings) | ForEach-Object {
        '<article class="{0}"><h3>{1}</h3><p><strong>{2}</strong> | {3}</p><p>{4}</p><div class="evidence">{5}</div><p><strong>Recommended action:</strong> {6}</p></article>' -f
            $class,
            (ConvertTo-HtmlEncoded $_.Title),
            (ConvertTo-HtmlEncoded $_.Category),
            (ConvertTo-HtmlEncoded $_.Severity),
            (ConvertTo-HtmlEncoded $_.Description),
            (ConvertTo-HtmlEncoded $_.Evidence),
            (ConvertTo-HtmlEncoded $_.RecommendedAction)
    }) -join "`n"
}

function Convert-EventsToHtml {
    param([pscustomobject]$EventLogs)
    $html = New-Object System.Collections.ArrayList
    foreach ($channel in @($EventLogs.Channels)) {
        [void]$html.Add("<details><summary>$(ConvertTo-HtmlEncoded $channel.LogName) - Critical $($channel.Counts.Critical), Error $($channel.Counts.Error), Warning $($channel.Counts.Warning)</summary>")
        if (-not $channel.Exists) {
            [void]$html.Add('<p class="small">Channel not present on this device.</p></details>')
            continue
        }
        if (@($channel.Events).Count -eq 0) {
            [void]$html.Add('<p class="small">No matching recent events.</p></details>')
            continue
        }
        $rows = @($channel.Events | Select-Object TimeCreated,Id,LevelDisplay,ProviderName,Message | ForEach-Object {
            '<tr class="eventRow"><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f (ConvertTo-HtmlEncoded $_.TimeCreated), $_.Id, (ConvertTo-HtmlEncoded $_.LevelDisplay), (ConvertTo-HtmlEncoded $_.ProviderName), (ConvertTo-HtmlEncoded $_.Message)
        })
        [void]$html.Add('<table><thead><tr><th>Time</th><th>ID</th><th>Level</th><th>Provider</th><th>Message</th></tr></thead><tbody>')
        [void]$html.Add(($rows -join "`n"))
        [void]$html.Add('</tbody></table></details>')
    }
    $html -join "`n"
}

function Get-CategoryClass {
    param([string]$Category)
    switch ($Category) {
        'Healthy' { 'healthy' }
        'Needs attention' { 'attention' }
        'Problematic' { 'problem' }
        default { 'critical' }
    }
}

function New-HtmlReport {
    param([pscustomobject]$Report)
    Invoke-SafeSection -Name 'HTML report' -DefaultValue $null -ScriptBlock {
        if (-not (Test-Path -LiteralPath $script:TemplatePath)) {
            throw "ReportTemplate.html was not found at $script:TemplatePath"
        }
        $template = Get-Content -LiteralPath $script:TemplatePath -Raw
        $rawJson = $Report | ConvertTo-Json -Depth 12
        $summary = @"
<p><strong>$($Report.Device.ComputerName)</strong> scored <strong>$($Report.HealthScore.Score)</strong> and is categorized as <strong>$($Report.HealthScore.Category)</strong>.</p>
<p>The scan found <strong>$(@($Report.CriticalFindings).Count)</strong> critical findings and <strong>$(@($Report.Warnings).Count)</strong> warnings across update, Intune, driver, firmware, event log, disk, and hardware checks.</p>
"@
        $windowsUpdateHtml = '<details open><summary>Windows Update summary</summary>{0}</details><details><summary>Pending updates</summary>{1}</details><details><summary>Policy/source registry values</summary>{2}</details><details><summary>Failed update events</summary>{3}</details>' -f (ConvertTo-HtmlTable ($Report.WindowsUpdate | Select-Object LastWindowsUpdateScan,LastSuccessfulUpdateInstallation,PendingUpdateCount,FailedWindowsUpdateEventCount,MissingRecentUpdateActivity)), (ConvertTo-HtmlTable $Report.WindowsUpdate.PendingUpdates), (ConvertTo-HtmlTable $Report.WindowsUpdate.WindowsUpdatePolicySourceRegistry), (ConvertTo-HtmlTable $Report.WindowsUpdate.FailedWindowsUpdateEvents)
        $intuneHtml = '<details open><summary>Intune summary</summary>{0}</details><details><summary>IME log files</summary>{1}</details><details><summary>Expected IME logs</summary>{2}</details><details><summary>DeviceManagement events</summary>{3}</details>' -f (ConvertTo-HtmlTable ($Report.Intune | Select-Object IMEServiceStatus,IMEServiceStartType,IMELogFolderExists,LatestIMELogModified,AutopilotEventChannelPresent)), (ConvertTo-HtmlTable $Report.Intune.RecentIMELogFiles), (ConvertTo-HtmlTable $Report.Intune.ExpectedIMELogs), (ConvertTo-HtmlTable $Report.Intune.DeviceManagementEvents.Events)
        $driversHtml = '<details open><summary>Firmware</summary>{0}</details><details><summary>Problem PnP devices</summary>{1}</details><details><summary>Display adapters</summary>{2}</details><details><summary>Network adapters</summary>{3}</details><details><summary>Storage controllers</summary>{4}</details><details><summary>System/chipset devices</summary>{5}</details>' -f (ConvertTo-HtmlTable ($Report.DriversFirmware | Select-Object BIOSVersion,BIOSReleaseDate,BIOSAgeDays,BIOSAgeWarning,ProblemPnpDeviceCount)), (ConvertTo-HtmlTable $Report.DriversFirmware.ProblemPnpDevices), (ConvertTo-HtmlTable $Report.DriversFirmware.DisplayAdapters), (ConvertTo-HtmlTable $Report.DriversFirmware.NetworkAdapters), (ConvertTo-HtmlTable $Report.DriversFirmware.StorageControllers), (ConvertTo-HtmlTable $Report.DriversFirmware.SystemChipsetDevices)
        $diskHtml = '<details open><summary>Disk health summary</summary>{0}</details><details><summary>Physical disk health</summary>{1}</details><details><summary>SMART/storage reliability</summary>{2}</details><details><summary>Battery</summary>{3}</details>' -f (ConvertTo-HtmlTable ($Report.DiskHardware | Select-Object SystemDriveFreeGB,SystemDriveFreePercent,LowDiskSpace,DiskRelatedEventCount,NTFSEventCount,WHEAEventCount,BatteryAvailable)), (ConvertTo-HtmlTable $Report.DiskHardware.PhysicalDiskHealth), (ConvertTo-HtmlTable $Report.DiskHardware.StorageReliability), (ConvertTo-HtmlTable $Report.DiskHardware.Battery)
        $comparisonHtml = if ($Report.Comparison -and $Report.Comparison.Results) { ConvertTo-HtmlTable $Report.Comparison.Results } else { '<p class="small">No baseline comparison has been run.</p>' }

        $replacements = @{
            '__GENERATED__'          = ConvertTo-HtmlEncoded $Report.Metadata.GeneratedAt
            '__COMPUTER__'           = ConvertTo-HtmlEncoded $Report.Device.ComputerName
            '__CATEGORY__'           = ConvertTo-HtmlEncoded $Report.HealthScore.Category
            '__CATEGORY_CLASS__'     = Get-CategoryClass $Report.HealthScore.Category
            '__SCORE__'              = [string]$Report.HealthScore.Score
            '__CRITICAL_COUNT__'     = [string]@($Report.CriticalFindings).Count
            '__WARNING_COUNT__'      = [string]@($Report.Warnings).Count
            '__UPTIME__'             = ConvertTo-HtmlEncoded $Report.Device.Uptime
            '__EXECUTIVE_SUMMARY__'  = $summary
            '__CRITICAL_FINDINGS__'  = Convert-FindingsToHtml $Report.CriticalFindings $true
            '__WARNINGS__'           = Convert-FindingsToHtml $Report.Warnings $false
            '__DEVICE_TABLE__'       = ConvertTo-HtmlTable $Report.Device
            '__HARDWARE_TABLE__'     = ConvertTo-HtmlTable $Report.Hardware
            '__WINDOWS_UPDATE__'     = $windowsUpdateHtml
            '__INTUNE__'             = $intuneHtml
            '__DRIVERS__'            = $driversHtml
            '__EVENTS__'             = Convert-EventsToHtml $Report.EventLogs
            '__DISK__'               = $diskHtml
            '__COMPARISON__'         = $comparisonHtml
            '__RAW_JSON__'           = ConvertTo-HtmlEncoded $rawJson
            '__METADATA_TABLE__'     = ConvertTo-HtmlTable $Report.Metadata
        }
        foreach ($key in $replacements.Keys) {
            $template = $template.Replace($key, [string]$replacements[$key])
        }
        Set-Content -LiteralPath $script:ReportPath -Value $template -Encoding UTF8
        return $script:ReportPath
    }
}
#endregion HTML Report Functions

#region JSON Export Functions
function Export-JsonReport {
    param([pscustomobject]$Report)
    Invoke-SafeSection -Name 'JSON report' -DefaultValue $null -ScriptBlock {
        $Report | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $script:JsonReportPath -Encoding UTF8
        return $script:JsonReportPath
    }
}
#endregion JSON Export Functions

#region Baseline Comparison Functions
function Get-DriverMap {
    param($DriversFirmware)
    $map = @{}
    foreach ($collectionName in @('DisplayAdapters','NetworkAdapters','StorageControllers','SystemChipsetDevices')) {
        foreach ($driver in @($DriversFirmware.$collectionName)) {
            if ($driver.DeviceName) {
                $map["$collectionName::$($driver.DeviceName)"] = $driver.DriverVersion
            }
        }
    }
    return $map
}

function Add-ComparisonResult {
    param($List, [string]$Item, $Baseline, $Current)
    $status = if ([string]$Baseline -eq [string]$Current) { 'Same' } else { 'Changed' }
    [void]$List.Add([pscustomobject]@{ Item = $Item; Baseline = $Baseline; Current = $Current; Status = $status })
}

function Compare-EndpointBaseline {
    param([pscustomobject]$Baseline, [pscustomobject]$Current)
    $results = New-Object System.Collections.ArrayList
    Add-ComparisonResult $results 'Manufacturer' $Baseline.Hardware.Manufacturer $Current.Hardware.Manufacturer
    Add-ComparisonResult $results 'Model' $Baseline.Hardware.Model $Current.Hardware.Model
    Add-ComparisonResult $results 'OS version' $Baseline.Device.OSVersion $Current.Device.OSVersion
    Add-ComparisonResult $results 'OS build' $Baseline.Device.OSBuild $Current.Device.OSBuild
    Add-ComparisonResult $results 'BIOS version' $Baseline.Hardware.BIOSVersion $Current.Hardware.BIOSVersion
    Add-ComparisonResult $results 'BIOS release date' $Baseline.Hardware.BIOSReleaseDate $Current.Hardware.BIOSReleaseDate
    Add-ComparisonResult $results 'Windows Update failed event count' $Baseline.WindowsUpdate.FailedWindowsUpdateEventCount $Current.WindowsUpdate.FailedWindowsUpdateEventCount
    Add-ComparisonResult $results 'Windows Update pending update count' $Baseline.WindowsUpdate.PendingUpdateCount $Current.WindowsUpdate.PendingUpdateCount
    Add-ComparisonResult $results 'IME service status' $Baseline.Intune.IMEServiceStatus $Current.Intune.IMEServiceStatus
    Add-ComparisonResult $results 'Pending reboot' $Baseline.Device.PendingReboot $Current.Device.PendingReboot
    Add-ComparisonResult $results 'System drive free GB' $Baseline.DiskHardware.SystemDriveFreeGB $Current.DiskHardware.SystemDriveFreeGB
    Add-ComparisonResult $results 'Event error count' $Baseline.EventLogs.ErrorEventCount $Current.EventLogs.ErrorEventCount
    Add-ComparisonResult $results 'Critical finding count' @($Baseline.CriticalFindings).Count @($Current.CriticalFindings).Count
    Add-ComparisonResult $results 'Warning count' @($Baseline.Warnings).Count @($Current.Warnings).Count

    $baselineDrivers = Get-DriverMap $Baseline.DriversFirmware
    $currentDrivers = Get-DriverMap $Current.DriversFirmware
    foreach ($key in @($baselineDrivers.Keys + $currentDrivers.Keys | Sort-Object -Unique)) {
        Add-ComparisonResult $results "Driver: $key" $baselineDrivers[$key] $currentDrivers[$key]
    }

    [pscustomobject]@{
        ComparedAt = Get-Date
        BaselineComputer = $Baseline.Device.ComputerName
        CurrentComputer = $Current.Device.ComputerName
        ChangedCount = @($results | Where-Object { $_.Status -eq 'Changed' }).Count
        Results = @($results)
    }
}

function Export-Baseline {
    if (-not $script:CurrentReport) { return }
    try {
        $script:CurrentReport | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $script:BaselinePath -Encoding UTF8
        Set-GuiStatus -Status "Baseline exported to $script:BaselinePath" -Progress 100
        Write-ToLog -Message "Baseline exported to $script:BaselinePath"
    } catch {
        [System.Windows.MessageBox]::Show("Failed to export baseline: $($_.Exception.Message)", $script:AppName, 'OK', 'Error') | Out-Null
        Write-ToLog -Message "Failed to export baseline: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Load-Baseline {
    try {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.InitialDirectory = $script:DataPath
        $dialog.Filter = 'JSON files (*.json)|*.json|All files (*.*)|*.*'
        $dialog.FileName = 'Baseline.json'
        if ($dialog.ShowDialog()) {
            $script:LoadedBaseline = Get-Content -LiteralPath $dialog.FileName -Raw | ConvertFrom-Json
            $script:Controls.CompareBaselineButton.IsEnabled = $null -ne $script:CurrentReport
            $script:Controls.ComparisonText.Text = "Loaded baseline: $($dialog.FileName)"
            Write-ToLog -Message "Baseline loaded from $($dialog.FileName)"
        }
    } catch {
        [System.Windows.MessageBox]::Show("Failed to load baseline: $($_.Exception.Message)", $script:AppName, 'OK', 'Error') | Out-Null
        Write-ToLog -Message "Failed to load baseline: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Compare-BaselineFromGui {
    if (-not $script:CurrentReport) { return }
    if (-not $script:LoadedBaseline) {
        if (Test-Path -LiteralPath $script:BaselinePath) {
            $script:LoadedBaseline = Get-Content -LiteralPath $script:BaselinePath -Raw | ConvertFrom-Json
        } else {
            [System.Windows.MessageBox]::Show('Load or export a baseline before comparing.', $script:AppName, 'OK', 'Information') | Out-Null
            return
        }
    }
    try {
        $script:CurrentReport.Comparison = Compare-EndpointBaseline -Baseline $script:LoadedBaseline -Current $script:CurrentReport
        Export-JsonReport -Report $script:CurrentReport | Out-Null
        New-HtmlReport -Report $script:CurrentReport | Out-Null
        Update-GuiWithReport -Report $script:CurrentReport
        Set-GuiStatus -Status "Baseline comparison completed. Changed items: $($script:CurrentReport.Comparison.ChangedCount)" -Progress 100
    } catch {
        [System.Windows.MessageBox]::Show("Comparison failed: $($_.Exception.Message)", $script:AppName, 'OK', 'Error') | Out-Null
        Write-ToLog -Message "Comparison failed: $($_.Exception.Message)" -Level 'ERROR'
    }
}
#endregion Baseline Comparison Functions

#region Main Execution
function New-EndpointReport {
    $script:FailedSections = New-Object System.Collections.ArrayList
    $metadata = [pscustomobject]@{
        ToolName       = $script:AppName
        ToolVersion    = $script:AppVersion
        GeneratedAt    = Get-Date
        RunningUser    = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        IsAdministrator = Test-IsAdmin
        EventLookbackDays = $script:Config.EventLookbackDays
        OutputFolder   = $script:RootPath
        FailedSections = @()
    }

    Set-GuiStatus 'Collecting device identity...' 8
    $device = Get-DeviceIdentity
    Set-GuiStatus 'Collecting hardware inventory...' 18
    $hardware = Get-EndpointHardware
    Set-GuiStatus 'Collecting Windows Update health...' 32
    $windowsUpdate = Get-WindowsUpdateData
    Set-GuiStatus 'Collecting Intune diagnostics...' 46
    $intune = Get-IntuneData
    Set-GuiStatus 'Collecting driver and firmware data...' 60
    $drivers = Get-DriversFirmwareData -Hardware $hardware
    Set-GuiStatus 'Analyzing event logs...' 74
    $events = Get-EventLogAnalysis
    Set-GuiStatus 'Checking disk and hardware health...' 84
    $diskHardware = Get-DiskHardwareHealth -Hardware $hardware -EventLogs $events

    $metadata.FailedSections = @($script:FailedSections)
    $report = [pscustomobject]@{
        Metadata        = $metadata
        Device          = $device
        Hardware        = $hardware
        WindowsUpdate   = $windowsUpdate
        Intune          = $intune
        DriversFirmware = $drivers
        EventLogs       = $events
        DiskHardware    = $diskHardware
        HealthScore     = $null
        CriticalFindings = @()
        Warnings        = @()
        Comparison      = [pscustomobject]@{ Status = 'Not compared'; Results = @() }
        RawData         = [pscustomobject]@{
            FailedSections = @($script:FailedSections)
        }
    }

    Set-GuiStatus 'Analyzing findings and calculating health score...' 92
    $report = Invoke-EndpointAnalysis -Report $report
    $report.HealthScore = Get-HealthScore -Report $report
    return $report
}

function Start-ScanWorkflow {
    if ($script:ScanProcess -and -not $script:ScanProcess.HasExited) {
        Set-GuiStatus 'A scan is already running.' 0
        return
    }

    Set-ButtonsForScan -IsScanning $true
    Write-ToLog -Message '============================================================'
    Write-ToLog -Message 'Scan process launch requested'
    Write-ToLog -Message "Running user: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    try {
        if (Test-Path -LiteralPath $script:ProgressPath) {
            Remove-Item -LiteralPath $script:ProgressPath -Force -ErrorAction SilentlyContinue
        }
        Set-GuiStatus 'Starting background scan process...' 2

        $arguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"",
            '-SilentScan'
        )
        $script:ScanProcess = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
        Write-ToLog -Message "Background scan process started. PID: $($script:ScanProcess.Id)"
        Start-ScanProgressMonitor
    } catch {
        Write-ToLog -Message "Unable to start scan process: $($_.Exception.Message)" -Level 'ERROR'
        [System.Windows.MessageBox]::Show("Unable to start scan process: $($_.Exception.Message)", $script:AppName, 'OK', 'Error') | Out-Null
        Set-GuiStatus 'Scan could not be started. Review the log for details.' 0
        Set-ButtonsForScan -IsScanning $false
    }
}

function Start-ScanProgressMonitor {
    if ($script:ScanTimer) {
        $script:ScanTimer.Stop()
    }

    $script:ScanTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ScanTimer.Interval = [TimeSpan]::FromMilliseconds(750)
    $script:ScanTimer.Add_Tick({
        try {
            if (Test-Path -LiteralPath $script:ProgressPath) {
                $progress = Get-Content -LiteralPath $script:ProgressPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($progress) {
                    $script:Controls.StatusText.Text = $progress.Status
                    $script:Controls.ScanProgressBar.Value = [int]$progress.Progress
                }
            }

            if ($script:ScanProcess -and $script:ScanProcess.HasExited) {
                $script:ScanTimer.Stop()
                Complete-BackgroundScan
            }
        } catch {
            Write-ToLog -Message "Progress monitor warning: $($_.Exception.Message)" -Level 'WARN'
        }
    })
    $script:ScanTimer.Start()
}

function Complete-BackgroundScan {
    try {
        $exitCode = $script:ScanProcess.ExitCode
        Write-ToLog -Message "Background scan process exited with code $exitCode"
        if ($exitCode -ne 0) {
            Set-GuiStatus "Scan process failed with exit code $exitCode. Review the log." 0
            [System.Windows.MessageBox]::Show("The background scan process failed with exit code $exitCode. Review $script:LogPath for details.", $script:AppName, 'OK', 'Error') | Out-Null
            return
        }

        if (-not (Test-Path -LiteralPath $script:JsonReportPath)) {
            Set-GuiStatus 'Scan finished, but the JSON report was not found.' 0
            [System.Windows.MessageBox]::Show("The scan finished, but $script:JsonReportPath was not found.", $script:AppName, 'OK', 'Error') | Out-Null
            return
        }

        $script:CurrentReport = Get-Content -LiteralPath $script:JsonReportPath -Raw | ConvertFrom-Json
        Update-GuiWithReport -Report $script:CurrentReport
        Set-GuiStatus "Scan complete. Report saved to $script:ReportPath" 100
    } catch {
        Write-ToLog -Message "Unable to complete background scan: $($_.Exception.Message)" -Level 'ERROR'
        [System.Windows.MessageBox]::Show("Unable to load scan results: $($_.Exception.Message)", $script:AppName, 'OK', 'Error') | Out-Null
        Set-GuiStatus 'Scan completed, but result loading failed. Review the log.' 0
    } finally {
        Set-ButtonsForScan -IsScanning $false
        Write-ToLog -Message 'Scan ended'
    }
}

function Open-FileWithShell {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File was not found: $Path"
    }

    try {
        Start-Process -FilePath $Path -ErrorAction Stop
    } catch {
        Write-ToLog -Message "Direct shell open failed for $Path. Trying explorer.exe. Error: $($_.Exception.Message)" -Level 'WARN'
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Path`"" -ErrorAction Stop
    }
}

function Ensure-HtmlReportExists {
    if (Test-Path -LiteralPath $script:ReportPath) {
        return $true
    }

    Write-ToLog -Message "HTML report missing at $script:ReportPath" -Level 'WARN'
    if (-not $script:CurrentReport -and (Test-Path -LiteralPath $script:JsonReportPath)) {
        try {
            $script:CurrentReport = Get-Content -LiteralPath $script:JsonReportPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-ToLog -Message "Unable to load JSON report while regenerating HTML: $($_.Exception.Message)" -Level 'ERROR'
        }
    }

    if ($script:CurrentReport) {
        try {
            Write-ToLog -Message 'Regenerating missing HTML report from current JSON data'
            New-HtmlReport -Report $script:CurrentReport | Out-Null
        } catch {
            Write-ToLog -Message "Unable to regenerate HTML report: $($_.Exception.Message)" -Level 'ERROR'
        }
    }

    return (Test-Path -LiteralPath $script:ReportPath)
}

function Invoke-SilentScan {
    Write-ToLog -Message '============================================================'
    Write-ToLog -Message 'Silent/background scan started'
    Write-ToLog -Message "Running user: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    try {
        $report = New-EndpointReport
        Set-GuiStatus 'Writing JSON report...' 96
        Export-JsonReport -Report $report | Out-Null
        Set-GuiStatus 'Generating HTML report...' 98
        New-HtmlReport -Report $report | Out-Null
        Set-GuiStatus "Scan complete. Report saved to $script:ReportPath" 100
        Write-ToLog -Message "Silent/background scan completed. Score: $($report.HealthScore.Score) $($report.HealthScore.Category)"
        exit 0
    } catch {
        Write-ToLog -Message "Silent/background scan failed unexpectedly: $($_.Exception.Message)" -Level 'ERROR'
        Set-GuiStatus 'Scan failed. Review the log for details.' 0
        exit 1
    } finally {
        Write-ToLog -Message 'Silent/background scan ended'
    }
}

function Open-Report {
    Write-ToLog -Message 'Open report button clicked'
    try {
        if (Ensure-HtmlReportExists) {
            Open-FileWithShell -Path $script:ReportPath
            Write-ToLog -Message "Opened HTML report: $script:ReportPath"
        } else {
            [System.Windows.MessageBox]::Show("No HTML report was found at:`n$script:ReportPath`n`nRun a scan first, or review the log for report generation errors.", $script:AppName, 'OK', 'Information') | Out-Null
            Write-ToLog -Message "Open report failed because report is missing: $script:ReportPath" -Level 'WARN'
        }
    } catch {
        Write-ToLog -Message "Open report failed: $($_.Exception.Message)" -Level 'ERROR'
        [System.Windows.MessageBox]::Show("Could not open the report:`n$($_.Exception.Message)", $script:AppName, 'OK', 'Error') | Out-Null
    }
}

function Export-HtmlReportCopy {
    Write-ToLog -Message 'Export HTML report button clicked'
    if (-not (Ensure-HtmlReportExists)) {
        [System.Windows.MessageBox]::Show("No HTML report was found at:`n$script:ReportPath`n`nRun a scan first, or review the log for report generation errors.", $script:AppName, 'OK', 'Information') | Out-Null
        Write-ToLog -Message "Export report failed because report is missing: $script:ReportPath" -Level 'WARN'
        return
    }
    try {
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.InitialDirectory = $script:ReportsPath
        $dialog.Filter = 'HTML files (*.html)|*.html|All files (*.*)|*.*'
        $dialog.FileName = "ecHealthReport-$env:COMPUTERNAME.html"
        if ($dialog.ShowDialog()) {
            Copy-Item -LiteralPath $script:ReportPath -Destination $dialog.FileName -Force
            Set-GuiStatus -Status "HTML report exported to $($dialog.FileName)" -Progress 100
            Write-ToLog -Message "HTML report exported to $($dialog.FileName)"
        } else {
            Write-ToLog -Message 'HTML report export dialog was cancelled'
        }
    } catch {
        [System.Windows.MessageBox]::Show("Failed to export report: $($_.Exception.Message)", $script:AppName, 'OK', 'Error') | Out-Null
        Write-ToLog -Message "Failed to export report: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Open-Logs {
    Write-ToLog -Message 'Open logs button clicked'
    try {
        if (-not (Test-Path -LiteralPath $script:LogPath)) {
            New-Item -Path $script:LogPath -ItemType File -Force | Out-Null
        }
        Open-FileWithShell -Path $script:LogPath
    } catch {
        Write-ToLog -Message "Open logs failed: $($_.Exception.Message)" -Level 'ERROR'
        [System.Windows.MessageBox]::Show("Could not open the ecHealth log:`n$($_.Exception.Message)", $script:AppName, 'OK', 'Error') | Out-Null
    }
}

Initialize-AppFolders
if ($SilentScan) {
    Invoke-SilentScan
    return
}

Write-ToLog -Message "Application launched. Version: $script:AppVersion"
try {
    Import-Gui
    if (-not (Test-IsAdmin)) {
        Write-ToLog -Message 'Application is not running as administrator' -Level 'WARN'
        $script:Controls.StatusText.Text = 'Ready. Warning: not running as administrator, some scan sections may be incomplete.'
    }
    [void]$script:Window.ShowDialog()
} catch {
    Write-ToLog -Message "Application startup failed: $($_.Exception.Message)" -Level 'ERROR'
    throw
}
#endregion Main Execution
