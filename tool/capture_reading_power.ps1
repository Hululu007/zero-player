# Read-only Android power snapshots. Never resets batterystats or changes settings.
param(
    [string]$PackageId = 'dev.zeroplayer.zero_player.devtest',
    [string]$Serial,
    [ValidateRange(30, 3600)][int]$DurationSeconds = 600,
    [ValidateRange(10, 60)][int]$IntervalSeconds = 30,
    [string]$Scenario = 'reading-static',
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
if ($PackageId -notmatch '^[a-zA-Z0-9_.]+$') { throw 'Invalid package id' }
if (!(Get-Command adb -ErrorAction SilentlyContinue)) { throw 'adb is not on PATH' }
$adbArguments = @()
if ($Serial) { $adbArguments = @('-s', $Serial) }
$projectRoot = Split-Path $PSScriptRoot -Parent
if (!$OutputDirectory) {
    $OutputDirectory = Join-Path $projectRoot ('build/reading-power/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

function Read-Adb([string[]]$Arguments, [string]$Name) {
    $content = & adb @adbArguments @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "adb failed: $Name" }
    $content | Set-Content -LiteralPath (Join-Path $outputRoot $Name) -Encoding utf8
}

$state = & adb @adbArguments get-state 2>&1
if ($LASTEXITCODE -ne 0 -or $state -notcontains 'device') { throw 'Select one connected Android device with -Serial' }
Read-Adb @('shell', 'getprop', 'ro.build.fingerprint') 'device.txt'
Read-Adb @('shell', 'dumpsys', 'package', $PackageId) 'package.txt'
Read-Adb @('shell', 'settings', 'get', 'system', 'screen_brightness') 'brightness.txt'
Read-Adb @('shell', 'settings', 'get', 'system', 'screen_brightness_mode') 'brightness-mode.txt'
Read-Adb @('shell', 'settings', 'get', 'global', 'low_power') 'power-saver.txt'
Read-Adb @('shell', 'dumpsys', 'batterystats', '--checkin', $PackageId) 'batterystats-before.txt'
Read-Adb @('shell', 'dumpsys', 'gfxinfo', $PackageId, 'framestats') 'frames-before.txt'
$timer = [Diagnostics.Stopwatch]::StartNew()
$samples = @()
do {
    $elapsed = [int]$timer.Elapsed.TotalSeconds
    $prefix = 'sample-{0:D4}' -f $elapsed
    Read-Adb @('shell', 'dumpsys', 'battery') "$prefix-battery.txt"
    Read-Adb @('shell', 'dumpsys', 'cpuinfo') "$prefix-cpu.txt"
    Read-Adb @('shell', 'dumpsys', 'meminfo', $PackageId) "$prefix-memory.txt"
    Read-Adb @('shell', 'dumpsys', 'thermalservice') "$prefix-thermal.txt"
    $samples += @{ seconds = $elapsed; timestamp = (Get-Date).ToUniversalTime().ToString('o'); prefix = $prefix }
    $remaining = $DurationSeconds - [int]$timer.Elapsed.TotalSeconds
    if ($remaining -le 0) { break }
    Start-Sleep -Seconds ([Math]::Min($IntervalSeconds, $remaining))
} while ($true)
Read-Adb @('shell', 'dumpsys', 'batterystats', '--checkin', $PackageId) 'batterystats-after.txt'
Read-Adb @('shell', 'dumpsys', 'gfxinfo', $PackageId, 'framestats') 'frames-after.txt'
@{ scenario = $Scenario; package = $PackageId; seconds = $timer.Elapsed.TotalSeconds;
   samples = $samples; readOnly = $true } | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $outputRoot 'capture.json') -Encoding utf8
Write-Output "Saved power snapshots to $outputRoot"
