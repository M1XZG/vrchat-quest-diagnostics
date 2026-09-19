#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$collector = Join-Path $repositoryRoot "Collect-VRChat-Quest-Diagnostics.ps1"

if (-not (Test-Path -LiteralPath $collector -PathType Leaf)) {
    throw "Collector not found: $collector"
}

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $collector,
    [ref]$tokens,
    [ref]$parseErrors
) | Out-Null

if ($parseErrors.Count -gt 0) {
    $parseErrors | Format-List
    throw "PowerShell parser reported $($parseErrors.Count) error(s)."
}

$content = Get-Content -LiteralPath $collector -Raw
$requiredPatterns = @{
    "Administrator elevation" = "Test-Administrator"
    "Privacy redaction" = "Redact-CopiedText"
    "Opt-in crash dumps" = "IncludeCrashDumps"
    "NVIDIA telemetry" = "Get-NvidiaSmi"
    "AMD telemetry" = "Get-AmdSmi"
    "Vendor-neutral GPU telemetry" = "GPUPerformanceCounters_GPUEngine"
    "Live network telemetry" = "liveNetworkPath"
    "Gateway latency telemetry" = "liveGatewayPath"
    "Headset latency telemetry" = "liveHeadsetPath"
    "Steam Link health telemetry" = "liveSteamLinkPath"
    "Graceful early stop" = "ConsoleKey]::Enter"
    "Post-sample log refresh" = "Refreshing logs generated during the live sample"
}

foreach ($entry in $requiredPatterns.GetEnumerator()) {
    if ($content -notmatch [regex]::Escape($entry.Value)) {
        throw "Missing required collector feature: $($entry.Key)"
    }
}

Write-Host "Collector validation passed." -ForegroundColor Green
