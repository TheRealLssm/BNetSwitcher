#--------------------------------------
# Build Script: Compile PS1 to EXE
#--------------------------------------
# This script converts bnet-switcher-gui.ps1 to an executable using PS2EXE
# For manual installation, visit: https://github.com/MScholtes/PS2EXE/releases
#
# SECURITY & PRIVACY NOTICE:
# - This script operates 100% OFFLINE - no internet required after initial ps2exe module install
# - No data collection, telemetry, or external communications
# - All operations are local machine only
# - The source code is readable PowerShell - you can inspect exactly what it does
# - PS2EXE is open source: https://github.com/MScholtes/PS2EXE/

param(
    [string]$SourceScript = "bnet-switcher-gui.ps1",
    [string]$OutputExe = "bnet-switcher.exe",
    [string]$IconPath = "bnet-switcher.ico"
)

$ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourceFull = Join-Path $ScriptPath $SourceScript

if (-not (Test-Path $SourceFull)) {
    Write-Error "Source script not found: $SourceFull"
    exit 1
}

$OutputFull = Join-Path $ScriptPath $OutputExe

# Resolve IconPath to absolute path if it's relative
if (-not [string]::IsNullOrEmpty($IconPath) -and -not [System.IO.Path]::IsPathRooted($IconPath)) {
    $IconPath = Join-Path $ScriptPath $IconPath
}

# Check for ps2exe module
$ps2exeAvailable = $false

# First, try to find ps2exe module
$ps2exeModule = Get-Module -Name ps2exe -ListAvailable -ErrorAction SilentlyContinue
if ($ps2exeModule) {
    Write-Host "ps2exe module found" -ForegroundColor Green
    $ps2exeAvailable = $true
} else {
    Write-Host "Installing ps2exe module..." -ForegroundColor Cyan
    try {
        Install-Module ps2exe -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        Write-Host "ps2exe module installed successfully" -ForegroundColor Green
        Import-Module ps2exe -ErrorAction Stop | Out-Null
        $ps2exeAvailable = $true
    } catch {
        Write-Host "Failed to install ps2exe module: $_" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Setup PS2EXE manually:" -ForegroundColor Cyan
        Write-Host "  1. Visit: https://github.com/MScholtes/PS2EXE/releases" -ForegroundColor White
        Write-Host "  2. Run: Install-Module ps2exe -Scope CurrentUser" -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

if (-not $ps2exeAvailable) {
    Write-Error "ps2exe not available"
    exit 1
}

# Build command with parameters
$buildParams = @{
    inputFile   = $SourceFull
    outputFile  = $OutputFull
    x64         = $true
    noConsole   = $true
}

if (-not [string]::IsNullOrEmpty($IconPath)) {
    $buildParams['iconFile'] = $IconPath
}

# A running instance holds a lock on the exe, and ps2exe cannot replace it.
# Without this check the build below fails but still leaves the OLD exe in
# place, which used to be reported as success.
$exeName = [System.IO.Path]::GetFileNameWithoutExtension($OutputExe)
$running = @(Get-Process -Name $exeName -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Host ""
    Write-Host "$OutputExe is currently running (PID $($running.Id -join ', '))." -ForegroundColor Yellow
    Write-Host "Close it before building, or the old executable stays in place." -ForegroundColor Yellow
    exit 1
}

# Remember the current build so we can prove a new one replaced it
$previousWrite = $null
if (Test-Path $OutputFull) { $previousWrite = (Get-Item $OutputFull).LastWriteTime }

Write-Host "Building EXE..." -ForegroundColor Cyan
Write-Host "  Source: $SourceFull"
Write-Host "  Output: $OutputFull"
if (-not [string]::IsNullOrEmpty($IconPath)) {
    Write-Host "  Icon: $IconPath"
}
Write-Host ""

# Build the EXE
Write-Host "Command: ps2exe -inputFile '$SourceFull' -outputFile '$OutputFull' -x64 -noConsole$(if (-not [string]::IsNullOrEmpty($IconPath)) { " -iconFile '$IconPath'" })" -ForegroundColor Gray
$buildOutput = ps2exe @buildParams 2>&1
if ($buildOutput) {
    Write-Host $buildOutput
}
# Verify output. Existence alone is not proof: a failed build leaves the
# previous executable untouched, so require that it was actually rewritten.
if (-not (Test-Path $OutputFull)) {
    Write-Error "Build failed: output file was not created."
    exit 1
}

$newWrite = (Get-Item $OutputFull).LastWriteTime
if ($previousWrite -and $newWrite -le $previousWrite) {
    Write-Error "Build failed: $OutputExe was not replaced - it is still the previous build (last written $newWrite). Check the ps2exe output above."
    exit 1
}

Write-Host ""
Write-Host "Build complete!" -ForegroundColor Green
Write-Host "Output: $OutputFull" -ForegroundColor Green
Write-Host "Built:  $newWrite" -ForegroundColor Green
$fileSize = (Get-Item $OutputFull).Length / 1MB
Write-Host "Size: $([math]::Round($fileSize, 2)) MB" -ForegroundColor Green
