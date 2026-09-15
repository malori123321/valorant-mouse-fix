#Requires -Version 5.1
<#
.SYNOPSIS
    Detects and fixes a stale MaxResolution value in the Windows Monitor class
    registry entry that Valorant targets, as described in:
    "Fix: Uncontrolled / Disconnected Mouse Feel in Valorant  -  Wrong MaxResolution
    in Monitor Registry Entry"

.DESCRIPTION
    1. Locates Valorant's GameUserSettings.ini and reads DefaultMonitorDeviceID
       to find exactly which monitor registry key the game is targeting
       (instead of guessing / hardcoding a GUID+instance).
    2. Reads the actual current resolution Windows is using for that display.
    3. Compares it against the MaxResolution value stored in:
         HKLM\SYSTEM\CurrentControlSet\Control\Class\{GUID}\<instance>
         HKLM\SYSTEM\CurrentControlSet\Control\Class\{GUID}\<instance>\Configuration\Driver
    4. If they don't match, backs up both keys (reg export) and corrects
       MaxResolution / $!MaxResolution to the real resolution.

.NOTES
    - Self-elevates: if not already running as Administrator, it relaunches
      itself with a UAC prompt automatically. You do not need to manually
      open an elevated PowerShell  -  just run this script normally.
    - This is community-documented, NOT an official/confirmed fix  -  read the
      README's "Caveats / honesty section" before relying on this.
    - Always keep the .reg backups this script creates until you've confirmed
      everything still works as expected.
#>

# ---------------------------------------------------------------------------
# 0. Self-elevate if not already running as Administrator
# ---------------------------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Not running as Administrator  -  relaunching with elevation..." -ForegroundColor Yellow
    $scriptPath = $MyInvocation.MyCommand.Definition
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoExit -ExecutionPolicy Bypass -File `"$scriptPath`"" `
        -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"

function Write-Section($text) {
    Write-Host "`n=== $text ===" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. Find Valorant's GameUserSettings.ini
# ---------------------------------------------------------------------------
Write-Section "Locating GameUserSettings.ini"

$searchRoots = @(
    "$env:LOCALAPPDATA\VALORANT\Saved\Config",
    "$env:USERPROFILE\Saved Games\VALORANT",
    "$env:LOCALAPPDATA"
)

$iniFile = $null
foreach ($root in $searchRoots) {
    if (Test-Path $root) {
        $found = Get-ChildItem -Path $root -Filter "GameUserSettings.ini" -Recurse -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) { $iniFile = $found.FullName; break }
    }
}

if (-not $iniFile) {
    Write-Host "Could not auto-locate GameUserSettings.ini." -ForegroundColor Yellow
    $iniFile = Read-Host "Paste the full path to your GameUserSettings.ini manually"
}

if (-not (Test-Path $iniFile)) {
    throw "File not found: $iniFile"
}

Write-Host "Using: $iniFile"

# ---------------------------------------------------------------------------
# 2. Extract MONITOR\<HWID>\{GUID}\<instance> from DefaultMonitorDeviceID
# ---------------------------------------------------------------------------
Write-Section "Reading DefaultMonitorDeviceID"

$content = Get-Content -Path $iniFile -Raw
$match = [regex]::Match($content, 'DefaultMonitorDeviceID="MONITOR\\+([^\\]+)\\+(\{[0-9a-fA-F-]+\})\\+([0-9A-Fa-f]+)"')

if (-not $match.Success) {
    throw "Could not find a DefaultMonitorDeviceID line in $iniFile. Launch Valorant at least once and pick a display, then re-run this script."
}

$hwid      = $match.Groups[1].Value
$classGuid = $match.Groups[2].Value
$instance  = $match.Groups[3].Value

Write-Host "Hardware ID   : $hwid"
Write-Host "Class GUID    : $classGuid"
Write-Host "Instance      : $instance"

$regBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$classGuid\$instance"
$regDriver = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$classGuid\Configuration\Driver"

if (-not (Test-Path $regBase)) {
    throw "Registry path not found: $regBase (unexpected  -  did the ini parse correctly?)"
}

$driverKeyExists = Test-Path $regDriver
if (-not $driverKeyExists) {
    Write-Host "Note: $regDriver does not exist on this system - will only fix the main instance key." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 3. Get the real current resolution for comparison
# ---------------------------------------------------------------------------
Write-Section "Detecting actual current resolution"

Add-Type -AssemblyName System.Windows.Forms
$primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$realWidth  = $primary.Width
$realHeight = $primary.Height
$realRes = "$realWidth,$realHeight"

Write-Host "Windows reports current resolution as: $realRes"
Write-Host "(If this looks wrong  -  e.g. you're on an external monitor right now  - "
Write-Host " press Ctrl+C and re-run this on the display Valorant actually targets.)"

# ---------------------------------------------------------------------------
# 4. Compare and fix
# ---------------------------------------------------------------------------
Write-Section "Checking registry values"

$currentMain   = (Get-ItemProperty -Path $regBase -Name "MaxResolution" -ErrorAction SilentlyContinue).MaxResolution
$currentDriver = if ($driverKeyExists) {
    (Get-ItemProperty -Path $regDriver -Name "`$!MaxResolution" -ErrorAction SilentlyContinue)."`$!MaxResolution"
} else { $null }

Write-Host "Main key MaxResolution         : $currentMain"
Write-Host "Configuration\Driver MaxResolution : $currentDriver"

$mainMatches   = ($currentMain -eq $realRes)
$driverMatches = (-not $driverKeyExists) -or ($currentDriver -eq $realRes)

$modesPath = Join-Path $regBase "MODES"
$modesMatches = $true
if (Test-Path $modesPath) {
    $staleModeKeys = Get-ChildItem -Path $modesPath -ErrorAction SilentlyContinue |
                     Where-Object { $_.PSChildName -ne $realRes }
    if ($staleModeKeys) { $modesMatches = $false }
}

if ($mainMatches -and $driverMatches -and $modesMatches) {
    Write-Host "`nNothing to fix  -  values already match your real resolution ($realRes)." -ForegroundColor Green
    exit 0
}

Write-Host "`nMismatch detected. Preparing to fix..." -ForegroundColor Yellow

# --- Backup first ---
Write-Section "Backing up registry keys"

$backupDir = Join-Path $env:USERPROFILE "Desktop\monitor_registry_backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$backupMainFile   = Join-Path $backupDir "monitor_main_key.reg"
$backupDriverFile = Join-Path $backupDir "monitor_driver_key.reg"

$regBaseNative   = "HKLM\SYSTEM\CurrentControlSet\Control\Class\$classGuid\$instance"
$regDriverNative = "HKLM\SYSTEM\CurrentControlSet\Control\Class\$classGuid\Configuration\Driver"

reg export $regBaseNative $backupMainFile /y | Out-Null
if ($driverKeyExists) {
    reg export $regDriverNative $backupDriverFile /y | Out-Null
}

Write-Host "Backups saved to: $backupDir" -ForegroundColor Green

# --- Confirm before writing ---
$confirm = Read-Host "`nAbout to set MaxResolution to '$realRes'. Continue? (y/n)"
if ($confirm -ne "y") {
    Write-Host "Aborted, no changes made." -ForegroundColor Yellow
    exit 0
}

# --- Apply fix ---
Write-Section "Applying fix"

if (-not $mainMatches) {
    Set-ItemProperty -Path $regBase -Name "MaxResolution" -Value $realRes -Type String
    Write-Host "Updated main key." -ForegroundColor Green
}

# The MODES subkey is a registry KEY named after the resolution (e.g. "1600,1200"),
# not a value -- Set-ItemProperty can't touch it, it needs Rename-Item. This runs
# regardless of whether MaxResolution itself already matched, since a previous run
# may have fixed the value but not this key.
$modesPath = Join-Path $regBase "MODES"
if (Test-Path $modesPath) {
    $existingModeKeys = Get-ChildItem -Path $modesPath -ErrorAction SilentlyContinue
    $staleKey = $existingModeKeys | Where-Object { $_.PSChildName -ne $realRes } | Select-Object -First 1

    if ($staleKey) {
        $oldModeKey = $staleKey.PSPath
        $newModeKey = Join-Path $modesPath $realRes
        if (-not (Test-Path $newModeKey)) {
            $oldModeKeyNative = "HKLM\SYSTEM\CurrentControlSet\Control\Class\$classGuid\$instance\MODES\$($staleKey.PSChildName)"
            reg export $oldModeKeyNative (Join-Path $backupDir "modes_key_$($staleKey.PSChildName -replace ',','_').reg") /y | Out-Null
            Rename-Item -Path $oldModeKey -NewName $realRes
            Write-Host "Renamed MODES\$($staleKey.PSChildName) to MODES\$realRes." -ForegroundColor Green
        } else {
            Write-Host "MODES\$realRes already exists -- leaving MODES\$($staleKey.PSChildName) untouched." -ForegroundColor Yellow
        }
    } else {
        Write-Host "MODES already correct, nothing to rename." -ForegroundColor Green
    }
}
if ($driverKeyExists -and -not $driverMatches) {
    Set-ItemProperty -Path $regDriver -Name "`$!MaxResolution" -Value $realRes -Type String
    Write-Host "Updated Configuration\Driver key." -ForegroundColor Green
}

Write-Host "Done. New value: $realRes" -ForegroundColor Green
Write-Host "`nA full restart is recommended before testing in Valorant." -ForegroundColor Cyan
