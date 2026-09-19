#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a diagnostic ZIP for VRChat, SteamVR, and Meta Quest Link problems.

.DESCRIPTION
    This read-only collector gathers:
      - Windows, BIOS, motherboard, CPU, RAM, storage, and driver information
      - CPU, memory, GPU, process, disk, and network telemetry
      - Cross-vendor GPU state, with enhanced NVIDIA/AMD telemetry when available
      - Windows gaming, graphics, power, virtualization, and security settings
      - USB controllers and Meta/Oculus/Quest-related devices
      - Steam, SteamVR, VRChat, OpenVR, and Meta Quest Link configuration/logs
      - WHEA, display-driver, USB, application-crash, and reliability events
      - Relevant Windows Error Reporting metadata and crash-dump inventory

    Run it while Quest Link, SteamVR, and VRChat are open and the problem is
    happening. The script requests Administrator rights, samples the live
    system for 60 seconds by default, and creates a timestamped ZIP on Desktop.

.PARAMETER Days
    Number of days of event and application log history to collect. Default: 14.

.PARAMETER SampleSeconds
    Length of the live telemetry sample. Default: 60 seconds.

.PARAMETER OutputDirectory
    Folder where the final ZIP is written. Default: the current user's Desktop.

.PARAMETER IncludeCrashDumps
    Include relevant application crash dumps. Disabled by default because dump
    files can contain fragments of private memory and greatly increase ZIP size.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Collect-VRChat-Quest-Diagnostics.ps1

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Collect-VRChat-Quest-Diagnostics.ps1 -Days 30 -SampleSeconds 120

.NOTES
    The ZIP can contain usernames, local paths, hardware details, VRChat IDs,
    Steam IDs, IP addresses, and diagnostic messages. Basic redaction is
    applied to copied text, but review the ZIP before sharing it publicly.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 90)]
    [int]$Days = 14,

    [ValidateRange(10, 7200)]
    [int]$SampleSeconds = 60,

    [string]$OutputDirectory = [Environment]::GetFolderPath("Desktop"),

    [switch]$IncludeCrashDumps
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-Administrator)) {
    Write-Host "Administrator rights are required. Requesting elevation..." -ForegroundColor Yellow
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Days", "$Days",
        "-SampleSeconds", "$SampleSeconds",
        "-OutputDirectory", "`"$OutputDirectory`""
    )
    if ($IncludeCrashDumps) {
        $arguments += "-IncludeCrashDumps"
    }
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arguments
    }
    catch {
        Write-Host "Elevation was cancelled or failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

$script:Started = Get-Date
$script:StartTime = $script:Started.AddDays(-$Days)
$timestamp = $script:Started.ToString("yyyyMMdd-HHmmss")
$safeComputer = ($env:COMPUTERNAME -replace '[^A-Za-z0-9._-]', '_')
$bundleName = "VRChat-Quest-Diagnostics-$safeComputer-$timestamp"
$workRoot = Join-Path $env:TEMP $bundleName
$zipPath = Join-Path $OutputDirectory "$bundleName.zip"

$dirs = @{
    Root       = $workRoot
    Summary    = Join-Path $workRoot "00-Summary"
    System     = Join-Path $workRoot "01-System"
    Hardware   = Join-Path $workRoot "02-Hardware"
    GPU        = Join-Path $workRoot "03-GPU"
    VR         = Join-Path $workRoot "04-VR-Configuration"
    Logs       = Join-Path $workRoot "05-Application-Logs"
    Events     = Join-Path $workRoot "06-Windows-Events"
    Crashes    = Join-Path $workRoot "07-Crash-Evidence"
    Network    = Join-Path $workRoot "08-Network"
    Live       = Join-Path $workRoot "09-Live-Telemetry"
}

foreach ($directory in $dirs.Values) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$script:CollectionLog = Join-Path $dirs.Root "_collection-log.txt"
$script:ErrorLog = Join-Path $dirs.Root "_collection-errors.txt"
$script:SkippedLog = Join-Path $dirs.Root "_skipped-files.txt"
$script:CopiedBytes = [int64]0
$script:MaximumCopiedBytes = [int64](750MB)
$script:MaximumSingleFileBytes = [int64](100MB)
$script:RedactionCounts = @{}
$script:NvidiaSmi = $null
$script:AmdSmi = $null

function Write-CollectorLog {
    param([string]$Message)

    $line = "[{0}] {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $script:CollectionLog -Value $line -Encoding UTF8
}

function Write-CollectionError {
    param(
        [string]$Step,
        [object]$ErrorRecord
    )

    $message = "[{0}] {1}: {2}" -f (Get-Date).ToString("u"), $Step, $ErrorRecord
    Add-Content -LiteralPath $script:ErrorLog -Value $message -Encoding UTF8
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    Write-CollectorLog $Name
    try {
        & $Action
    }
    catch {
        Write-CollectionError -Step $Name -ErrorRecord $_
    }
}

function Save-Text {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    try {
        & $Command 2>&1 |
            Out-String -Width 1000 |
            Set-Content -LiteralPath $Path -Encoding UTF8
    }
    catch {
        Write-CollectionError -Step "Save $Path" -ErrorRecord $_
        "Collection failed: $($_.Exception.Message)" |
            Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

function Save-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Executable,

        [string[]]$Arguments = @()
    )

    try {
        & $Executable @Arguments 2>&1 |
            Out-String -Width 1000 |
            Set-Content -LiteralPath $Path -Encoding UTF8
    }
    catch {
        Write-CollectionError -Step "$Executable $($Arguments -join ' ')" -ErrorRecord $_
    }
}

function Export-Objects {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [scriptblock]$Command
    )

    try {
        @(& $Command) |
            Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    }
    catch {
        Write-CollectionError -Step "Export $Path" -ErrorRecord $_
    }
}

function Get-NvidiaSmi {
    $command = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidate = Join-Path $env:ProgramFiles "NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    return $null
}

function Get-AmdSmi {
    foreach ($name in @("amd-smi.exe", "amd-smi")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    $amdRoot = Join-Path $env:ProgramFiles "AMD"
    if (Test-Path -LiteralPath $amdRoot) {
        $candidate = Get-ChildItem -LiteralPath $amdRoot -Filter "amd-smi.exe" `
            -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($candidate) {
            return $candidate.FullName
        }
    }

    return $null
}

function Get-SteamRoots {
    $roots = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($registryPath in @(
        "HKCU:\Software\Valve\Steam",
        "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam",
        "HKLM:\SOFTWARE\Valve\Steam"
    )) {
        try {
            $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            foreach ($candidate in @($item.SteamPath, $item.InstallPath)) {
                if ($candidate -and (Test-Path -LiteralPath $candidate)) {
                    [void]$roots.Add((Resolve-Path -LiteralPath $candidate).Path)
                }
            }
        }
        catch {
        }
    }

    foreach ($candidate in @(
        "${env:ProgramFiles(x86)}\Steam",
        "$env:ProgramFiles\Steam"
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            [void]$roots.Add((Resolve-Path -LiteralPath $candidate).Path)
        }
    }

    return @($roots)
}

function Get-MetaInstallRoots {
    $roots = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles "Meta Horizon"),
        (Join-Path $env:ProgramFiles "Oculus")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            [void]$roots.Add((Resolve-Path -LiteralPath $candidate).Path)
        }
    }

    foreach ($registryPath in @(
        "HKLM:\SOFTWARE\WOW6432Node\Oculus VR, LLC\Oculus",
        "HKLM:\SOFTWARE\Oculus VR, LLC\Oculus"
    )) {
        try {
            $base = (
                Get-ItemProperty -LiteralPath $registryPath -Name "Base" `
                    -ErrorAction Stop
            ).Base
            if ($base -and (Test-Path -LiteralPath $base)) {
                [void]$roots.Add((Resolve-Path -LiteralPath $base).Path)
            }
        }
        catch {
        }
    }

    return @($roots)
}

function Get-SteamLibraryRoots {
    param([string[]]$SteamRoots)

    $libraries = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($steamRoot in $SteamRoots) {
        $defaultSteamApps = Join-Path $steamRoot "steamapps"
        if (Test-Path -LiteralPath $defaultSteamApps) {
            [void]$libraries.Add($defaultSteamApps)
        }

        $libraryFile = Join-Path $defaultSteamApps "libraryfolders.vdf"
        if (Test-Path -LiteralPath $libraryFile) {
            try {
                $content = Get-Content -LiteralPath $libraryFile -Raw
                foreach ($match in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
                    $path = $match.Groups[1].Value.Replace("\\", "\")
                    $steamApps = Join-Path $path "steamapps"
                    if (Test-Path -LiteralPath $steamApps) {
                        [void]$libraries.Add($steamApps)
                    }
                }
            }
            catch {
                Write-CollectionError -Step "Read $libraryFile" -ErrorRecord $_
            }
        }
    }

    return @($libraries)
}

function Copy-DiagnosticFile {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [string]$SourceRoot
    )

    try {
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            return
        }

        $item = Get-Item -LiteralPath $Source -ErrorAction Stop
        if ($item.Length -gt $script:MaximumSingleFileBytes) {
            "$Source skipped: $($item.Length) bytes exceeds the per-file limit." |
                Add-Content -LiteralPath $script:SkippedLog -Encoding UTF8
            return
        }
        if (($script:CopiedBytes + $item.Length) -gt $script:MaximumCopiedBytes) {
            "$Source skipped: bundle copy limit reached." |
                Add-Content -LiteralPath $script:SkippedLog -Encoding UTF8
            return
        }

        $relative = $item.Name
        if ($SourceRoot -and $item.FullName.StartsWith($SourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $item.FullName.Substring($SourceRoot.Length).TrimStart("\")
        }
        $destination = Join-Path $DestinationRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Force -ErrorAction Stop
        $script:CopiedBytes += $item.Length
    }
    catch {
        Write-CollectionError -Step "Copy $Source" -ErrorRecord $_
    }
}

function Copy-RecentFiles {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DestinationRoot,

        [string[]]$Extensions = @(".txt", ".log", ".json", ".xml", ".cfg", ".vdf", ".vrsettings", ".wer"),

        [int]$MaximumFiles = 200,

        [datetime]$Since = $script:StartTime
    )

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        return
    }

    try {
        Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LastWriteTime -ge $Since -and
                $_.Extension.ToLowerInvariant() -in $Extensions
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First $MaximumFiles |
            ForEach-Object {
                Copy-DiagnosticFile -Source $_.FullName -DestinationRoot $DestinationRoot -SourceRoot $SourceRoot
            }
    }
    catch {
        Write-CollectionError -Step "Inspect $SourceRoot" -ErrorRecord $_
    }
}

function Export-EventCsv {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$Filter,

        [scriptblock]$Where
    )

    $path = Join-Path $dirs.Events "$Name.csv"
    try {
        $events = @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop)
        if ($Where) {
            $events = @($events | Where-Object $Where)
        }
        $events |
            Sort-Object TimeCreated -Descending |
            Select-Object TimeCreated, LogName, Id, LevelDisplayName, ProviderName,
                ProcessId, ThreadId,
                @{Name = "Message"; Expression = { ($_.Message -replace '\s+', ' ').Trim() }} |
            Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    }
    catch {
        if ($_.Exception.Message -notmatch "No events were found") {
            Write-CollectionError -Step "Event query $Name" -ErrorRecord $_
        }
        @() | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    }
}

function Add-RedactionCount {
    param(
        [string]$Category,
        [int]$Count
    )

    if ($Count -le 0) {
        return
    }
    if (-not $script:RedactionCounts.ContainsKey($Category)) {
        $script:RedactionCounts[$Category] = 0
    }
    $script:RedactionCounts[$Category] += $Count
}

function Replace-TextPattern {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Replacement,
        [string]$Category
    )

    $regex = [regex]::new(
        $Pattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $count = $regex.Matches($Text).Count
    Add-RedactionCount -Category $Category -Count $count
    return $regex.Replace($Text, $Replacement)
}

function Redact-PublicIpv4 {
    param([string]$Text)

    $script:PublicIpv4Redactions = 0
    $regex = [regex]::new(
        '\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b'
    )
    $count = 0
    $result = $regex.Replace($Text, {
        param($match)

        $bytes = [System.Net.IPAddress]::Parse($match.Value).GetAddressBytes()
        $isPrivate = (
            $bytes[0] -eq 10 -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
            $bytes[0] -eq 127 -or
            ($bytes[0] -eq 169 -and $bytes[1] -eq 254)
        )
        if ($isPrivate) {
            return $match.Value
        }

        $script:PublicIpv4Redactions++
        return "<PUBLIC_IPV4>"
    })

    if ($script:PublicIpv4Redactions) {
        $count = $script:PublicIpv4Redactions
        $script:PublicIpv4Redactions = 0
        Add-RedactionCount -Category "PUBLIC_IPV4" -Count $count
    }
    return $result
}

function Redact-CopiedText {
    Write-CollectorLog "Redacting obvious personal identifiers in copied text."

    $textExtensions = @(
        ".txt", ".log", ".csv", ".json", ".xml", ".cfg", ".vdf",
        ".vrsettings", ".wer"
    )

    $files = Get-ChildItem -LiteralPath $dirs.Root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension.ToLowerInvariant() -in $textExtensions }

    foreach ($file in $files) {
        try {
            $text = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($text)) {
                continue
            }

            if ($env:USERNAME) {
                $text = Replace-TextPattern -Text $text `
                    -Pattern ([regex]::Escape($env:USERNAME)) `
                    -Replacement "<WINDOWS_USER>" -Category "WINDOWS_USER"
            }
            if ($env:COMPUTERNAME) {
                $text = Replace-TextPattern -Text $text `
                    -Pattern ([regex]::Escape($env:COMPUTERNAME)) `
                    -Replacement "<COMPUTER_NAME>" -Category "COMPUTER_NAME"
            }

            $text = Replace-TextPattern -Text $text `
                -Pattern '\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b' `
                -Replacement "<EMAIL>" -Category "EMAIL"
            $text = Replace-TextPattern -Text $text `
                -Pattern '\b7656119\d{10}\b' `
                -Replacement "<STEAM_ID>" -Category "STEAM_ID"
            $text = Replace-TextPattern -Text $text `
                -Pattern '\b(?:usr|wrld|avtr|grp|file)_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' `
                -Replacement "<VRCHAT_ID>" -Category "VRCHAT_ID"
            $text = Replace-TextPattern -Text $text `
                -Pattern '(?m)(OnPlayerJoined|OnPlayerLeft)\s+.*$' `
                -Replacement '$1 <VRCHAT_PLAYER>' -Category "VRCHAT_PLAYER"
            $text = Replace-TextPattern -Text $text `
                -Pattern '(?m)^\s*(?:B?SSID|Profile)\s*(?:\d+)?\s*:.*$' `
                -Replacement "<WIFI_IDENTITY>" -Category "WIFI_IDENTITY"
            $text = Replace-TextPattern -Text $text `
                -Pattern '([?&](?:token|auth|key|signature|sig|code|ip)=)[^&\s"]+' `
                -Replacement '$1<SENSITIVE_VALUE>' -Category "URL_SECRET"
            $text = Replace-TextPattern -Text $text `
                -Pattern '(?i)("machine_id"\s*:\s*")[^"]+' `
                -Replacement '$1<MACHINE_ID>' -Category "MACHINE_ID"
            $text = Replace-TextPattern -Text $text `
                -Pattern '(?im)^(\s*(?:"?(?:HMDSerialNumber|SerialNumber|motherboard_serial|device_serial|serial_number)"?\s*[:=]\s*"?))[^",\r\n]+' `
                -Replacement '$1<HARDWARE_SERIAL>' -Category "HARDWARE_SERIAL"
            $text = Replace-TextPattern -Text $text `
                -Pattern '(?i)(USB\\VID_2833&PID_[0-9A-F]{4}\\)[^\s",]+' `
                -Replacement '$1<QUEST_SERIAL>' -Category "QUEST_SERIAL"
            $text = Replace-TextPattern -Text $text `
                -Pattern '(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])' `
                -Replacement "<MAC_ADDRESS>" -Category "MAC_ADDRESS"
            $text = Replace-TextPattern -Text $text `
                -Pattern '(?i)(?<![0-9a-f:])(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{1,4}(?![0-9a-f:])' `
                -Replacement "<IPV6_ADDRESS>" -Category "IPV6_ADDRESS"
            $text = Redact-PublicIpv4 -Text $text

            Set-Content -LiteralPath $file.FullName -Value $text -Encoding UTF8
        }
        catch {
            Write-CollectionError -Step "Redact $($file.FullName)" -ErrorRecord $_
        }
    }

    $report = @(
        "Privacy redaction report"
        "========================"
        "Only copies inside this diagnostic bundle were edited."
        "Original files were not changed."
        ""
        "This is best-effort redaction, not a guarantee that every identifier was removed."
        "Review the ZIP before posting it publicly."
        ""
    )
    foreach ($category in ($script:RedactionCounts.Keys | Sort-Object)) {
        $report += "{0}: {1}" -f $category, $script:RedactionCounts[$category]
    }
    $report | Set-Content -LiteralPath (Join-Path $dirs.Summary "PRIVACY-REDACTION.txt") -Encoding UTF8
}

@"
VRChat / SteamVR / Meta Quest Link diagnostic bundle
====================================================
Created: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss K")
Computer: $env:COMPUTERNAME
Collection window: last $Days days
Live sample: $SampleSeconds seconds

For the most useful capture, Quest Link, SteamVR, and VRChat should be open
while the live sample runs, preferably while the fault is happening.

This script is read-only. It does not change drivers, services, registry
settings, Steam configuration, Meta configuration, or game files.

Privacy warning:
The archive contains hardware and software details, local paths, event
messages, application logs, network configuration, and device information.
Basic text redaction is applied, but review the ZIP before sharing publicly.

Deliberately excluded:
- Passwords, browser profiles, browser history, and credential stores
- Full Windows MEMORY.DMP files
- Application crash dumps unless -IncludeCrashDumps is explicitly supplied
- VRChat cache content and downloaded world/avatar assets
- Large binary application data unrelated to diagnosis
"@ | Set-Content -LiteralPath (Join-Path $dirs.Root "README-FIRST.txt") -Encoding UTF8

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host " VRChat / SteamVR / Meta Quest Link Diagnostic Collector" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "Keep Quest Link, SteamVR, and VRChat open if possible."
Write-Host "Live sampling duration: $SampleSeconds seconds."
Write-Host "Final ZIP: $zipPath"
Write-Host ""

Invoke-Step "Collecting Windows and computer overview" {
    Export-Objects -Path (Join-Path $dirs.System "operating-system.csv") -Command {
        Get-CimInstance Win32_OperatingSystem |
            Select-Object Caption, Version, BuildNumber, OSArchitecture,
                InstallDate, LastBootUpTime, TotalVisibleMemorySize,
                FreePhysicalMemory
    }
    Export-Objects -Path (Join-Path $dirs.System "computer-system.csv") -Command {
        Get-CimInstance Win32_ComputerSystem |
            Select-Object Manufacturer, Model, SystemType, TotalPhysicalMemory,
                NumberOfProcessors, NumberOfLogicalProcessors,
                HypervisorPresent, AutomaticManagedPagefile
    }
    Export-Objects -Path (Join-Path $dirs.System "bios.csv") -Command {
        Get-CimInstance Win32_BIOS |
            Select-Object Manufacturer, SMBIOSBIOSVersion, ReleaseDate, Version
    }
    Export-Objects -Path (Join-Path $dirs.System "motherboard.csv") -Command {
        Get-CimInstance Win32_BaseBoard |
            Select-Object Manufacturer, Product, Version
    }
    Save-NativeCommand -Path (Join-Path $dirs.System "systeminfo.txt") `
        -Executable "systeminfo.exe"
    Export-Objects -Path (Join-Path $dirs.System "installed-hotfixes.csv") -Command {
        Get-HotFix |
            Sort-Object InstalledOn -Descending |
            Select-Object HotFixID, Description, InstalledBy, InstalledOn
    }
}

Invoke-Step "Creating MSInfo32 report" {
    $report = Join-Path $dirs.System "msinfo32.txt"
    $process = Start-Process -FilePath "msinfo32.exe" `
        -ArgumentList "/report `"$report`"" -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(180000)) {
        $process.Kill()
        "msinfo32 timed out after 180 seconds." |
            Set-Content -LiteralPath $report -Encoding UTF8
    }
}

Invoke-Step "Creating DirectX diagnostic report" {
    $report = Join-Path $dirs.System "dxdiag.txt"
    $process = Start-Process -FilePath "dxdiag.exe" `
        -ArgumentList "/whql:off /dontskip /t `"$report`"" `
        -PassThru -WindowStyle Hidden
    if (-not $process.WaitForExit(120000)) {
        $process.Kill()
        "dxdiag timed out after 120 seconds." |
            Set-Content -LiteralPath $report -Encoding UTF8
    }
}

Invoke-Step "Collecting CPU health and configuration" {
    Export-Objects -Path (Join-Path $dirs.Hardware "cpu.csv") -Command {
        Get-CimInstance Win32_Processor |
            Select-Object Name, Manufacturer, Description, Architecture,
                NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed,
                CurrentClockSpeed, LoadPercentage, VirtualizationFirmwareEnabled,
                SecondLevelAddressTranslationExtensions, VMMonitorModeExtensions
    }
    Save-NativeCommand -Path (Join-Path $dirs.Hardware "processor-power-settings.txt") `
        -Executable "powercfg.exe" -Arguments @("/qh", "SCHEME_CURRENT", "SUB_PROCESSOR")
    Save-Text -Path (Join-Path $dirs.Hardware "acpi-thermal-zones.txt") -Command {
        Get-CimInstance -Namespace "root/wmi" `
            -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
            Select-Object InstanceName,
                @{Name = "TemperatureC"; Expression = {
                    [math]::Round(($_.CurrentTemperature / 10) - 273.15, 1)
                }},
                @{Name = "CriticalTripPointC"; Expression = {
                    if ($_.CriticalTripPoint) {
                        [math]::Round(($_.CriticalTripPoint / 10) - 273.15, 1)
                    }
                }} |
            Format-Table -AutoSize
    }
}

Invoke-Step "Collecting RAM configuration and health evidence" {
    Export-Objects -Path (Join-Path $dirs.Hardware "memory-modules.csv") -Command {
        Get-CimInstance Win32_PhysicalMemory |
            Select-Object DeviceLocator, BankLabel, Manufacturer, PartNumber,
                @{Name = "CapacityGB"; Expression = {
                    [math]::Round($_.Capacity / 1GB, 2)
                }},
                Speed, ConfiguredClockSpeed, ConfiguredVoltage,
                DataWidth, TotalWidth, FormFactor, MemoryType, SMBIOSMemoryType
    }
    Export-Objects -Path (Join-Path $dirs.Hardware "memory-arrays.csv") -Command {
        Get-CimInstance Win32_PhysicalMemoryArray |
            Select-Object MemoryDevices, MaxCapacity, MaxCapacityEx,
                Use, ErrorCorrection
    }
    Export-Objects -Path (Join-Path $dirs.Hardware "pagefile.csv") -Command {
        Get-CimInstance Win32_PageFileUsage |
            Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage
    }
    Save-Text -Path (Join-Path $dirs.Hardware "memory-performance-current.txt") -Command {
        Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory |
            Format-List *
    }
}

Invoke-Step "Collecting storage health" {
    Export-Objects -Path (Join-Path $dirs.Hardware "physical-disks.csv") -Command {
        Get-PhysicalDisk -ErrorAction Stop |
            Select-Object FriendlyName, MediaType, BusType, HealthStatus,
                OperationalStatus, Size
    }
    Save-Text -Path (Join-Path $dirs.Hardware "storage-reliability.txt") -Command {
        foreach ($disk in Get-PhysicalDisk -ErrorAction Stop) {
            "=== $($disk.FriendlyName) ==="
            $disk | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue |
                Select-Object Temperature, TemperatureMax, Wear,
                    ReadErrorsTotal, WriteErrorsTotal, PowerOnHours,
                    StartStopCycleCount |
                Format-List
        }
    }
    Export-Objects -Path (Join-Path $dirs.Hardware "volumes.csv") -Command {
        Get-Volume -ErrorAction Stop |
            Select-Object DriveLetter, Path, UniqueId, FileSystemLabel,
                FileSystem, DriveType, HealthStatus, OperationalStatus,
                Size, SizeRemaining
    }
    Save-NativeCommand -Path (Join-Path $dirs.Hardware "volume-mount-points.txt") `
        -Executable "mountvol.exe"
}

Invoke-Step "Collecting cross-vendor display and GPU state" {
    $videoControllers = @(Get-CimInstance Win32_VideoController)
    $videoControllers |
        Select-Object Name, AdapterCompatibility, AdapterRAM, DriverVersion,
            DriverDate, VideoProcessor, VideoModeDescription,
            CurrentHorizontalResolution, CurrentVerticalResolution,
            CurrentRefreshRate, Status |
        Export-Csv -LiteralPath (Join-Path $dirs.GPU "video-controllers.csv") `
            -NoTypeInformation -Encoding UTF8
    $videoControllers |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Vendor = if ("$($_.Name) $($_.AdapterCompatibility)" -match "NVIDIA") {
                    "NVIDIA"
                }
                elseif ("$($_.Name) $($_.AdapterCompatibility)" -match "AMD|ATI|Radeon") {
                    "AMD"
                }
                elseif ("$($_.Name) $($_.AdapterCompatibility)" -match "Intel") {
                    "Intel"
                }
                else {
                    "Other"
                }
                DriverVersion = $_.DriverVersion
                DriverDate = $_.DriverDate
            }
        } |
        Export-Csv -LiteralPath (Join-Path $dirs.GPU "gpu-vendors.csv") `
            -NoTypeInformation -Encoding UTF8

    Export-Objects -Path (Join-Path $dirs.GPU "display-drivers.csv") -Command {
        Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='DISPLAY'" |
            Select-Object DeviceName, Manufacturer, DriverProviderName,
                DriverVersion, DriverDate, InfName, IsSigned
    }
    Save-NativeCommand -Path (Join-Path $dirs.GPU "display-diagnostic.txt") `
        -Executable "dispdiag.exe" -Arguments @("-out", (Join-Path $dirs.GPU "dispdiag.dat"))
    Save-Text -Path (Join-Path $dirs.GPU "graphics-and-gaming-registry.txt") -Command {
        foreach ($path in @(
            "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers",
            "HKCU:\Software\Microsoft\GameBar",
            "HKCU:\System\GameConfigStore",
            "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
        )) {
            "=== $path ==="
            Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue |
                Format-List *
        }
    }

    $script:NvidiaSmi = Get-NvidiaSmi
    if ($script:NvidiaSmi) {
        Save-NativeCommand -Path (Join-Path $dirs.GPU "nvidia-smi-full.txt") `
            -Executable $script:NvidiaSmi -Arguments @("-q")
        Save-NativeCommand -Path (Join-Path $dirs.GPU "nvidia-smi-performance.txt") `
            -Executable $script:NvidiaSmi `
            -Arguments @("-q", "-d", "PERFORMANCE,CLOCK,POWER,TEMPERATURE,MEMORY,PCIE")
        Save-NativeCommand -Path (Join-Path $dirs.GPU "nvidia-smi-query-fields.txt") `
            -Executable $script:NvidiaSmi -Arguments @("--help-query-gpu")
    }
    else {
        "nvidia-smi.exe was not found." |
            Set-Content -LiteralPath (Join-Path $dirs.GPU "nvidia-smi-not-found.txt") -Encoding UTF8
    }

    $script:AmdSmi = Get-AmdSmi
    if ($script:AmdSmi) {
        Save-NativeCommand -Path (Join-Path $dirs.GPU "amd-smi-list.json") `
            -Executable $script:AmdSmi -Arguments @("list", "--json")
        Save-NativeCommand -Path (Join-Path $dirs.GPU "amd-smi-static.json") `
            -Executable $script:AmdSmi -Arguments @("static", "--json")
        Save-NativeCommand -Path (Join-Path $dirs.GPU "amd-smi-metric.json") `
            -Executable $script:AmdSmi -Arguments @("metric", "--json")
    }
    else {
        "amd-smi was not found. Windows GPU engine counters and DirectX diagnostics remain available." |
            Set-Content -LiteralPath (Join-Path $dirs.GPU "amd-smi-not-found.txt") -Encoding UTF8
    }
}

Invoke-Step "Collecting USB and VR device state" {
    Export-Objects -Path (Join-Path $dirs.VR "usb-controllers.csv") -Command {
        Get-CimInstance Win32_USBController |
            Select-Object Name, Manufacturer, DeviceID, PNPDeviceID, Status
    }
    Export-Objects -Path (Join-Path $dirs.VR "usb-hubs.csv") -Command {
        Get-CimInstance Win32_USBHub |
            Select-Object Name, Description, DeviceID, PNPDeviceID, Status
    }
    Export-Objects -Path (Join-Path $dirs.VR "vr-related-pnp-devices.csv") -Command {
        Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object {
                "$($_.FriendlyName) $($_.InstanceId) $($_.Class)" -match
                    "Oculus|Meta|Quest|VR|OpenXR|XRSP|ADB|Android|Rift"
            } |
            Select-Object Status, Class, FriendlyName, InstanceId, Problem,
                ConfigManagerErrorCode
    }
    Export-Objects -Path (Join-Path $dirs.VR "problem-devices.csv") -Command {
        Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -ne "OK" } |
            Select-Object Status, Class, FriendlyName, InstanceId, Problem,
                ConfigManagerErrorCode
    }
    Save-NativeCommand -Path (Join-Path $dirs.VR "pnputil-usb-devices.txt") `
        -Executable "pnputil.exe" -Arguments @("/enum-devices", "/class", "USB", "/drivers")
}

Invoke-Step "Collecting installed VR software, services, and processes" {
    Export-Objects -Path (Join-Path $dirs.VR "installed-vr-software.csv") -Command {
        Get-ItemProperty `
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
            -ErrorAction SilentlyContinue |
            Where-Object {
                $displayName = if ($_.PSObject.Properties.Match("DisplayName").Count) {
                    $_.DisplayName
                }
                else {
                    ""
                }
                $publisher = if ($_.PSObject.Properties.Match("Publisher").Count) {
                    $_.Publisher
                }
                else {
                    ""
                }
                "$displayName $publisher" -match
                    "Steam|SteamVR|VRChat|Oculus|Meta Quest|OpenXR|Virtual Desktop|VIVE|Pimax|fpsVR|OVR Toolkit|VRCX"
            } |
            Select-Object DisplayName, DisplayVersion, Publisher,
                InstallDate, InstallLocation
    }
    Export-Objects -Path (Join-Path $dirs.VR "vr-services.csv") -Command {
        Get-CimInstance Win32_Service |
            Where-Object {
                "$($_.Name) $($_.DisplayName) $($_.PathName)" -match
                    "Oculus|OVR|Meta|Steam|VR|OpenXR"
            } |
            Select-Object Name, DisplayName, State, StartMode, StartName, PathName
    }
    Export-Objects -Path (Join-Path $dirs.VR "running-processes.csv") -Command {
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -match
                    "VRChat|vrserver|vrcompositor|vrmonitor|vrdashboard|vrwebhelper|steam|OVR|Oculus|Meta|VirtualDesktop|VRCX|OpenXR|fpsVR|OVRToolkit"
            } |
            Select-Object Name, ProcessId, ParentProcessId, ExecutablePath,
                CommandLine, CreationDate
    }
    Save-Text -Path (Join-Path $dirs.VR "openxr-runtime.txt") -Command {
        foreach ($path in @(
            "HKLM:\SOFTWARE\Khronos\OpenXR\1",
            "HKLM:\SOFTWARE\WOW6432Node\Khronos\OpenXR\1",
            "HKCU:\SOFTWARE\Khronos\OpenXR\1"
        )) {
            "=== $path ==="
            Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue |
                Format-List *
        }
    }
}

$steamRoots = @(Get-SteamRoots)
$steamLibraries = @(Get-SteamLibraryRoots -SteamRoots $steamRoots)

Invoke-Step "Collecting Steam and SteamVR configuration" {
    $steamRoots |
        Set-Content -LiteralPath (Join-Path $dirs.VR "steam-roots.txt") -Encoding UTF8
    $steamLibraries |
        Set-Content -LiteralPath (Join-Path $dirs.VR "steam-library-roots.txt") -Encoding UTF8

    foreach ($steamRoot in $steamRoots) {
        $label = ($steamRoot -replace '[:\\ /]', '_').Trim("_")
        $destination = Join-Path $dirs.Logs "Steam-$label"
        $logRoot = Join-Path $steamRoot "logs"
        Copy-RecentFiles -SourceRoot $logRoot -DestinationRoot (Join-Path $destination "logs") `
            -Extensions @(".txt", ".log") -MaximumFiles 250

        foreach ($relative in @(
            "config\steamvr.vrsettings",
            "config\steamvr.vrstats",
            "config\config.vdf",
            "steamapps\libraryfolders.vdf"
        )) {
            $source = Join-Path $steamRoot $relative
            Copy-DiagnosticFile -Source $source -DestinationRoot (Join-Path $destination "config") `
                -SourceRoot $steamRoot
        }
    }

    foreach ($steamApps in $steamLibraries) {
        foreach ($appId in @("250820", "438100")) {
            $manifest = Join-Path $steamApps "appmanifest_$appId.acf"
            Copy-DiagnosticFile -Source $manifest `
                -DestinationRoot (Join-Path $dirs.VR "steam-app-manifests") `
                -SourceRoot $steamApps
        }
    }

    foreach ($path in @(
        (Join-Path $env:LOCALAPPDATA "openvr\openvrpaths.vrpath"),
        (Join-Path $env:LOCALAPPDATA "openvrpaths.vrpath")
    )) {
        Copy-DiagnosticFile -Source $path -DestinationRoot (Join-Path $dirs.VR "openvr")
    }
}

Invoke-Step "Collecting VRChat logs and crash evidence" {
    $localLow = Join-Path (Split-Path $env:LOCALAPPDATA -Parent) "LocalLow"
    $vrchatRoot = Join-Path $localLow "VRChat\VRChat"
    if (Test-Path -LiteralPath $vrchatRoot) {
        Get-ChildItem -LiteralPath $vrchatRoot -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like "output_log_*.txt" -or
                $_.Name -in @("config.json", "output_log.txt")
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 12 |
            ForEach-Object {
                Copy-DiagnosticFile -Source $_.FullName `
                    -DestinationRoot (Join-Path $dirs.Logs "VRChat") `
                    -SourceRoot $vrchatRoot
            }
    }

    $vrchatTemp = Join-Path $env:TEMP "VRChat\VRChat"
    $vrchatTempExtensions = @(".txt", ".log", ".wer")
    if ($IncludeCrashDumps) {
        $vrchatTempExtensions += ".dmp"
    }
    Copy-RecentFiles -SourceRoot $vrchatTemp `
        -DestinationRoot (Join-Path $dirs.Crashes "VRChat-Temp") `
        -Extensions $vrchatTempExtensions -MaximumFiles 30

    $crashDumps = Join-Path $env:LOCALAPPDATA "CrashDumps"
    if (Test-Path -LiteralPath $crashDumps) {
        $relevantDumps = @(
            Get-ChildItem -LiteralPath $crashDumps -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match "VRChat|vrserver|vrcompositor|OVRServer|Oculus" -and
                $_.LastWriteTime -ge $script:StartTime
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 20
        )
        $relevantDumps |
            Select-Object Name, Length, CreationTime, LastWriteTime |
            Export-Csv -LiteralPath (Join-Path $dirs.Crashes "crash-dump-inventory.csv") `
                -NoTypeInformation -Encoding UTF8

        if ($IncludeCrashDumps) {
            $relevantDumps | Select-Object -First 10 | ForEach-Object {
                Copy-DiagnosticFile -Source $_.FullName `
                    -DestinationRoot (Join-Path $dirs.Crashes "User-CrashDumps")
            }
        }
    }
}

Invoke-Step "Collecting Meta Quest Link and Oculus logs" {
    $metaInstallRoots = @(Get-MetaInstallRoots)
    $metaLogSources = @(
        (Join-Path $env:LOCALAPPDATA "Oculus"),
        (Join-Path $env:APPDATA "Oculus"),
        (Join-Path $env:ProgramData "Oculus")
    )
    foreach ($metaRoot in $metaInstallRoots) {
        $metaLogSources += Join-Path $metaRoot "Support\oculus-runtime"
        $metaLogSources += Join-Path $metaRoot "Support\oculus-diagnostics"
    }

    foreach ($source in ($metaLogSources | Sort-Object -Unique)) {
        if (Test-Path -LiteralPath $source) {
            $label = ($source -replace '[:\\ /]', '_').Trim("_")
            Copy-RecentFiles -SourceRoot $source `
                -DestinationRoot (Join-Path $dirs.Logs "Meta-$label") `
                -Extensions @(".txt", ".log", ".json", ".xml", ".cfg", ".wer") `
                -MaximumFiles 250
        }
    }

    $logGatherer = $null
    foreach ($metaRoot in $metaInstallRoots) {
        $candidate = Join-Path $metaRoot "Support\oculus-diagnostics\OculusLogGatherer.exe"
        if (Test-Path -LiteralPath $candidate) {
            $logGatherer = $candidate
            break
        }
    }
    @(
        "Official Meta log gatherer detected: $([bool]$logGatherer)"
        "Detected path: $logGatherer"
        ""
        "The collector copied existing readable Meta/Oculus logs."
        "It did not launch the interactive Meta log-gathering utility."
    ) | Set-Content -LiteralPath (Join-Path $dirs.VR "meta-log-gatherer.txt") -Encoding UTF8
}

Invoke-Step "Collecting Windows event evidence" {
    Export-EventCsv -Name "WHEA-Hardware-Errors" -Filter @{
        LogName = "System"
        ProviderName = "Microsoft-Windows-WHEA-Logger"
        StartTime = $script:StartTime
    }
    Export-EventCsv -Name "Display-GPU-Driver-Events" -Filter @{
        LogName = "System"
        StartTime = $script:StartTime
    } -Where {
        $_.ProviderName -match "Display|nvlddmkm|amdkmdag|amdwddmg|igfx|dxgkrnl|Kernel-PnP" -or
        $_.Message -match "NVIDIA|AMD|Radeon|Intel.*Graphics|GPU|display driver|LiveKernelEvent"
    }
    Export-EventCsv -Name "USB-and-Device-Events" -Filter @{
        LogName = "System"
        StartTime = $script:StartTime
    } -Where {
        $_.ProviderName -match "USB|Kernel-PnP|DriverFrameworks|UserPnp" -or
        $_.Message -match "Oculus|Meta|Quest|USB|VR"
    }
    Export-EventCsv -Name "Power-and-Processor-Events" -Filter @{
        LogName = "System"
        StartTime = $script:StartTime
    } -Where {
        $_.ProviderName -match "Kernel-Power|Kernel-Processor-Power|Thermal"
    }
    Export-EventCsv -Name "Disk-and-Storage-Errors" -Filter @{
        LogName = "System"
        Level = 1, 2, 3
        StartTime = $script:StartTime
    } -Where {
        $_.ProviderName -match "disk|stornvme|storahci|Ntfs|volmgr"
    }
    Export-EventCsv -Name "VR-Application-Crashes" -Filter @{
        LogName = "Application"
        StartTime = $script:StartTime
    } -Where {
        (
            $_.ProviderName -match "Application Error|Application Hang|Windows Error Reporting|\.NET Runtime"
        ) -and (
            $_.Message -match "VRChat|SteamVR|vrserver|vrcompositor|vrmonitor|OVRServer|Oculus|Meta|OpenXR|nvlddmkm"
        )
    }
    Export-EventCsv -Name "Windows-Memory-Diagnostics" -Filter @{
        LogName = "System"
        StartTime = $script:StartTime
    } -Where {
        $_.ProviderName -match "MemoryDiagnostics"
    }

    Export-Objects -Path (Join-Path $dirs.Events "reliability-history.csv") -Command {
        Get-CimInstance Win32_ReliabilityRecords -ErrorAction SilentlyContinue |
            Where-Object {
                $_.TimeGenerated -ge $script:StartTime -and
                "$($_.ProductName) $($_.SourceName) $($_.Message)" -match
                    "VRChat|Steam|Oculus|Meta|Quest|NVIDIA|AMD|Radeon|Intel.*Graphics|LiveKernelEvent|hardware error"
            } |
            Sort-Object TimeGenerated -Descending |
            Select-Object TimeGenerated, SourceName, EventIdentifier,
                ProductName, Message
    }
}

Invoke-Step "Collecting Windows Error Reporting metadata" {
    foreach ($source in @(
        (Join-Path $env:ProgramData "Microsoft\Windows\WER"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER")
    )) {
        if (-not (Test-Path -LiteralPath $source)) {
            continue
        }

        Get-ChildItem -LiteralPath $source -Recurse -Filter "Report.wer" -File `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $script:StartTime } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 50 |
            ForEach-Object {
                $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
                if ($content -match "VRChat|SteamVR|vrserver|vrcompositor|OVRServer|Oculus|Meta|Quest|NVIDIA|AMD|Radeon|Intel.*Graphics|LiveKernelEvent") {
                    Copy-DiagnosticFile -Source $_.FullName `
                        -DestinationRoot (Join-Path $dirs.Crashes "WER") `
                        -SourceRoot $source
                }
            }
    }
}

Invoke-Step "Collecting power, virtualization, and security state" {
    Save-NativeCommand -Path (Join-Path $dirs.System "power-plans.txt") `
        -Executable "powercfg.exe" -Arguments @("/list")
    Save-NativeCommand -Path (Join-Path $dirs.System "active-power-plan.txt") `
        -Executable "powercfg.exe" -Arguments @("/getactivescheme")
    Save-NativeCommand -Path (Join-Path $dirs.System "power-requests.txt") `
        -Executable "powercfg.exe" -Arguments @("/requests")
    Save-NativeCommand -Path (Join-Path $dirs.System "available-sleep-states.txt") `
        -Executable "powercfg.exe" -Arguments @("/a")
    Save-Text -Path (Join-Path $dirs.System "virtualization-and-security.txt") -Command {
        Get-CimInstance Win32_DeviceGuard -Namespace "root\Microsoft\Windows\DeviceGuard" `
            -ErrorAction SilentlyContinue |
            Format-List *
        Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FeatureName -match "Hyper-V|VirtualMachinePlatform|HypervisorPlatform|Containers"
            } |
            Format-Table FeatureName, State -AutoSize
        Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName AntiVirusProduct `
            -ErrorAction SilentlyContinue |
            Select-Object displayName, productState, pathToSignedProductExe |
            Format-Table -AutoSize
    }
}

Invoke-Step "Collecting network and Air Link evidence" {
    Export-Objects -Path (Join-Path $dirs.Network "network-adapters.csv") -Command {
        Get-NetAdapter -IncludeHidden |
            Select-Object Name, InterfaceDescription, Status, LinkSpeed,
                DriverInformation, DriverVersion, MediaConnectionState
    }
    Export-Objects -Path (Join-Path $dirs.Network "network-statistics.csv") -Command {
        Get-NetAdapterStatistics |
            Select-Object Name, ReceivedBytes, SentBytes, ReceivedUnicastPackets,
                SentUnicastPackets, ReceivedDiscardedPackets,
                OutboundDiscardedPackets, ReceivedPacketErrors, OutboundPacketErrors
    }
    Save-Text -Path (Join-Path $dirs.Network "ip-configuration.txt") -Command {
        Get-NetIPConfiguration |
            Select-Object InterfaceAlias, InterfaceDescription, NetProfile,
                IPv4Address, IPv6Address, IPv4DefaultGateway, DNSServer |
            Format-List
    }
    Save-NativeCommand -Path (Join-Path $dirs.Network "routes.txt") `
        -Executable "route.exe" -Arguments @("print")
    Save-NativeCommand -Path (Join-Path $dirs.Network "tcp-global.txt") `
        -Executable "netsh.exe" -Arguments @("interface", "tcp", "show", "global")
    Save-NativeCommand -Path (Join-Path $dirs.Network "wifi-interface.txt") `
        -Executable "netsh.exe" -Arguments @("wlan", "show", "interfaces")
    Save-NativeCommand -Path (Join-Path $dirs.Network "wifi-drivers.txt") `
        -Executable "netsh.exe" -Arguments @("wlan", "show", "drivers")
    Export-Objects -Path (Join-Path $dirs.Network "adapter-advanced-properties.csv") -Command {
        Get-NetAdapterAdvancedProperty -AllProperties -ErrorAction SilentlyContinue |
            Select-Object Name, DisplayName, DisplayValue, RegistryKeyword, RegistryValue
    }
}

Invoke-Step "Collecting current process and driver inventory" {
    Export-Objects -Path (Join-Path $dirs.System "all-running-processes.csv") -Command {
        Get-Process |
            Sort-Object ProcessName, Id |
            Select-Object ProcessName, Id, CPU, WorkingSet64, PrivateMemorySize64,
                HandleCount, Threads, Path
    }
    Save-NativeCommand -Path (Join-Path $dirs.System "driverquery.txt") `
        -Executable "driverquery.exe" -Arguments @("/v")
    Save-NativeCommand -Path (Join-Path $dirs.System "third-party-drivers.txt") `
        -Executable "pnputil.exe" -Arguments @("/enum-drivers")
}

Write-CollectorLog "Starting $SampleSeconds-second live telemetry sample."
$liveSystemPath = Join-Path $dirs.Live "system.csv"
$liveProcessesPath = Join-Path $dirs.Live "vr-processes.csv"
$liveGpuPath = Join-Path $dirs.Live "nvidia-gpu.csv"
$liveAmdGpuPath = Join-Path $dirs.Live "amd-gpu.jsonl"
$liveGpuEnginesPath = Join-Path $dirs.Live "gpu-engines.csv"
$script:SamplesCollected = 0
$script:SampleStoppedEarly = $false

Write-Host ""
Write-Host "Live capture has started." -ForegroundColor Cyan
Write-Host "Press ENTER after the fault occurs to stop sampling and build the ZIP immediately." -ForegroundColor Cyan
Write-Host "Do not use Ctrl+C, because that would skip final log collection." -ForegroundColor Yellow
Write-Host ""

if ($script:NvidiaSmi) {
    @(
        "collection_timestamp",
        "nvidia_timestamp",
        "gpu_index",
        "gpu_name",
        "driver_version",
        "performance_state",
        "temperature_c",
        "gpu_utilization_percent",
        "memory_utilization_percent",
        "encoder_utilization_percent",
        "decoder_utilization_percent",
        "memory_used_mib",
        "memory_total_mib",
        "power_draw_w",
        "power_limit_w",
        "graphics_clock_mhz",
        "memory_clock_mhz",
        "pcie_generation_current",
        "pcie_generation_max",
        "pcie_width_current",
        "pcie_width_max"
    ) -join "," |
        Set-Content -LiteralPath $liveGpuPath -Encoding UTF8
}

$sampleStarted = Get-Date
$sampleDeadline = $sampleStarted.AddSeconds($SampleSeconds)
$sampleNumber = 0

while ((Get-Date) -lt $sampleDeadline) {
    $sampleTime = Get-Date
    $sampleNumber++
    $script:SamplesCollected++

    try {
        $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor |
            Where-Object Name -eq "_Total" |
            Select-Object -First 1
        $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        $disk = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk `
            -Filter "Name='_Total'"

        [pscustomobject]@{
            Timestamp = $sampleTime.ToString("o")
            CpuPercent = $cpu.PercentProcessorTime
            CpuUserPercent = $cpu.PercentUserTime
            CpuPrivilegedPercent = $cpu.PercentPrivilegedTime
            CpuDpcPercent = $cpu.PercentDPCTime
            CpuInterruptPercent = $cpu.PercentInterruptTime
            AvailableMemoryMB = $memory.AvailableMBytes
            CommittedMemoryPercent = $memory.PercentCommittedBytesInUse
            PagesPerSecond = $memory.PagesPerSec
            DiskBusyPercent = $disk.PercentDiskTime
            DiskReadBytesPerSecond = $disk.DiskReadBytesPerSec
            DiskWriteBytesPerSecond = $disk.DiskWriteBytesPerSec
            DiskQueueLength = $disk.CurrentDiskQueueLength
        } | Export-Csv -LiteralPath $liveSystemPath -Append `
            -NoTypeInformation -Encoding UTF8
    }
    catch {
        Write-CollectionError -Step "Live system sample $sampleNumber" -ErrorRecord $_
    }

    try {
        Get-CimInstance Win32_PerfFormattedData_PerfProc_Process |
            Where-Object {
                $_.Name -match
                    "^(VRChat|vrserver|vrcompositor|vrmonitor|vrdashboard|vrwebhelper|steam|steamwebhelper|OVRServer.*|OVRService.*|Oculus.*|oculus.*|VirtualDesktop.*|VRCX.*|OpenXR.*|fpsVR.*|OVRToolkit.*)(#\d+)?$"
            } |
            ForEach-Object {
                [pscustomobject]@{
                    Timestamp = $sampleTime.ToString("o")
                    Name = $_.Name
                    ProcessId = $_.IDProcess
                    CpuPercent = $_.PercentProcessorTime
                    WorkingSetMB = [math]::Round($_.WorkingSet / 1MB, 2)
                    PrivateBytesMB = [math]::Round($_.PrivateBytes / 1MB, 2)
                    ThreadCount = $_.ThreadCount
                    IODataBytesPerSecond = $_.IODataBytesPersec
                    PageFaultsPerSecond = $_.PageFaultsPersec
                }
            } | Export-Csv -LiteralPath $liveProcessesPath -Append `
                -NoTypeInformation -Encoding UTF8
    }
    catch {
        Write-CollectionError -Step "Live process sample $sampleNumber" -ErrorRecord $_
    }

    if ($script:NvidiaSmi) {
        try {
            $query = @(
                "timestamp", "index", "name", "driver_version", "pstate",
                "temperature.gpu", "utilization.gpu", "utilization.memory",
                "utilization.encoder", "utilization.decoder", "memory.used",
                "memory.total", "power.draw", "power.limit",
                "clocks.current.graphics", "clocks.current.memory",
                "pcie.link.gen.current", "pcie.link.gen.max",
                "pcie.link.width.current", "pcie.link.width.max"
            ) -join ","
            & $script:NvidiaSmi "--query-gpu=$query" "--format=csv,noheader,nounits" 2>$null |
                ForEach-Object {
                    '"{0}",{1}' -f $sampleTime.ToString("o"), $_ |
                        Add-Content -LiteralPath $liveGpuPath -Encoding UTF8
                }
        }
        catch {
            Write-CollectionError -Step "Live NVIDIA sample $sampleNumber" -ErrorRecord $_
        }
    }

    if (($sampleNumber % 5) -eq 1) {
        if ($script:AmdSmi) {
            try {
                $rawAmdMetrics = @(
                    & $script:AmdSmi "metric" "--json" 2>&1
                ) -join [Environment]::NewLine
                if ($LASTEXITCODE -eq 0) {
                    $amdMetrics = $rawAmdMetrics | ConvertFrom-Json -ErrorAction Stop
                    [pscustomobject]@{
                        Timestamp = $sampleTime.ToString("o")
                        Metrics = $amdMetrics
                    } |
                        ConvertTo-Json -Depth 20 -Compress |
                        Add-Content -LiteralPath $liveAmdGpuPath -Encoding UTF8
                }
                else {
                    throw "amd-smi returned exit code $LASTEXITCODE`: $rawAmdMetrics"
                }
            }
            catch {
                Write-CollectionError -Step "Live AMD GPU sample $sampleNumber" -ErrorRecord $_
            }
        }

        try {
            Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine `
                -ErrorAction Stop |
                Where-Object { $_.UtilizationPercentage -ge 0.1 } |
                Sort-Object UtilizationPercentage -Descending |
                Select-Object -First 50 |
                ForEach-Object {
                    [pscustomobject]@{
                        Timestamp = $sampleTime.ToString("o")
                        Instance = $_.Name
                        UtilizationPercent = $_.UtilizationPercentage
                    }
                } | Export-Csv -LiteralPath $liveGpuEnginesPath -Append `
                    -NoTypeInformation -Encoding UTF8
        }
        catch {
            Write-CollectionError -Step "GPU engine sample $sampleNumber" -ErrorRecord $_
        }
    }

    $elapsedSeconds = [math]::Min(
        $SampleSeconds,
        [int]((Get-Date) - $sampleStarted).TotalSeconds
    )
    Write-Progress -Activity "Collecting live VR diagnostics" `
        -Status "$elapsedSeconds of $SampleSeconds seconds" `
        -PercentComplete (($elapsedSeconds / $SampleSeconds) * 100)

    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                $script:SampleStoppedEarly = $true
                Write-CollectorLog "ENTER pressed; ending live sampling early after $($script:SamplesCollected) sample(s)."
                break
            }
        }
    }
    catch {
        # Key polling is unavailable in some PowerShell hosts; timed capture continues.
    }

    Start-Sleep -Seconds 1
}
Write-Progress -Activity "Collecting live VR diagnostics" -Completed

Invoke-Step "Refreshing logs generated during the live sample" {
    foreach ($steamRoot in $steamRoots) {
        $label = ($steamRoot -replace '[:\\ /]', '_').Trim("_")
        $destination = Join-Path $dirs.Logs "Steam-$label"
        Copy-RecentFiles -SourceRoot (Join-Path $steamRoot "logs") `
            -DestinationRoot (Join-Path $destination "logs") `
            -Extensions @(".txt", ".log") -MaximumFiles 250 `
            -Since $script:Started
    }

    $localLow = Join-Path (Split-Path $env:LOCALAPPDATA -Parent) "LocalLow"
    $vrchatRoot = Join-Path $localLow "VRChat\VRChat"
    Copy-RecentFiles -SourceRoot $vrchatRoot `
        -DestinationRoot (Join-Path $dirs.Logs "VRChat") `
        -Extensions @(".txt", ".log", ".json") -MaximumFiles 20 `
        -Since $script:Started

    foreach ($source in @(
        (Join-Path $env:LOCALAPPDATA "Oculus"),
        (Join-Path $env:APPDATA "Oculus"),
        (Join-Path $env:ProgramData "Oculus")
    )) {
        if (Test-Path -LiteralPath $source) {
            $label = ($source -replace '[:\\ /]', '_').Trim("_")
            Copy-RecentFiles -SourceRoot $source `
                -DestinationRoot (Join-Path $dirs.Logs "Meta-$label") `
                -Extensions @(".txt", ".log", ".json", ".xml", ".cfg", ".wer") `
                -MaximumFiles 250 -Since $script:Started
        }
    }

    Export-EventCsv -Name "Post-Sample-VR-System-Events" -Filter @{
        LogName = "System"
        StartTime = $script:Started
    } -Where {
        $_.ProviderName -match "WHEA|Display|nvlddmkm|amdkmdag|amdwddmg|igfx|Kernel-Power|Kernel-PnP|USB|DriverFrameworks|Ntfs|disk|stor" -or
        $_.Message -match "Oculus|Meta|Quest|VR|NVIDIA|AMD|Radeon|Intel.*Graphics|GPU|USB"
    }
    Export-EventCsv -Name "Post-Sample-VR-Application-Events" -Filter @{
        LogName = "Application"
        StartTime = $script:Started
    } -Where {
        $_.ProviderName -match "Application Error|Application Hang|Windows Error Reporting|\.NET Runtime" -and
        $_.Message -match "VRChat|SteamVR|vrserver|vrcompositor|vrmonitor|OVRServer|Oculus|Meta|OpenXR|NVIDIA|AMD|Radeon|Intel.*Graphics"
    }
}

Invoke-Step "Analyzing common VR failure patterns" {
    $patterns = [ordered]@{
        "NVIDIA display driver reset" = "nvlddmkm|display driver.*stopped responding"
        "AMD display driver reset" = "amdkmdag|amdwddmg|Radeon.*driver.*(reset|timeout)"
        "Intel display driver reset" = "igfx|Intel.*Graphics.*driver.*(reset|timeout)"
        "GPU removed, hung, or reset" = "DXGI_ERROR_DEVICE_(REMOVED|HUNG|RESET)"
        "SteamVR compositor timeout" = "WaitForPresent|compositor.*timeout"
        "SteamVR watchdog" = "watchdog"
        "SteamVR disconnect" = "vrcompositor disconnected|headset.*disconnected"
        "USB disconnect or reset" = "USB.*disconnect|device.*reset|port reset failed"
        "Quest Link transport failure" = "OVRServer|Oculus.*(error|failed)|Link.*(error|failed)"
        "OpenXR failure" = "OpenXR.*(error|failed)|XR_ERROR_"
        "VRChat crash or out of memory" = "out of memory|access violation|crash|fatal error"
        "Encoder failure" = "encoder.*(error|failed)|NVENC.*(error|failed)"
        "WHEA hardware error" = "WHEA|hardware error|machine check"
    }

    $textFiles = Get-ChildItem -LiteralPath $dirs.Root -Recurse -File `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension.ToLowerInvariant() -in @(".txt", ".log", ".csv", ".wer") }

    $patternResults = foreach ($entry in $patterns.GetEnumerator()) {
        $matches = @(
            $textFiles | Select-String -Pattern $entry.Value -AllMatches `
                -ErrorAction SilentlyContinue
        )
        [pscustomobject]@{
            Finding = $entry.Key
            Pattern = $entry.Value
            MatchingLines = $matches.Count
            Files = (
                @($matches | ForEach-Object Path | Sort-Object -Unique) -join "; "
            )
        }
    }
    $patternResults |
        Export-Csv -LiteralPath (Join-Path $dirs.Summary "pattern-counts.csv") `
        -NoTypeInformation -Encoding UTF8
}

Invoke-Step "Writing summary" {
    $summary = [System.Collections.Generic.List[string]]::new()
    $summary.Add("VRChat / SteamVR / Meta Quest Link diagnostic summary")
    $summary.Add("====================================================")
    $summary.Add("Collected: $($script:Started.ToString('yyyy-MM-dd HH:mm:ss zzz'))")
    $summary.Add("Event/log window: last $Days days")
    $summary.Add("Live samples collected: $($script:SamplesCollected)")
    $summary.Add("Live sample stopped early with ENTER: $($script:SampleStoppedEarly)")
    $summary.Add("")

    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $memoryModules = @(Get-CimInstance Win32_PhysicalMemory)
    $gpus = @(Get-CimInstance Win32_VideoController)

    $summary.Add("SYSTEM")
    $summary.Add("OS: $($os.Caption) $($os.Version), build $($os.BuildNumber)")
    $summary.Add("Computer: $($computer.Manufacturer) $($computer.Model)")
    $summary.Add("CPU: $($cpu.Name.Trim())")
    $summary.Add("CPU cores/threads: $($cpu.NumberOfCores)/$($cpu.NumberOfLogicalProcessors)")
    $summary.Add("RAM: $([math]::Round($computer.TotalPhysicalMemory / 1GB, 1)) GB in $($memoryModules.Count) module(s)")
    $summary.Add("RAM configured speed(s): $(($memoryModules.ConfiguredClockSpeed | Sort-Object -Unique) -join ', ') MT/s")
    foreach ($gpu in $gpus) {
        $summary.Add("GPU: $($gpu.Name), driver $($gpu.DriverVersion)")
    }
    $summary.Add("")

    if (Test-Path -LiteralPath $liveSystemPath) {
        $samples = @(Import-Csv -LiteralPath $liveSystemPath)
        if ($samples.Count -gt 0) {
            $summary.Add("LIVE SYSTEM SAMPLE")
            $summary.Add("Peak CPU: $(($samples.CpuPercent | ForEach-Object {[double]$_} | Measure-Object -Maximum).Maximum)%")
            $summary.Add("Peak CPU DPC: $(($samples.CpuDpcPercent | ForEach-Object {[double]$_} | Measure-Object -Maximum).Maximum)%")
            $summary.Add("Lowest available RAM: $(($samples.AvailableMemoryMB | ForEach-Object {[double]$_} | Measure-Object -Minimum).Minimum) MB")
            $summary.Add("Peak committed RAM: $(($samples.CommittedMemoryPercent | ForEach-Object {[double]$_} | Measure-Object -Maximum).Maximum)%")
            $summary.Add("Peak disk busy: $(($samples.DiskBusyPercent | ForEach-Object {[double]$_} | Measure-Object -Maximum).Maximum)%")
            $summary.Add("")
        }
    }

    if (Test-Path -LiteralPath $liveGpuPath) {
        $summary.Add("NVIDIA live telemetry was captured in 09-Live-Telemetry\nvidia-gpu.csv.")
    }
    else {
        $summary.Add("NVIDIA live telemetry was not available.")
    }
    if (Test-Path -LiteralPath $liveAmdGpuPath) {
        $summary.Add("AMD live telemetry was captured in 09-Live-Telemetry\amd-gpu.jsonl.")
    }
    else {
        $summary.Add("AMD SMI live telemetry was not available.")
    }
    $summary.Add("Vendor-neutral Windows GPU-engine telemetry is in 09-Live-Telemetry\gpu-engines.csv.")

    $summary.Add("Steam roots found: $($steamRoots.Count)")
    $summary.Add("Steam library roots found: $($steamLibraries.Count)")
    $summary.Add("Copied application-log data: $([math]::Round($script:CopiedBytes / 1MB, 1)) MB")
    $summary.Add("")
    $summary.Add("Start with:")
    $summary.Add("1. 00-Summary\pattern-counts.csv")
    $summary.Add("2. 00-Summary\SUMMARY.txt")
    $summary.Add("3. 03-GPU\gpu-vendors.csv and vendor-specific telemetry")
    $summary.Add("4. 06-Windows-Events")
    $summary.Add("5. 05-Application-Logs")
    $summary.Add("")
    $summary.Add("Pattern counts are clues, not proof. Check matching log lines and timestamps.")
    $summary.Add("Review the ZIP before posting it publicly.")

    $summary | Set-Content -LiteralPath (Join-Path $dirs.Summary "SUMMARY.txt") -Encoding UTF8
}

Redact-CopiedText

Invoke-Step "Creating file manifest" {
    $manifestPath = Join-Path $dirs.Root "MANIFEST.csv"
    Get-ChildItem -LiteralPath $dirs.Root -Recurse -File |
        Where-Object { $_.FullName -ne $manifestPath } |
        ForEach-Object {
            [pscustomobject]@{
                RelativePath = $_.FullName.Substring($dirs.Root.Length + 1)
                Length = $_.Length
                LastWriteTime = $_.LastWriteTime.ToString("o")
                SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        } |
        Export-Csv -LiteralPath $manifestPath `
            -NoTypeInformation -Encoding UTF8
}

Invoke-Step "Creating ZIP archive" {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -LiteralPath $dirs.Root -DestinationPath $zipPath `
        -CompressionLevel Optimal -Force
}

if (Test-Path -LiteralPath $zipPath) {
    try {
        Remove-Item -LiteralPath $dirs.Root -Recurse -Force
    }
    catch {
        Write-Warning "The ZIP was created, but the temporary folder could not be removed: $($dirs.Root)"
    }

    Write-Host ""
    Write-Host "Diagnostic package complete." -ForegroundColor Green
    Write-Host "Send this ZIP for review:" -ForegroundColor Green
    Write-Host $zipPath -ForegroundColor Cyan
}
else {
    Write-Host ""
    Write-Host "ZIP creation failed. The uncompressed files remain here:" -ForegroundColor Yellow
    Write-Host $dirs.Root -ForegroundColor Yellow
}

Write-Host ""
Read-Host "Press ENTER to close"
