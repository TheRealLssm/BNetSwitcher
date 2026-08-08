#======================================================================
# Battle.net Account Switcher - Dark Edition (v1.2)
# Based on BNetSwitcher by Nepero (https://github.com/Nepero27182/BNetSwitcher)
#
# SECURITY & PRIVACY NOTICE
# - Only modifies your LOCAL Battle.net.config (with automatic backup)
# - No passwords are read, stored, or transmitted - ever
# - The only network calls are:
#     1. Rank lookups against the public OverFast API (overfast-api.tekrop.fr)
#     2. Downloading official rank icon images from Blizzard's CDN
#   Both happen only for accounts where YOU entered a BattleTag.
# - Open source PowerShell - read everything it does right here.
#
# NOTE ON ACCOUNT STATUS
#   Blizzard publishes NO ban/suspension data, and no public API exposes it.
#   Status flags in this app are set BY YOU, manually. Nothing is auto-detected,
#   because any "detector" would be guessing and would mislabel good accounts.
#======================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# PowerShell 5.1 defaults to TLS 1.0 which modern APIs reject -> enable TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'
if ($env:BNS_SMOKETEST) { $ErrorActionPreference = 'Continue' }
else                    { $ErrorActionPreference = 'SilentlyContinue' }

#--------------------------------------
# NATIVE: dark title bar support
#--------------------------------------
if (-not ('BNS.Native' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace BNS {
    public static class Native {
        [DllImport("dwmapi.dll", PreserveSig = true)]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    }
}
"@
}

function Set-DarkTitleBar {
    param([System.Windows.Forms.Form]$TargetForm, [bool]$Dark)
    try {
        $v = 0; if ($Dark) { $v = 1 }
        # 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (19 on older Win10 builds)
        [void][BNS.Native]::DwmSetWindowAttribute($TargetForm.Handle, 20, [ref]$v, 4)
        [void][BNS.Native]::DwmSetWindowAttribute($TargetForm.Handle, 19, [ref]$v, 4)
    } catch { }
}

#--------------------------------------
# PATHS
#--------------------------------------
$script:ConfigPath = "$env:APPDATA\Battle.net\Battle.net.config"
if ($env:BNS_CONFIG_OVERRIDE) { $script:ConfigPath = $env:BNS_CONFIG_OVERRIDE }

$script:DataFolder = Join-Path $env:APPDATA 'BNetSwitcher'
if ($env:BNS_DATA_OVERRIDE) { $script:DataFolder = $env:BNS_DATA_OVERRIDE }

$script:AppRoot = $null
if ($PSScriptRoot) { $script:AppRoot = $PSScriptRoot }
elseif ($PSCommandPath) { $script:AppRoot = Split-Path -Parent $PSCommandPath }

$script:SettingsPath       = Join-Path $script:DataFolder 'settings.json'
$script:AccountStorePath   = Join-Path $script:DataFolder 'accounts.json'
$script:LegacyTagPath      = Join-Path $script:DataFolder 'battletags.json'
$script:IconCacheDir       = Join-Path $script:DataFolder 'rankicons'
$script:DebugLogPath       = Join-Path $script:DataFolder 'debug.log'
$script:RemovedLogPath     = Join-Path $script:DataFolder 'removed-accounts.json'

try {
    if (-not (Test-Path $script:DataFolder))   { New-Item -ItemType Directory -Path $script:DataFolder -Force | Out-Null }
    if (-not (Test-Path $script:IconCacheDir)) { New-Item -ItemType Directory -Path $script:IconCacheDir -Force | Out-Null }
} catch { }

# Non-ASCII glyphs built from char codes so file encoding can never garble them
$script:GlyphDot  = [string][char]0x25CF   # active-account marker
$script:GlyphDash = [string][char]0x2013   # unranked
$script:GlyphMask = [string][char]0x2022   # masked email

#--------------------------------------
# SETTINGS
#--------------------------------------
$script:DefaultSettings = @{
    Theme                  = 'Dark'    # Dark | Light | Auto
    Platform               = 'pc'      # pc | console
    ShowRankIcons          = $true
    FetchRanksOnStart      = $true
    AutoLaunchBattleNet    = $true
    LaunchOverwatch        = $false
    CloseAfterSwitch       = $true
    CloseOverwatchOnSwitch = $true
    StreamerMode           = $false
    DebugLogging           = $false
    WarnOnFlagged          = $true
    ConfirmRemoval         = $true
    WindowWidth            = 0
    WindowHeight           = 0
}

function Load-Settings {
    $s = @{}
    foreach ($k in $script:DefaultSettings.Keys) { $s[$k] = $script:DefaultSettings[$k] }
    if (Test-Path $script:SettingsPath) {
        try {
            $raw = Get-Content $script:SettingsPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $data = $raw | ConvertFrom-Json
                foreach ($prop in $data.PSObject.Properties) {
                    if ($s.ContainsKey($prop.Name)) { $s[$prop.Name] = $prop.Value }
                }
            }
        } catch { }
    }
    return $s
}

function Save-Settings {
    try { ($script:Settings | ConvertTo-Json) | Set-Content -Path $script:SettingsPath -Encoding UTF8 } catch { }
}

$script:Settings = Load-Settings

function Write-DebugLog {
    param([string]$Message)
    if (-not $script:Settings.DebugLogging) { return }
    try {
        Add-Content -Path $script:DebugLogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch { }
}

#--------------------------------------
# ACCOUNT METADATA STORE
#   accounts.json:  { "<email>": { BattleTag, Status, Note, Until } }
#   Status: OK | Watch | Suspended | Banned   (always user-set, never inferred)
#--------------------------------------
$script:StatusValues = @('OK', 'Watch', 'Suspended', 'Banned')

function New-AccountMeta {
    return @{ BattleTag = ''; Status = 'OK'; Note = ''; Until = '' }
}

function Load-AccountStore {
    $store = @{}
    if (Test-Path $script:AccountStorePath) {
        try {
            $raw = Get-Content $script:AccountStorePath -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $data = $raw | ConvertFrom-Json
                foreach ($prop in $data.PSObject.Properties) {
                    $meta = New-AccountMeta
                    $v = $prop.Value
                    if ($v -is [string]) {
                        $meta.BattleTag = $v            # tolerate old flat format
                    } else {
                        if ($v.BattleTag) { $meta.BattleTag = [string]$v.BattleTag }
                        if ($v.Status -and ($script:StatusValues -contains [string]$v.Status)) { $meta.Status = [string]$v.Status }
                        if ($v.Note)  { $meta.Note  = [string]$v.Note }
                        if ($v.Until) { $meta.Until = [string]$v.Until }
                    }
                    $store[$prop.Name] = $meta
                }
            }
        } catch { }
        return $store
    }

    # Migrate legacy battletags.json (data folder, then script folder)
    $legacyPaths = @($script:LegacyTagPath)
    if ($script:AppRoot) { $legacyPaths += (Join-Path $script:AppRoot 'battletags.json') }
    foreach ($lp in $legacyPaths) {
        if (Test-Path $lp) {
            try {
                $raw = Get-Content $lp -Raw
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $data = $raw | ConvertFrom-Json
                    foreach ($prop in $data.PSObject.Properties) {
                        $meta = New-AccountMeta
                        $meta.BattleTag = [string]$prop.Value
                        $store[$prop.Name] = $meta
                    }
                    Write-DebugLog "Migrated legacy battletags from $lp"
                    break
                }
            } catch { }
        }
    }
    return $store
}

function Save-AccountStore {
    try {
        $out = @{}
        foreach ($k in $script:AccountStore.Keys) {
            $m = $script:AccountStore[$k]
            $out[$k] = [pscustomobject]@{
                BattleTag = [string]$m.BattleTag
                Status    = [string]$m.Status
                Note      = [string]$m.Note
                Until     = [string]$m.Until
            }
        }
        ($out | ConvertTo-Json -Depth 5) | Set-Content -Path $script:AccountStorePath -Encoding UTF8
    } catch { }
}

function Get-AccountMeta {
    param([string]$Account)
    if ($script:AccountStore.ContainsKey($Account)) { return $script:AccountStore[$Account] }
    $m = New-AccountMeta
    $script:AccountStore[$Account] = $m
    return $m
}

$script:AccountStore = Load-AccountStore

function Get-StatusDisplay {
    param($Meta)
    $status = [string]$Meta.Status
    if ([string]::IsNullOrWhiteSpace($status) -or $status -eq 'OK') { return '' }
    if ($status -eq 'Suspended' -and -not [string]::IsNullOrWhiteSpace([string]$Meta.Until)) {
        try {
            $until = [datetime]::Parse([string]$Meta.Until)
            $days = [int][Math]::Ceiling(($until - (Get-Date)).TotalDays)
            if ($days -gt 0) { return "Suspended ($days d)" }
            return 'Suspended (expired)'
        } catch { }
    }
    return $status
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        'Banned'    { return [System.Drawing.Color]::FromArgb(255, 96, 96) }
        'Suspended' { return [System.Drawing.Color]::FromArgb(255, 170, 60) }
        'Watch'     { return [System.Drawing.Color]::FromArgb(240, 210, 90) }
        default     { return $script:Colors.Subtle }
    }
}

function Mask-Account {
    param([string]$Account)
    if ([string]::IsNullOrWhiteSpace($Account)) { return '' }
    $m = $script:GlyphMask * 3
    $at = $Account.IndexOf('@')
    if ($at -gt 2)      { return $Account.Substring(0, 2) + $m }
    elseif ($at -ge 0)  { return $m }
    elseif ($Account.Length -gt 3) { return $Account.Substring(0, 2) + $m }
    return $m
}

#--------------------------------------
# THEME
#--------------------------------------
function Get-WindowsLightTheme {
    try {
        $v = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction SilentlyContinue).AppsUseLightTheme
        if ($null -eq $v) { return $true }
        return ($v -eq 1)
    } catch { return $true }
}

function Get-ThemeColors {
    $mode = [string]$script:Settings.Theme
    if ($mode -eq 'Auto') {
        if (Get-WindowsLightTheme) { $mode = 'Light' } else { $mode = 'Dark' }
    }
    if ($mode -eq 'Light') {
        return @{
            IsDark        = $false
            FormBack      = [System.Drawing.Color]::FromArgb(245, 246, 248)
            Fore          = [System.Drawing.Color]::FromArgb(27, 31, 38)
            Subtle        = [System.Drawing.Color]::FromArgb(106, 115, 131)
            GridBack      = [System.Drawing.Color]::White
            GridAlt       = [System.Drawing.Color]::FromArgb(243, 244, 246)
            HeaderBack    = [System.Drawing.Color]::FromArgb(232, 234, 238)
            Border        = [System.Drawing.Color]::FromArgb(201, 206, 214)
            ButtonBack    = [System.Drawing.Color]::FromArgb(228, 231, 236)
            Accent        = [System.Drawing.Color]::FromArgb(0, 116, 224)
            AccentFore    = [System.Drawing.Color]::White
            Danger        = [System.Drawing.Color]::FromArgb(200, 40, 40)
            SelectionBack = [System.Drawing.Color]::FromArgb(204, 224, 245)
            SelectionFore = [System.Drawing.Color]::FromArgb(27, 31, 38)
        }
    }
    return @{
        IsDark        = $true
        FormBack      = [System.Drawing.Color]::FromArgb(20, 23, 28)
        Fore          = [System.Drawing.Color]::FromArgb(228, 231, 236)
        Subtle        = [System.Drawing.Color]::FromArgb(152, 161, 176)
        GridBack      = [System.Drawing.Color]::FromArgb(27, 31, 38)
        GridAlt       = [System.Drawing.Color]::FromArgb(32, 37, 46)
        HeaderBack    = [System.Drawing.Color]::FromArgb(38, 44, 54)
        Border        = [System.Drawing.Color]::FromArgb(51, 58, 70)
        ButtonBack    = [System.Drawing.Color]::FromArgb(42, 49, 61)
        Accent        = [System.Drawing.Color]::FromArgb(20, 142, 255)
        AccentFore    = [System.Drawing.Color]::White
        Danger        = [System.Drawing.Color]::FromArgb(214, 62, 62)
        SelectionBack = [System.Drawing.Color]::FromArgb(42, 74, 115)
        SelectionFore = [System.Drawing.Color]::White
    }
}

$script:Colors = Get-ThemeColors

#--------------------------------------
# BATTLE.NET CONFIG
#--------------------------------------
if (-not (Test-Path $script:ConfigPath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Battle.net.config not found at:`n$script:ConfigPath`n`nMake sure Battle.net is installed and has been launched at least once.",
        'Battle.net Account Switcher', 'OK', 'Error') | Out-Null
    exit 1
}

$script:Json = $null
try { $script:Json = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json } catch { }

$savedNames = $null
if ($script:Json -and $script:Json.Client) { $savedNames = [string]$script:Json.Client.SavedAccountNames }

$script:Accounts = @()
if ($savedNames) {
    $script:Accounts = @($savedNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ($script:Accounts.Count -eq 0) {
    [System.Windows.Forms.MessageBox]::Show(
        "No saved accounts found in Battle.net.config.`nLog into each account once via the Battle.net launcher first.",
        'Battle.net Account Switcher', 'OK', 'Error') | Out-Null
    exit 1
}

function Resolve-BattleNetExe {
    $candidates = @()
    try {
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Battle.net' -ErrorAction Stop
        if ($reg.InstallLocation) {
            $candidates += (Join-Path $reg.InstallLocation 'Battle.net Launcher.exe')
            $candidates += (Join-Path $reg.InstallLocation 'Battle.net.exe')
        }
    } catch { }
    $candidates += "${env:ProgramFiles(x86)}\Battle.net\Battle.net Launcher.exe"
    $candidates += "${env:ProgramFiles(x86)}\Battle.net\Battle.net.exe"
    $candidates += "$env:ProgramFiles\Battle.net\Battle.net Launcher.exe"
    $candidates += "$env:ProgramFiles\Battle.net\Battle.net.exe"
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

$script:BattleNetExe = Resolve-BattleNetExe

function Test-BattleNetRunning {
    if ($env:BNS_SMOKETEST) { return $false }
    return [bool](Get-Process 'Battle.net' -ErrorAction SilentlyContinue)
}

function Save-BattleNetConfig {
    # Rewrites SavedAccountNames from $script:Accounts. Returns $true on success.
    try { Copy-Item $script:ConfigPath "$($script:ConfigPath).backup" -Force } catch { }
    try {
        $script:Json.Client.SavedAccountNames = ($script:Accounts -join ',')
        $script:Json | ConvertTo-Json -Depth 100 | Out-File $script:ConfigPath -Encoding UTF8
        return $true
    } catch {
        Set-Status 'ERROR: could not write Battle.net.config (is it locked by Battle.net?)'
        return $false
    }
}

#--------------------------------------
# IMAGE CACHE (rank icons, loaded without file locks)
#--------------------------------------
$script:ImageCache = @{}

function Get-CachedImage {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($script:ImageCache.ContainsKey($Path)) { return $script:ImageCache[$Path] }
    if (-not (Test-Path $Path)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        $img = [System.Drawing.Image]::FromStream($ms)
        $script:ImageCache[$Path] = $img
        return $img
    } catch { return $null }
}

#--------------------------------------
# ASYNC RANK FETCHING
#--------------------------------------
$script:RoleColumns = @('Tank', 'DPS', 'Support', 'OpenQueue')

$script:FetchScript = @'
param($BattleTag, $Platform, $CacheDir)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
$ErrorActionPreference = 'Stop'

$result = @{ Ok = $false; Error = ''; Season = $null; Username = ''; Updated = $null; Roles = @{} }
$dash = [string][char]0x2013

$normalized = ($BattleTag.Trim() -replace '\s', '') -replace '#', '-'
$normalized = [Uri]::EscapeDataString($normalized)

try {
    $resp = Invoke-RestMethod -Uri "https://overfast-api.tekrop.fr/players/$normalized/summary" -UseBasicParsing -TimeoutSec 15
    $comp = $null
    if ($resp.competitive) { $comp = $resp.competitive.$Platform }
    if ($comp -and $comp.season) { $result.Season = $comp.season }
    if ($resp.username) { $result.Username = [string]$resp.username }
    if ($resp.last_updated_at) { $result.Updated = [long]$resp.last_updated_at }

    $map = @(
        @('Tank', 'tank'),
        @('DPS', 'damage'),
        @('Support', 'support'),
        @('OpenQueue', 'open')
    )
    foreach ($pair in $map) {
        $col = $pair[0]; $key = $pair[1]
        $node = $null
        if ($comp) { $node = $comp.$key }
        if ($node -and $node.division) {
            $div = ([string]$node.division)
            $div = $div.Substring(0, 1).ToUpper() + $div.Substring(1)
            $text = "$div $($node.tier)"
            $iconPath = ''
            if ($node.rank_icon) {
                try {
                    $fname = [System.IO.Path]::GetFileName(([Uri]$node.rank_icon).AbsolutePath)
                    $fname = $fname -replace '[^A-Za-z0-9_.-]', '_'
                    $iconPath = Join-Path $CacheDir $fname
                    if (-not (Test-Path $iconPath)) {
                        Invoke-WebRequest -Uri $node.rank_icon -OutFile $iconPath -UseBasicParsing -TimeoutSec 15
                    }
                } catch { $iconPath = '' }
            }
            $result.Roles[$col] = @{ Text = $text; Icon = $iconPath }
        } else {
            $result.Roles[$col] = @{ Text = $dash; Icon = '' }
        }
    }
    $result.Ok = $true
} catch {
    $msg = [string]$_.Exception.Message
    if     ($msg -match '404')       { $result.Error = 'Not found' }
    elseif ($msg -match '422')       { $result.Error = 'Bad tag' }
    elseif ($msg -match '429|503')   { $result.Error = 'Rate limited' }
    elseif ($msg -match 'timed out') { $result.Error = 'Timeout' }
    else                             { $result.Error = 'API error' }
}
$result
'@

$script:RunspacePool = [runspacefactory]::CreateRunspacePool(1, 4)
$script:RunspacePool.Open()
$script:Jobs = New-Object System.Collections.ArrayList

function Start-RankFetch {
    param($Row, [string]$BattleTag)
    if ($null -eq $Row -or [string]::IsNullOrWhiteSpace($BattleTag)) { return }
    foreach ($col in $script:RoleColumns) {
        $Row.Cells[$col].Value = '...'
        $Row.Cells[$col].Tag = $null
        $Row.Cells[$col].ToolTipText = ''
    }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:RunspacePool
    [void]$ps.AddScript($script:FetchScript).AddArgument($BattleTag).AddArgument([string]$script:Settings.Platform).AddArgument($script:IconCacheDir)
    $handle = $ps.BeginInvoke()
    [void]$script:Jobs.Add(@{ PS = $ps; Handle = $handle; Row = $Row; BattleTag = $BattleTag.Trim() })
    Write-DebugLog "Queued rank fetch for $BattleTag"
}

function Start-AllRankFetches {
    foreach ($row in $script:Grid.Rows) {
        $bt = [string]$row.Cells['BattleTag'].Value
        if (-not [string]::IsNullOrWhiteSpace($bt)) { Start-RankFetch -Row $row -BattleTag $bt }
    }
    if ($script:Jobs.Count -gt 0) { Set-Status "Fetching ranks for $($script:Jobs.Count) account(s)..." }
}

function Process-RankJobs {
    $completed = @($script:Jobs | Where-Object { $_.Handle.IsCompleted })
    foreach ($job in $completed) {
        $out = $null
        try { $out = $job.PS.EndInvoke($job.Handle) } catch { }
        try { $job.PS.Dispose() } catch { }
        $script:Jobs.Remove($job)

        $row = $job.Row
        if ($null -eq $row -or $null -eq $row.DataGridView) { continue }   # row was removed
        $currentTag = ([string]$row.Cells['BattleTag'].Value)
        if ($currentTag.Trim() -ne $job.BattleTag) { continue }            # tag edited meanwhile

        $res = $null
        if ($out) { $res = $out | Select-Object -Last 1 }

        if (-not $res -or -not $res.Ok) {
            $err = 'API error'
            if ($res -and $res.Error) { $err = [string]$res.Error }
            foreach ($col in $script:RoleColumns) {
                $row.Cells[$col].Value = $err
                $row.Cells[$col].Tag = $null
                $row.Cells[$col].ToolTipText = "Rank lookup failed for $($job.BattleTag): $err`n(This says nothing about ban status - see Set status.)"
            }
            Write-DebugLog "Fetch failed for $($job.BattleTag): $err"
        } else {
            $seasonText = ''
            if ($res.Season) { $seasonText = " (Season $($res.Season))" }
            foreach ($col in $script:RoleColumns) {
                $roleData = $res.Roles[$col]
                if ($roleData) {
                    $row.Cells[$col].Value = [string]$roleData.Text
                    $row.Cells[$col].Tag = Get-CachedImage ([string]$roleData.Icon)
                    $row.Cells[$col].ToolTipText = "$($script:Grid.Columns[$col].HeaderText): $($roleData.Text)$seasonText"
                }
            }
            if ($res.Username) { $row.Cells['BattleTag'].ToolTipText = "Profile: $($res.Username)$seasonText" }
            Write-DebugLog "Fetch OK for $($job.BattleTag)"
        }
        $script:Grid.InvalidateRow($row.Index)
    }
    if ($script:Jobs.Count -eq 0) {
        if ($script:StatusLabel.Text -like 'Fetching*') { Set-Status 'Ready' }
    } else {
        Set-Status "Fetching ranks ($($script:Jobs.Count) remaining)..."
    }
}

#--------------------------------------
# GUI
#--------------------------------------
$initW = 1080; $initH = 540
if ([int]$script:Settings.WindowWidth -ge 900)  { $initW = [int]$script:Settings.WindowWidth }
if ([int]$script:Settings.WindowHeight -ge 420) { $initH = [int]$script:Settings.WindowHeight }

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Battle.net Account Switcher'
$script:Form.Size = New-Object System.Drawing.Size($initW, $initH)
$script:Form.MinimumSize = New-Object System.Drawing.Size(900, 420)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.KeyPreview = $true

$iconLoaded = $false
if ($script:AppRoot) {
    $icoFile = Join-Path $script:AppRoot 'bnet-switcher.ico'
    if (Test-Path $icoFile) {
        try { $script:Form.Icon = New-Object System.Drawing.Icon($icoFile); $iconLoaded = $true } catch { }
    }
}
if (-not $iconLoaded) {
    try {
        $ownExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $script:Form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ownExe)
    } catch { }
}

$pad = 14
$btnRowH = 40
$statusH = 24

$script:Grid = New-Object System.Windows.Forms.DataGridView
$script:Grid.Location = New-Object System.Drawing.Point($pad, $pad)
$gridW = $script:Form.ClientSize.Width - (2 * $pad)
$gridH = $script:Form.ClientSize.Height - (2 * $pad) - $btnRowH - $statusH - 16
$script:Grid.Size = New-Object System.Drawing.Size($gridW, $gridH)
$script:Grid.Anchor = 'Top,Bottom,Left,Right'
$script:Grid.AllowUserToAddRows = $false
$script:Grid.AllowUserToDeleteRows = $false
$script:Grid.AllowUserToResizeRows = $false
$script:Grid.MultiSelect = $false
$script:Grid.SelectionMode = 'FullRowSelect'
$script:Grid.RowHeadersVisible = $false
$script:Grid.AutoSizeColumnsMode = 'Fill'
$script:Grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$script:Grid.ColumnHeadersHeight = 34
$script:Grid.RowTemplate.Height = 36
$script:Grid.EnableHeadersVisualStyles = $false
$script:Grid.BorderStyle = 'FixedSingle'
$script:Grid.CellBorderStyle = 'SingleHorizontal'
$script:Grid.ColumnHeadersBorderStyle = 'Single'
$script:Grid.EditMode = 'EditOnEnter'
$script:Grid.ShowCellToolTips = $true

$dbProp = $script:Grid.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
if ($dbProp) { $dbProp.SetValue($script:Grid, $true, $null) }

[void]$script:Grid.Columns.Add('Account',   'Account')
[void]$script:Grid.Columns.Add('Status',    'Status')
[void]$script:Grid.Columns.Add('BattleTag', 'BattleTag')
[void]$script:Grid.Columns.Add('Tank',      'Tank')
[void]$script:Grid.Columns.Add('DPS',       'Damage')
[void]$script:Grid.Columns.Add('Support',   'Support')
[void]$script:Grid.Columns.Add('OpenQueue', 'Open Queue')

$script:Grid.Columns['Account'].ReadOnly   = $true
$script:Grid.Columns['Status'].ReadOnly    = $true
$script:Grid.Columns['BattleTag'].ReadOnly = $false
foreach ($col in $script:RoleColumns) { $script:Grid.Columns[$col].ReadOnly = $true }

$script:Grid.Columns['Account'].FillWeight   = 24
$script:Grid.Columns['Status'].FillWeight    = 13
$script:Grid.Columns['BattleTag'].FillWeight = 19
$script:Grid.Columns['Tank'].FillWeight      = 11
$script:Grid.Columns['DPS'].FillWeight       = 11
$script:Grid.Columns['Support'].FillWeight   = 11
$script:Grid.Columns['OpenQueue'].FillWeight = 13

foreach ($c in $script:Grid.Columns) { $c.SortMode = 'NotSortable' }

$script:Form.Controls.Add($script:Grid)

$script:SwitchBtn = New-Object System.Windows.Forms.Button
$script:SwitchBtn.Text = 'Switch Account'
$script:SwitchBtn.Size = New-Object System.Drawing.Size(200, $btnRowH)
$script:SwitchBtn.Anchor = 'Bottom,Left'

$script:RefreshBtn = New-Object System.Windows.Forms.Button
$script:RefreshBtn.Text = 'Refresh Ranks  (F5)'
$script:RefreshBtn.Size = New-Object System.Drawing.Size(155, $btnRowH)
$script:RefreshBtn.Anchor = 'Bottom,Left'

$script:StatusBtn = New-Object System.Windows.Forms.Button
$script:StatusBtn.Text = 'Set Status'
$script:StatusBtn.Size = New-Object System.Drawing.Size(115, $btnRowH)
$script:StatusBtn.Anchor = 'Bottom,Left'

$script:RemoveBtn = New-Object System.Windows.Forms.Button
$script:RemoveBtn.Text = 'Remove'
$script:RemoveBtn.Size = New-Object System.Drawing.Size(115, $btnRowH)
$script:RemoveBtn.Anchor = 'Bottom,Left'

$script:SettingsBtn = New-Object System.Windows.Forms.Button
$script:SettingsBtn.Text = 'Settings'
$script:SettingsBtn.Size = New-Object System.Drawing.Size(110, $btnRowH)
$script:SettingsBtn.Anchor = 'Bottom,Left'

$btnY = $script:Form.ClientSize.Height - $btnRowH - $statusH - 8
$bx = $pad
$script:SwitchBtn.Location   = New-Object System.Drawing.Point($bx, $btnY); $bx += 210
$script:RefreshBtn.Location  = New-Object System.Drawing.Point($bx, $btnY); $bx += 165
$script:StatusBtn.Location   = New-Object System.Drawing.Point($bx, $btnY); $bx += 125
$script:RemoveBtn.Location   = New-Object System.Drawing.Point($bx, $btnY); $bx += 125
$script:SettingsBtn.Location = New-Object System.Drawing.Point($bx, $btnY)

$script:Form.Controls.Add($script:SwitchBtn)
$script:Form.Controls.Add($script:RefreshBtn)
$script:Form.Controls.Add($script:StatusBtn)
$script:Form.Controls.Add($script:RemoveBtn)
$script:Form.Controls.Add($script:SettingsBtn)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Location = New-Object System.Drawing.Point($pad, ($script:Form.ClientSize.Height - $statusH))
$script:StatusLabel.Size = New-Object System.Drawing.Size(($script:Form.ClientSize.Width - 2 * $pad), 18)
$script:StatusLabel.Anchor = 'Bottom,Left,Right'
$script:StatusLabel.TextAlign = 'MiddleLeft'
$script:Form.Controls.Add($script:StatusLabel)

function Set-Status {
    param([string]$Text)
    if ($script:StatusLabel) { $script:StatusLabel.Text = $Text }
}

#--------------------------------------
# THEME APPLICATION
#--------------------------------------
function Style-Button {
    param($Button, [string]$Kind = 'normal')   # normal | primary | danger
    $Button.FlatStyle = 'Flat'
    $Button.Font = New-Object System.Drawing.Font('Segoe UI', 10.5)
    $Button.UseVisualStyleBackColor = $false
    if ($Kind -eq 'primary' -or $Kind -eq 'danger') {
        $base = $script:Colors.Accent
        if ($Kind -eq 'danger') { $base = $script:Colors.Danger }
        $Button.BackColor = $base
        $Button.ForeColor = $script:Colors.AccentFore
        $Button.FlatAppearance.BorderSize = 0
        $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(
            [Math]::Min(255, [int]$base.R + 25),
            [Math]::Min(255, [int]$base.G + 25),
            [Math]::Min(255, [int]$base.B + 25))
    } else {
        $Button.BackColor = $script:Colors.ButtonBack
        $Button.ForeColor = $script:Colors.Fore
        $Button.FlatAppearance.BorderSize = 1
        $Button.FlatAppearance.BorderColor = $script:Colors.Border
        $Button.FlatAppearance.MouseOverBackColor = $script:Colors.HeaderBack
    }
}

function Apply-Theme {
    $script:Colors = Get-ThemeColors
    $c = $script:Colors

    $script:Form.BackColor = $c.FormBack
    $script:Form.ForeColor = $c.Fore

    $g = $script:Grid
    $g.BackgroundColor = $c.GridBack
    $g.GridColor = $c.Border
    $g.DefaultCellStyle.BackColor = $c.GridBack
    $g.DefaultCellStyle.ForeColor = $c.Fore
    $g.DefaultCellStyle.SelectionBackColor = $c.SelectionBack
    $g.DefaultCellStyle.SelectionForeColor = $c.SelectionFore
    $g.DefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $g.AlternatingRowsDefaultCellStyle.BackColor = $c.GridAlt
    $g.AlternatingRowsDefaultCellStyle.ForeColor = $c.Fore
    $g.AlternatingRowsDefaultCellStyle.SelectionBackColor = $c.SelectionBack
    $g.AlternatingRowsDefaultCellStyle.SelectionForeColor = $c.SelectionFore
    $g.ColumnHeadersDefaultCellStyle.BackColor = $c.HeaderBack
    $g.ColumnHeadersDefaultCellStyle.ForeColor = $c.Fore
    $g.ColumnHeadersDefaultCellStyle.SelectionBackColor = $c.HeaderBack
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)

    Style-Button $script:SwitchBtn   'primary'
    Style-Button $script:RefreshBtn  'normal'
    Style-Button $script:StatusBtn   'normal'
    Style-Button $script:RemoveBtn   'danger'
    Style-Button $script:SettingsBtn 'normal'

    $script:StatusLabel.ForeColor = $c.Subtle
    $script:StatusLabel.BackColor = $c.FormBack
    $script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    if ($script:Form.IsHandleCreated) { Set-DarkTitleBar -TargetForm $script:Form -Dark $c.IsDark }
    $script:Grid.Invalidate()
}

#--------------------------------------
# REUSABLE THEMED CONFIRM DIALOG
#--------------------------------------
function Show-ThemedConfirm {
    param(
        [string]$Title,
        [string]$Heading,
        [string]$Body,
        [string]$ConfirmText = 'Confirm',
        [string]$CancelText  = 'Cancel',
        [bool]$Danger = $false
    )
    $c = $script:Colors
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.Size = New-Object System.Drawing.Size(520, 340)
    $dlg.BackColor = $c.FormBack
    $dlg.ForeColor = $c.Fore
    $dlg.Add_Shown({ Set-DarkTitleBar -TargetForm $this -Dark $script:Colors.IsDark })

    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Text = $Heading
    $lblHead.Location = New-Object System.Drawing.Point(22, 20)
    $lblHead.Size = New-Object System.Drawing.Size(465, 30)
    $lblHead.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
    if ($Danger) { $lblHead.ForeColor = $c.Danger } else { $lblHead.ForeColor = $c.Fore }
    $dlg.Controls.Add($lblHead)

    $lblBody = New-Object System.Windows.Forms.Label
    $lblBody.Text = $Body
    $lblBody.Location = New-Object System.Drawing.Point(22, 58)
    $lblBody.Size = New-Object System.Drawing.Size(465, 190)
    $lblBody.Font = New-Object System.Drawing.Font('Segoe UI', 9.75)
    $lblBody.ForeColor = $c.Fore
    $dlg.Controls.Add($lblBody)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = $ConfirmText
    $btnOk.Location = New-Object System.Drawing.Point(22, 258)
    $btnOk.Size = New-Object System.Drawing.Size(230, 36)
    if ($Danger) { Style-Button $btnOk 'danger' } else { Style-Button $btnOk 'primary' }
    $btnOk.DialogResult = 'OK'
    $dlg.Controls.Add($btnOk)

    $btnNo = New-Object System.Windows.Forms.Button
    $btnNo.Text = $CancelText
    $btnNo.Location = New-Object System.Drawing.Point(262, 258)
    $btnNo.Size = New-Object System.Drawing.Size(225, 36)
    Style-Button $btnNo 'normal'
    $btnNo.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnNo)

    $dlg.AcceptButton = $btnNo      # safe default: Enter cancels destructive actions
    $dlg.CancelButton = $btnNo

    $res = $dlg.ShowDialog($script:Form)
    $dlg.Dispose()
    return ($res -eq [System.Windows.Forms.DialogResult]::OK)
}

#--------------------------------------
# ROW MANAGEMENT
#--------------------------------------
$script:SuppressCellEvents = $false

function Reload-AccountRows {
    $script:SuppressCellEvents = $true
    $script:Grid.Rows.Clear()
    $i = 0
    foreach ($acct in $script:Accounts) {
        $meta = Get-AccountMeta $acct
        $display = $acct
        if ($script:Settings.StreamerMode) { $display = Mask-Account $acct }
        if ($i -eq 0) { $display = "$($script:GlyphDot) $display" }

        $statusText = Get-StatusDisplay $meta
        $rowIndex = $script:Grid.Rows.Add($display, $statusText, [string]$meta.BattleTag, '', '', '', '')
        $row = $script:Grid.Rows[$rowIndex]
        $row.Tag = $acct

        $row.Cells['Account'].ToolTipText = 'Double-click to switch. Right-click for options.'
        if ($i -eq 0) {
            $row.Cells['Account'].Style.ForeColor = $script:Colors.Accent
            $row.Cells['Account'].Style.SelectionForeColor = $script:Colors.Accent
            $row.Cells['Account'].Style.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
            $row.Cells['Account'].ToolTipText = 'Currently active account'
        }

        $statusColor = Get-StatusColor ([string]$meta.Status)
        $row.Cells['Status'].Style.ForeColor = $statusColor
        $row.Cells['Status'].Style.SelectionForeColor = $statusColor
        $row.Cells['Status'].Style.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
        $tip = 'Status is set by you (right-click > Set status). Nothing is auto-detected.'
        if (-not [string]::IsNullOrWhiteSpace([string]$meta.Note)) { $tip = "Note: $($meta.Note)`n$tip" }
        $row.Cells['Status'].ToolTipText = $tip
        $i++
    }
    if ($script:Grid.Rows.Count -gt 0) { $script:Grid.Rows[0].Selected = $true }
    $script:SuppressCellEvents = $false
}

function Get-SelectedAccount {
    if ($script:Grid.SelectedRows.Count -gt 0) { return [string]$script:Grid.SelectedRows[0].Tag }
    if ($script:Grid.CurrentRow) { return [string]$script:Grid.CurrentRow.Tag }
    return $null
}

#--------------------------------------
# ACCOUNT REMOVAL
#--------------------------------------
function Remove-AccountEntry {
    param([string]$Account)
    if ([string]::IsNullOrWhiteSpace($Account)) { return }

    if ($script:Accounts.Count -le 1) {
        [System.Windows.Forms.MessageBox]::Show(
            "This is your only saved account. Removing it would leave the list empty and this tool would have nothing to show.`n`nRemove it from the Battle.net launcher directly if that's really what you want.",
            'Cannot remove last account', 'OK', 'Information') | Out-Null
        return
    }

    $meta = Get-AccountMeta $Account
    $tagLine = 'none saved'
    if (-not [string]::IsNullOrWhiteSpace([string]$meta.BattleTag)) { $tagLine = [string]$meta.BattleTag }

    if ($script:Settings.ConfirmRemoval) {
        $body = @"
Account:     $Account
BattleTag:   $tagLine

This WILL:
   -  Delete the entry from Battle.net.config
      (a .backup copy is written first)
   -  Delete the BattleTag, status and note saved here
   -  Remove it from the Battle.net login dropdown

This will NOT:
   -  Delete or change your actual Blizzard account
   -  Log you out anywhere, or touch any password
   -  Affect any games, purchases or progress

You can restore it any time by logging into that
account once through Battle.net.
"@
        if (-not (Show-ThemedConfirm -Title 'Remove account' -Heading 'Remove this saved account?' `
                    -Body $body -ConfirmText 'Remove account' -CancelText 'Keep it' -Danger $true)) {
            Set-Status 'Removal cancelled'
            return
        }
    }

    # Battle.net rewrites its config on exit and would resurrect the entry
    if (Test-BattleNetRunning) {
        $ask = [System.Windows.Forms.MessageBox]::Show(
            "Battle.net is running. It rewrites Battle.net.config when it closes, which can bring this account back.`n`nClose Battle.net now so the removal sticks?",
            'Battle.net is running', 'YesNoCancel', 'Warning')
        if ($ask -eq [System.Windows.Forms.DialogResult]::Cancel) { Set-Status 'Removal cancelled'; return }
        if ($ask -eq [System.Windows.Forms.DialogResult]::Yes) {
            Get-Process 'Battle.net' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 600
        }
    }

    # Keep a local record so a mistaken removal is recoverable
    try {
        $log = @()
        if (Test-Path $script:RemovedLogPath) {
            $raw = Get-Content $script:RemovedLogPath -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $log = @($raw | ConvertFrom-Json) }
        }
        $log += [pscustomobject]@{
            Account   = $Account
            BattleTag = [string]$meta.BattleTag
            Status    = [string]$meta.Status
            Note      = [string]$meta.Note
            RemovedAt = (Get-Date).ToString('s')
        }
        ($log | ConvertTo-Json -Depth 5) | Set-Content -Path $script:RemovedLogPath -Encoding UTF8
    } catch { }

    $script:Accounts = @($script:Accounts | Where-Object { $_ -ne $Account })
    if (-not (Save-BattleNetConfig)) { return }

    if ($script:AccountStore.ContainsKey($Account)) {
        $script:AccountStore.Remove($Account)
        Save-AccountStore
    }

    Write-DebugLog "Removed account $Account"
    Reload-AccountRows
    Start-AllRankFetches
    Set-Status "Removed $Account - purged from Battle.net.config (backup saved)"
}

#--------------------------------------
# STATUS DIALOG
#--------------------------------------
function Show-StatusDialog {
    param([string]$Account)
    if ([string]::IsNullOrWhiteSpace($Account)) { return }
    $meta = Get-AccountMeta $Account
    $c = $script:Colors

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Set account status'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.Size = New-Object System.Drawing.Size(500, 430)
    $dlg.BackColor = $c.FormBack
    $dlg.ForeColor = $c.Fore
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.Add_Shown({ Set-DarkTitleBar -TargetForm $this -Dark $script:Colors.IsDark })

    $lblAcct = New-Object System.Windows.Forms.Label
    $lblAcct.Text = $Account
    $lblAcct.Location = New-Object System.Drawing.Point(20, 16)
    $lblAcct.Size = New-Object System.Drawing.Size(445, 26)
    $lblAcct.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 11)
    $dlg.Controls.Add($lblAcct)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = "Blizzard publishes no ban data, so this is set by you." + [Environment]::NewLine + "Flagged accounts warn you before switching."
    $lblHint.Location = New-Object System.Drawing.Point(20, 44)
    $lblHint.Size = New-Object System.Drawing.Size(445, 38)
    $lblHint.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lblHint.ForeColor = $c.Subtle
    $dlg.Controls.Add($lblHint)

    $y = 92
    $radios = @{}
    $descriptions = @{
        'OK'        = 'Normal - no warning'
        'Watch'     = 'Keep an eye on it - warns before switching'
        'Suspended' = 'Temporarily locked - warns before switching'
        'Banned'    = 'Banned - strong warning before switching'
    }
    foreach ($val in $script:StatusValues) {
        $rb = New-Object System.Windows.Forms.RadioButton
        $rb.Text = "$val  -  $($descriptions[$val])"
        $rb.Location = New-Object System.Drawing.Point(24, $y)
        $rb.Size = New-Object System.Drawing.Size(440, 26)
        $rb.ForeColor = Get-StatusColor $val
        if ($val -eq 'OK') { $rb.ForeColor = $c.Fore }
        $rb.Checked = ([string]$meta.Status -eq $val)
        $dlg.Controls.Add($rb)
        $radios[$val] = $rb
        $y += 30
    }
    $y += 10

    $lblUntil = New-Object System.Windows.Forms.Label
    $lblUntil.Text = 'Suspended until (optional)'
    $lblUntil.Location = New-Object System.Drawing.Point(24, ($y + 4))
    $lblUntil.Size = New-Object System.Drawing.Size(200, 24)
    $dlg.Controls.Add($lblUntil)

    $chkUntil = New-Object System.Windows.Forms.CheckBox
    $chkUntil.Location = New-Object System.Drawing.Point(232, ($y + 6))
    $chkUntil.Size = New-Object System.Drawing.Size(20, 20)
    $dlg.Controls.Add($chkUntil)

    $dtUntil = New-Object System.Windows.Forms.DateTimePicker
    $dtUntil.Location = New-Object System.Drawing.Point(256, $y)
    $dtUntil.Size = New-Object System.Drawing.Size(208, 26)
    $dtUntil.Format = 'Short'
    $dtUntil.MinDate = (Get-Date).Date
    if (-not [string]::IsNullOrWhiteSpace([string]$meta.Until)) {
        try { $dtUntil.Value = [datetime]::Parse([string]$meta.Until); $chkUntil.Checked = $true } catch { }
    }
    $dlg.Controls.Add($dtUntil)
    $y += 40

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = 'Note (shown in tooltip and warning)'
    $lblNote.Location = New-Object System.Drawing.Point(24, $y)
    $lblNote.Size = New-Object System.Drawing.Size(440, 22)
    $dlg.Controls.Add($lblNote)
    $y += 26

    $txtNote = New-Object System.Windows.Forms.TextBox
    $txtNote.Location = New-Object System.Drawing.Point(24, $y)
    $txtNote.Size = New-Object System.Drawing.Size(440, 26)
    $txtNote.Text = [string]$meta.Note
    $txtNote.BackColor = $c.GridBack
    $txtNote.ForeColor = $c.Fore
    $txtNote.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($txtNote)
    $y += 42

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Save'
    $btnSave.Location = New-Object System.Drawing.Point(24, $y)
    $btnSave.Size = New-Object System.Drawing.Size(215, 36)
    Style-Button $btnSave 'primary'
    $btnSave.DialogResult = 'OK'
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(249, $y)
    $btnCancel.Size = New-Object System.Drawing.Size(215, 36)
    Style-Button $btnCancel 'normal'
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnSave
    $dlg.CancelButton = $btnCancel

    $res = $dlg.ShowDialog($script:Form)
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        foreach ($val in $script:StatusValues) {
            if ($radios[$val].Checked) { $meta.Status = $val }
        }
        $meta.Note = $txtNote.Text.Trim()
        if ($chkUntil.Checked -and $meta.Status -eq 'Suspended') {
            $meta.Until = $dtUntil.Value.ToString('yyyy-MM-dd')
        } else {
            $meta.Until = ''
        }
        $script:AccountStore[$Account] = $meta
        Save-AccountStore
        Reload-AccountRows
        Start-AllRankFetches
        Set-Status "Status for $Account set to $($meta.Status)"
    }
    $dlg.Dispose()
}

#--------------------------------------
# SWITCH LOGIC
#--------------------------------------
function Confirm-FlaggedSwitch {
    param([string]$Account, $Meta)
    $status = [string]$Meta.Status
    if ($status -eq 'OK' -or [string]::IsNullOrWhiteSpace($status)) { return $true }
    if (-not $script:Settings.WarnOnFlagged) { return $true }

    $heading = 'This account is flagged'
    $danger = $false
    switch ($status) {
        'Banned' {
            $heading = 'This account is marked BANNED'
            $danger = $true
        }
        'Suspended' {
            $heading = 'This account is marked SUSPENDED'
            $danger = $true
        }
        'Watch' { $heading = 'This account is flagged: Watch' }
    }

    $extra = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Meta.Note)) {
        $extra += [Environment]::NewLine + "Your note:  $($Meta.Note)" + [Environment]::NewLine
    }
    if ($status -eq 'Suspended' -and -not [string]::IsNullOrWhiteSpace([string]$Meta.Until)) {
        try {
            $until = [datetime]::Parse([string]$Meta.Until)
            $days = [int][Math]::Ceiling(($until - (Get-Date)).TotalDays)
            if ($days -gt 0) { $extra += [Environment]::NewLine + "Suspension ends:  $($until.ToString('yyyy-MM-dd'))  ($days days left)" + [Environment]::NewLine }
            else { $extra += [Environment]::NewLine + "Suspension end date has passed ($($until.ToString('yyyy-MM-dd')))." + [Environment]::NewLine }
        } catch { }
    }

    $body = @"
Account:  $Account
Status:   $status
$extra
Switching will set this account as the active login
and restart Battle.net.

Reminder: this flag is one YOU set. The app cannot
detect bans - Blizzard exposes no such data anywhere.

Are you sure you want to log in to this account?
"@

    return (Show-ThemedConfirm -Title 'Flagged account' -Heading $heading -Body $body `
                -ConfirmText 'Log in anyway' -CancelText 'Cancel' -Danger $danger)
}

function Invoke-AccountSwitch {
    param([string]$Account)
    if ([string]::IsNullOrWhiteSpace($Account)) { return }

    $meta = Get-AccountMeta $Account
    if (-not (Confirm-FlaggedSwitch -Account $Account -Meta $meta)) {
        Set-Status 'Switch cancelled'
        return
    }

    Set-Status "Switching to $Account..."
    Write-DebugLog "Switching to $Account"

    $script:Accounts = @($Account) + @($script:Accounts | Where-Object { $_ -ne $Account })
    if (-not (Save-BattleNetConfig)) { return }

    if (-not $env:BNS_SMOKETEST) {
        if ($script:Settings.CloseOverwatchOnSwitch) {
            Get-Process 'Overwatch' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Get-Process 'Battle.net' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400

        if ($script:BattleNetExe -and (Test-Path $script:BattleNetExe)) {
            if ($script:Settings.LaunchOverwatch) {
                Start-Process $script:BattleNetExe -ArgumentList '--exec="launch Pro"'
            } elseif ($script:Settings.AutoLaunchBattleNet) {
                Start-Process $script:BattleNetExe
            }
        }
    }

    if ($script:Settings.CloseAfterSwitch) {
        $script:Form.Close()
    } else {
        Reload-AccountRows
        Start-AllRankFetches
        Set-Status "Switched to $Account - Battle.net restarted"
    }
}

#--------------------------------------
# SETTINGS DIALOG
#--------------------------------------
function Show-SettingsDialog {
    $c = $script:Colors
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Settings'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.Size = New-Object System.Drawing.Size(440, 620)
    $dlg.BackColor = $c.FormBack
    $dlg.ForeColor = $c.Fore
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $dlg.Add_Shown({ Set-DarkTitleBar -TargetForm $this -Dark $script:Colors.IsDark })

    $x = 20; $y = 18; $w = 380; $rowH = 32

    $lblTheme = New-Object System.Windows.Forms.Label
    $lblTheme.Text = 'Theme'
    $lblTheme.Location = New-Object System.Drawing.Point($x, ($y + 4))
    $lblTheme.Size = New-Object System.Drawing.Size(180, 22)
    $dlg.Controls.Add($lblTheme)

    $cmbTheme = New-Object System.Windows.Forms.ComboBox
    $cmbTheme.DropDownStyle = 'DropDownList'
    [void]$cmbTheme.Items.AddRange(@('Dark', 'Light', 'Auto (match Windows)'))
    $cmbTheme.Location = New-Object System.Drawing.Point(($x + 200), $y)
    $cmbTheme.Size = New-Object System.Drawing.Size(180, 26)
    $cmbTheme.FlatStyle = 'Flat'
    $cmbTheme.BackColor = $c.ButtonBack
    $cmbTheme.ForeColor = $c.Fore
    switch ([string]$script:Settings.Theme) {
        'Light' { $cmbTheme.SelectedIndex = 1 }
        'Auto'  { $cmbTheme.SelectedIndex = 2 }
        default { $cmbTheme.SelectedIndex = 0 }
    }
    $dlg.Controls.Add($cmbTheme)
    $y += $rowH + 6

    $lblPlat = New-Object System.Windows.Forms.Label
    $lblPlat.Text = 'Rank platform'
    $lblPlat.Location = New-Object System.Drawing.Point($x, ($y + 4))
    $lblPlat.Size = New-Object System.Drawing.Size(180, 22)
    $dlg.Controls.Add($lblPlat)

    $cmbPlat = New-Object System.Windows.Forms.ComboBox
    $cmbPlat.DropDownStyle = 'DropDownList'
    [void]$cmbPlat.Items.AddRange(@('PC', 'Console'))
    $cmbPlat.Location = New-Object System.Drawing.Point(($x + 200), $y)
    $cmbPlat.Size = New-Object System.Drawing.Size(180, 26)
    $cmbPlat.FlatStyle = 'Flat'
    $cmbPlat.BackColor = $c.ButtonBack
    $cmbPlat.ForeColor = $c.Fore
    if ([string]$script:Settings.Platform -eq 'console') { $cmbPlat.SelectedIndex = 1 } else { $cmbPlat.SelectedIndex = 0 }
    $dlg.Controls.Add($cmbPlat)
    $y += $rowH + 12

    $checks = @(
        @{ Key = 'WarnOnFlagged';          Text = 'Warn before switching to a flagged account' },
        @{ Key = 'ConfirmRemoval';         Text = 'Confirm before removing an account' },
        @{ Key = 'ShowRankIcons';          Text = 'Show rank icons in the grid' },
        @{ Key = 'FetchRanksOnStart';      Text = 'Fetch ranks automatically on startup' },
        @{ Key = 'AutoLaunchBattleNet';    Text = 'Relaunch Battle.net after switching' },
        @{ Key = 'LaunchOverwatch';        Text = 'Launch Overwatch 2 directly after switching' },
        @{ Key = 'CloseOverwatchOnSwitch'; Text = 'Close Overwatch when switching accounts' },
        @{ Key = 'CloseAfterSwitch';       Text = 'Close this window after switching' },
        @{ Key = 'StreamerMode';           Text = 'Streamer mode (mask account emails)' },
        @{ Key = 'DebugLogging';           Text = 'Write debug log (troubleshooting)' }
    )
    $checkBoxes = @{}
    foreach ($item in $checks) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $item.Text
        $cb.Location = New-Object System.Drawing.Point($x, $y)
        $cb.Size = New-Object System.Drawing.Size($w, 26)
        $cb.Checked = [bool]$script:Settings[$item.Key]
        $cb.ForeColor = $c.Fore
        $dlg.Controls.Add($cb)
        $checkBoxes[$item.Key] = $cb
        $y += 30
    }
    $y += 8

    $btnCache = New-Object System.Windows.Forms.Button
    $btnCache.Text = 'Clear icon cache'
    $btnCache.Location = New-Object System.Drawing.Point($x, $y)
    $btnCache.Size = New-Object System.Drawing.Size(180, 32)
    Style-Button $btnCache 'normal'
    $btnCache.Add_Click({
        try { Remove-Item (Join-Path $script:IconCacheDir '*') -Force -ErrorAction SilentlyContinue } catch { }
        $script:ImageCache = @{}
        [System.Windows.Forms.MessageBox]::Show('Rank icon cache cleared. Icons re-download on next refresh.', 'Settings', 'OK', 'Information') | Out-Null
    })
    $dlg.Controls.Add($btnCache)

    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Text = 'Open data folder'
    $btnFolder.Location = New-Object System.Drawing.Point(($x + 200), $y)
    $btnFolder.Size = New-Object System.Drawing.Size(180, 32)
    Style-Button $btnFolder 'normal'
    $btnFolder.Add_Click({ Start-Process explorer.exe $script:DataFolder })
    $dlg.Controls.Add($btnFolder)
    $y += 48

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = 'Save'
    $btnSave.Location = New-Object System.Drawing.Point($x, $y)
    $btnSave.Size = New-Object System.Drawing.Size(180, 36)
    Style-Button $btnSave 'primary'
    $btnSave.DialogResult = 'OK'
    $dlg.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(($x + 200), $y)
    $btnCancel.Size = New-Object System.Drawing.Size(180, 36)
    Style-Button $btnCancel 'normal'
    $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnSave
    $dlg.CancelButton = $btnCancel
    $y += 46

    # Credit to the original project this is forked from
    $lblCredit = New-Object System.Windows.Forms.Label
    $lblCredit.Text = "Dark Edition v1.2  -  forked from BNetSwitcher by Nepero" + [Environment]::NewLine + "Rank data by OverFast API"
    $lblCredit.Location = New-Object System.Drawing.Point($x, $y)
    $lblCredit.Size = New-Object System.Drawing.Size($w, 34)
    $lblCredit.TextAlign = 'MiddleCenter'
    $lblCredit.Font = New-Object System.Drawing.Font('Segoe UI', 8.25)
    $lblCredit.ForeColor = $c.Subtle
    $dlg.Controls.Add($lblCredit)

    $result = $dlg.ShowDialog($script:Form)
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return }

    $oldPlatform = [string]$script:Settings.Platform
    $oldStreamer = [bool]$script:Settings.StreamerMode

    switch ($cmbTheme.SelectedIndex) {
        1 { $script:Settings.Theme = 'Light' }
        2 { $script:Settings.Theme = 'Auto' }
        default { $script:Settings.Theme = 'Dark' }
    }
    if ($cmbPlat.SelectedIndex -eq 1) { $script:Settings.Platform = 'console' } else { $script:Settings.Platform = 'pc' }
    foreach ($key in $checkBoxes.Keys) { $script:Settings[$key] = [bool]$checkBoxes[$key].Checked }
    Save-Settings
    $dlg.Dispose()

    Apply-Theme
    if (([bool]$script:Settings.StreamerMode) -ne $oldStreamer) { Reload-AccountRows }
    if (([string]$script:Settings.Platform) -ne $oldPlatform)   { Start-AllRankFetches }
    Set-Status 'Settings saved'
}

#--------------------------------------
# CONTEXT MENU
#--------------------------------------
$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:Menu.BackColor = $script:Colors.HeaderBack
$script:Menu.ForeColor = $script:Colors.Fore
$script:Menu.ShowImageMargin = $false

$miSwitch = $script:Menu.Items.Add('Switch to this account')
$miSwitch.Add_Click({ $a = Get-SelectedAccount; if ($a) { Invoke-AccountSwitch $a } })

$miStatus = $script:Menu.Items.Add('Set status / note...')
$miStatus.Add_Click({ $a = Get-SelectedAccount; if ($a) { Show-StatusDialog $a } })

[void]$script:Menu.Items.Add('-')

$miRefresh = $script:Menu.Items.Add('Refresh this rank')
$miRefresh.Add_Click({
    if ($script:Grid.SelectedRows.Count -gt 0) {
        $row = $script:Grid.SelectedRows[0]
        $bt = [string]$row.Cells['BattleTag'].Value
        if ($bt) { Start-RankFetch -Row $row -BattleTag $bt }
    }
})

$miCopy = $script:Menu.Items.Add('Copy email to clipboard')
$miCopy.Add_Click({
    $a = Get-SelectedAccount
    if ($a) { try { Set-Clipboard -Value $a; Set-Status 'Email copied to clipboard' } catch { } }
})

[void]$script:Menu.Items.Add('-')

$miRemove = $script:Menu.Items.Add('Remove account (Del)')
$miRemove.ForeColor = $script:Colors.Danger
$miRemove.Add_Click({ $a = Get-SelectedAccount; if ($a) { Remove-AccountEntry $a } })

# Right-click selects the row under the cursor before showing the menu
$script:Grid.Add_CellMouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    if ($e.RowIndex -lt 0) { return }
    $sender.ClearSelection()
    $sender.Rows[$e.RowIndex].Selected = $true
    $sender.CurrentCell = $sender.Rows[$e.RowIndex].Cells['Account']
})
$script:Grid.ContextMenuStrip = $script:Menu

#--------------------------------------
# EVENT WIRING
#--------------------------------------

# Custom paint: rank icon + division/tier text in role cells
$script:Grid.Add_CellPainting({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $colName = $sender.Columns[$e.ColumnIndex].Name
    if ($script:RoleColumns -notcontains $colName) { return }

    $e.PaintBackground($e.CellBounds, $true)

    $cell = $sender.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
    $img = $null
    if ($script:Settings.ShowRankIcons) { $img = $cell.Tag }
    $text = ''
    if ($null -ne $e.FormattedValue) { $text = [string]$e.FormattedValue }

    $x = $e.CellBounds.X + 6
    if ($img) {
        $size = 26
        $iy = $e.CellBounds.Y + [int](($e.CellBounds.Height - $size) / 2)
        try {
            $e.Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $e.Graphics.DrawImage($img, $x, $iy, $size, $size)
        } catch { }
        $x += $size + 6
    }
    if ($text) {
        $selected = (($e.State -band [System.Windows.Forms.DataGridViewElementStates]::Selected) -ne 0)
        $color = $e.CellStyle.ForeColor
        if ($selected) { $color = $e.CellStyle.SelectionForeColor }
        $rectW = $e.CellBounds.Right - $x - 2
        if ($rectW -gt 0) {
            $rect = New-Object System.Drawing.Rectangle($x, $e.CellBounds.Y, $rectW, $e.CellBounds.Height)
            $flags = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $text, $e.CellStyle.Font, $rect, $color, $flags)
        }
    }
    $e.Handled = $true
})

# BattleTag edited -> persist + fetch ranks
$script:Grid.Add_CellEndEdit({
    param($sender, $e)
    if ($script:SuppressCellEvents) { return }
    if ($sender.Columns[$e.ColumnIndex].Name -ne 'BattleTag') { return }

    $row = $sender.Rows[$e.RowIndex]
    $acct = [string]$row.Tag
    $meta = Get-AccountMeta $acct
    $btRaw = $row.Cells['BattleTag'].Value
    $bt = ''
    if ($btRaw) { $bt = ([string]$btRaw).Trim() }

    if ([string]::IsNullOrWhiteSpace($bt)) {
        $meta.BattleTag = ''
        foreach ($col in $script:RoleColumns) {
            $row.Cells[$col].Value = ''
            $row.Cells[$col].Tag = $null
            $row.Cells[$col].ToolTipText = ''
        }
    } else {
        $meta.BattleTag = $bt
        if ($bt -notmatch '#') { Set-Status "Tip: BattleTags look like Name#1234 - '$bt' may not be found" }
        Start-RankFetch -Row $row -BattleTag $bt
    }
    $script:AccountStore[$acct] = $meta
    Save-AccountStore
})

# Double-click account name -> switch
$script:Grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $colName = $sender.Columns[$e.ColumnIndex].Name
    if ($colName -eq 'Account') {
        $acct = [string]$sender.Rows[$e.RowIndex].Tag
        if ($acct) { Invoke-AccountSwitch $acct }
    } elseif ($colName -eq 'Status') {
        $acct = [string]$sender.Rows[$e.RowIndex].Tag
        if ($acct) { Show-StatusDialog $acct }
    }
})

# Enter -> switch; Delete -> remove
$script:Grid.Add_KeyDown({
    param($sender, $e)
    if ($sender.IsCurrentCellInEditMode) { return }
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.Handled = $true; $e.SuppressKeyPress = $true
        $acct = Get-SelectedAccount
        if ($acct) { Invoke-AccountSwitch $acct }
    } elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) {
        $e.Handled = $true; $e.SuppressKeyPress = $true
        $acct = Get-SelectedAccount
        if ($acct) { Remove-AccountEntry $acct }
    }
})
$script:Form.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) { $e.Handled = $true; Start-AllRankFetches }
})

$script:SwitchBtn.Add_Click({ $a = Get-SelectedAccount; if ($a) { Invoke-AccountSwitch $a } })
$script:RefreshBtn.Add_Click({ Start-AllRankFetches })
$script:StatusBtn.Add_Click({ $a = Get-SelectedAccount; if ($a) { Show-StatusDialog $a } })
$script:RemoveBtn.Add_Click({ $a = Get-SelectedAccount; if ($a) { Remove-AccountEntry $a } })
$script:SettingsBtn.Add_Click({ Show-SettingsDialog })

$script:PollTimer = New-Object System.Windows.Forms.Timer
$script:PollTimer.Interval = 300
$script:PollTimer.Add_Tick({ Process-RankJobs })
$script:PollTimer.Start()

$script:Form.Add_Shown({
    Set-DarkTitleBar -TargetForm $script:Form -Dark $script:Colors.IsDark
    if ($script:Settings.FetchRanksOnStart) { Start-AllRankFetches }
    $hasTags = $false
    foreach ($row in $script:Grid.Rows) {
        if (-not [string]::IsNullOrWhiteSpace([string]$row.Cells['BattleTag'].Value)) { $hasTags = $true; break }
    }
    if (-not $hasTags) {
        Set-Status 'Tip: click a BattleTag cell and type Name#1234 - ranks and icons load automatically'
    }
})

$script:Form.Add_FormClosing({
    try {
        $script:PollTimer.Stop()
        $script:Settings.WindowWidth = $script:Form.Width
        $script:Settings.WindowHeight = $script:Form.Height
        Save-Settings
    } catch { }
    foreach ($job in @($script:Jobs)) {
        try { $job.PS.BeginStop($null, $null) | Out-Null } catch { }
    }
    try { $script:RunspacePool.Close(); $script:RunspacePool.Dispose() } catch { }
})

#--------------------------------------
# SMOKE TEST HOOK (dev/testing only, inert in normal use)
#--------------------------------------
if ($env:BNS_SMOKETEST) {
    $script:SmokeTimer = New-Object System.Windows.Forms.Timer
    $script:SmokeTimer.Interval = 12000
    $script:SmokeTimer.Add_Tick({
        $script:SmokeTimer.Stop()
        try {
            if ($env:BNS_SMOKE_REMOVE) {
                $script:Settings.ConfirmRemoval = $false
                Remove-AccountEntry $env:BNS_SMOKE_REMOVE
            }
            $dump = [ordered]@{
                Accounts = @($script:Accounts)
                Rows = @(foreach ($row in $script:Grid.Rows) {
                    [ordered]@{
                        Account   = [string]$row.Tag
                        Display   = [string]$row.Cells['Account'].Value
                        Status    = [string]$row.Cells['Status'].Value
                        BattleTag = [string]$row.Cells['BattleTag'].Value
                        Support   = [string]$row.Cells['Support'].Value
                        HasIcon   = ($null -ne $row.Cells['Support'].Tag)
                    }
                })
            }
            if ($env:BNS_SMOKE_OUT) { ($dump | ConvertTo-Json -Depth 5) | Set-Content -Path $env:BNS_SMOKE_OUT -Encoding UTF8 }
        } catch {
            if ($env:BNS_SMOKE_OUT) { "ERROR: $_" | Set-Content -Path $env:BNS_SMOKE_OUT -Encoding UTF8 }
        }
        $script:Form.Close()
    })
    $script:SmokeTimer.Start()
}

#--------------------------------------
# LAUNCH
#--------------------------------------
Apply-Theme
Reload-AccountRows
Set-Status 'Ready'
$null = $script:Form.ShowDialog()
exit
