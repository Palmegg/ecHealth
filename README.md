# ecHealth

ecHealth is a local Windows troubleshooting application for IT technicians working with Intune-managed endpoints, Windows Update failures, driver and firmware problems, disk or hardware instability, freezing PCs, and general device health issues.

The application uses PowerShell 5.1 with a WPF/XAML interface. It is not console-only. A scan produces a technician-friendly GUI summary, a structured JSON report, and a self-contained HTML report that opens directly from disk like a small local website.

The GUI starts scan work in a separate hidden PowerShell process so the WPF window remains responsive while CIM, event log, Windows Update, Intune, driver, and disk checks run.

## Files

- `EndpointHealthAnalyzer.ps1` - main application and scan engine
- `MainWindow.xaml` - WPF dashboard interface
- `ReportTemplate.html` - self-contained HTML report template
- `README.md` - usage and deployment notes

## Requirements

- Windows PowerShell 5.1
- Windows 10 or Windows 11
- Local administrator rights recommended
- No internet access required
- No external PowerShell modules required

The tool avoids `Win32_Product` and uses built-in Windows cmdlets, CIM/WMI classes, registry checks, and event log queries.

## Run As Administrator

Open an elevated PowerShell prompt in the tool folder and run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\EndpointHealthAnalyzer.ps1
```

The app can run without elevation, but some event logs, TPM data, disk health data, registry locations, and Intune diagnostics may be incomplete.

## Run From GitHub With Launchpad

After the repository is public, a technician can run only `Launchpad.ps1` on a remote PC. The launchpad downloads the required application files to:

```text
C:\ProgramData\EndpointHealthAnalyzer\App
```

Then it starts `EndpointHealthAnalyzer.ps1`.

Example one-liner:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass; irm "https://raw.githubusercontent.com/Palmegg/ecHealth/main/Launchpad.ps1?cacheBust=$(Get-Date -Format yyyyMMddHHmmss)" | iex
```

The launchpad writes its own log to:

```text
C:\ProgramData\EndpointHealthAnalyzer\Logs\Launchpad.log
```

## Start A Scan

1. Launch `EndpointHealthAnalyzer.ps1`.
2. Click **Start Scan**.
3. Watch the progress bar and current status text.
4. Review the health score, critical findings, warnings, and tabbed technical sections.
5. Click **Open report** to view the generated HTML report.

## Output Locations

The application creates:

- `C:\ProgramData\EndpointHealthAnalyzer\Reports\EndpointHealthReport.html`
- `C:\ProgramData\EndpointHealthAnalyzer\Data\EndpointHealthReport.json`
- `C:\ProgramData\EndpointHealthAnalyzer\Data\ScanProgress.json`
- `C:\ProgramData\EndpointHealthAnalyzer\Logs\EndpointHealthAnalyzer.log`
- `C:\ProgramData\EndpointHealthAnalyzer\Data\Baseline.json` when exporting a baseline

## Baseline Export And Comparison

After a scan:

1. Click **Export baseline** to save the current scan as `Baseline.json`.
2. Click **Load baseline** to choose an existing baseline JSON file.
3. Click **Compare with baseline** to compare the current endpoint against the baseline.

The comparison includes manufacturer, model, OS version/build, BIOS version and date, driver versions, Windows Update status, Intune service status, pending reboot state, disk free space, event error counts, and finding counts.

## Intune Usage

The tool can be packaged and deployed with Intune as a Win32 app if needed.

Suggested install command:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\EndpointHealthAnalyzer.ps1
```

For technician-triggered downloads from a public repo, Intune or a remote session can also run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Launchpad.ps1
```

For production Intune deployment, packaging all app files together is still preferred over downloading from GitHub at runtime. For collection-only scenarios, use the built-in `-SilentScan` mode.

The main script now includes a background scan mode used by the GUI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\EndpointHealthAnalyzer.ps1 -SilentScan
```

This mode writes the JSON and HTML reports without opening the WPF interface.

## Logs

Use **Open logs** in the app to open the main ecHealth log:

```text
C:\ProgramData\EndpointHealthAnalyzer\Logs\EndpointHealthAnalyzer.log
```

Launchpad activity is logged here:

```text
C:\ProgramData\EndpointHealthAnalyzer\Logs\Launchpad.log
```

## What It Checks

- Device identity and join/enrollment indicators
- OS, build, uptime, pending reboot
- Hardware inventory, BIOS age, TPM, disk, battery
- Windows Update activity, policy/source registry values, failed update events
- Intune Management Extension service, logs, MDM enrollment indicators, DeviceManagement events
- Driver and firmware inventory, problematic PnP devices
- Recent System, Application, Setup, Windows Update, Intune, and Autopilot event logs
- Disk, NTFS, WHEA, BugCheck, unexpected shutdown, application crash, MSI, and service errors

## Known Limitations

- Some Windows Update history sources vary by OS build and policy configuration.
- Driver date availability depends on provider data exposed through CIM/PnP.
- Battery and SMART details may be unavailable on some desktops or storage controllers.
- Entra join details are parsed from `dsregcmd /status` when available.
- The GUI scan runs locally and may be busy while large event logs are queried.

## Future Improvement Ideas

- Add a silent scan mode for Intune proactive remediations.
- Add remediation scripts for common issues.
- Add richer driver normalization by hardware vendor.
- Add signed release packaging.
- Add timeline visualizations for crashes, update failures, and IME activity.
- Add optional redaction controls before exporting reports.
