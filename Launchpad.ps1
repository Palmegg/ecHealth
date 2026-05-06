<#
ecHealth Launchpad
Downloads the application files from GitHub and starts the WPF scanner.
#>

#region Modifiable Parameters
$RepositoryOwner = 'Palmegg'
$RepositoryName = 'ecHealth'
$RepositoryBranch = 'main'
$InstallPath = 'C:\ProgramData\EndpointHealthAnalyzer\App'
$StartAsAdministrator = $true
$RequiredFiles = @(
    'EndpointHealthAnalyzer.ps1',
    'MainWindow.xaml',
    'ReportTemplate.html',
    'README.md'
)
#endregion Modifiable Parameters

#region Static Variables
$RawBaseUrl = "https://raw.githubusercontent.com/$RepositoryOwner/$RepositoryName/$RepositoryBranch"
$LogRoot = 'C:\ProgramData\EndpointHealthAnalyzer\Logs'
$LaunchpadLogPath = Join-Path $LogRoot 'Launchpad.log'
#endregion Static Variables

#region Helper Functions
function Write-LaunchpadLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    try {
        if (-not (Test-Path -LiteralPath $LogRoot)) {
            New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
        }
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
        Add-Content -LiteralPath $LaunchpadLogPath -Value $line -Encoding UTF8
    } catch {
        # Never let logging block launch.
    }
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Enable-ModernTls {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    } catch {
        Write-LaunchpadLog -Message "Unable to set TLS protocol preference: $($_.Exception.Message)" -Level 'WARN'
    }
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Write-LaunchpadLog -Message "Downloading $Url to $Destination"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "Failed to download $Url. $($_.Exception.Message)"
    }
}
#endregion Helper Functions

#region Main Execution
Write-LaunchpadLog -Message 'Launchpad started'

try {
    Enable-ModernTls

    if ($StartAsAdministrator -and -not (Test-IsAdministrator)) {
        Write-LaunchpadLog -Message 'Relaunching launchpad as administrator'
        Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`""
        ) -Verb RunAs
        return
    }

    if (-not (Test-Path -LiteralPath $InstallPath)) {
        New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
    }

    foreach ($file in $RequiredFiles) {
        $url = "$RawBaseUrl/$file"
        $destination = Join-Path $InstallPath $file
        Invoke-FileDownload -Url $url -Destination $destination
    }

    $appScript = Join-Path $InstallPath 'EndpointHealthAnalyzer.ps1'
    if (-not (Test-Path -LiteralPath $appScript)) {
        throw "Downloaded application script was not found at $appScript"
    }

    Write-LaunchpadLog -Message "Starting ecHealth from $appScript"
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$appScript`""
    )
    Write-LaunchpadLog -Message 'Launchpad completed'
} catch {
    Write-LaunchpadLog -Message $_.Exception.Message -Level 'ERROR'
    Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'ecHealth Launchpad', 'OK', 'Error') | Out-Null
    throw
}
#endregion Main Execution
