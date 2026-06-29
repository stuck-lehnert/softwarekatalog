<#
SelfServiceWinget.ps1

Use as:
- Computer Startup GPO script (default mode = Install)
- Scheduled task target (Mode = Daemon / UpgradeAll / ApplyPolicy / ProcessRequest)

Behavior:
User -> GUI / request helper -> named pipe -> daemon task (SYSTEM) -> winget install --scope machine

Created paths:
C:\ProgramData\__Softwarekatalog\
  SelfServiceWinget.ps1
  Request-App.ps1
  Software-Catalog.ps1
  Launch-Software-Catalog.vbs
  Installed-Packages.json
  Logs\service.log
#>

[CmdletBinding()]
param(
    [ValidateSet('Install','Daemon','UpgradeAll','ApplyPolicy','ProcessRequest')]
    [string]$Mode = 'Install',
    [ValidateSet('Install','Uninstall')]
    [string]$RequestAction = 'Install',
    [string]$AppAlias,
    [string]$RequestedBy,
    [string]$RequestedBySid
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------
# Configuration
# ----------------------------
$CatalogDisplayName     = 'Softwarekatalog'
$BaseDir                = Join-Path $env:ProgramData '__Softwarekatalog'
$LocalScriptPath        = Join-Path $BaseDir 'SelfServiceWinget.ps1'
$RequestToolPath        = Join-Path $BaseDir 'Request-App.ps1'
$CatalogGuiPath         = Join-Path $BaseDir 'Software-Catalog.ps1'
$CatalogLauncherPath    = Join-Path $BaseDir 'Launch-Software-Catalog.vbs'
$InstalledPackagesPath  = Join-Path $BaseDir 'Installed-Packages.json'
$LogDir                 = Join-Path $BaseDir 'Logs'
$LogFile                = Join-Path $LogDir 'service.log'
$PolicyRoot             = 'HKLM:\Software\Policies\STL\Softwarekatalog'
$PolicyCatalogRoot      = Join-Path $PolicyRoot 'Catalog'
$PolicyRequiredRoot     = Join-Path $PolicyRoot 'Required'
$PolicyMaxEntries       = 500
$LegacyQueueTaskName    = 'Softwarekatalog - Winget Queue'
$DaemonTaskName         = 'Softwarekatalog - Daemon'
$UpgradeTaskName        = 'Softwarekatalog - Winget Upgrade'
$PipeName               = 'Softwarekatalog'
$WingetMutexName        = 'Global\Softwarekatalog-Winget'
$PowerShellExe          = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$WScriptExe             = Join-Path $env:SystemRoot 'System32\wscript.exe'
$AppInstallerFamilyName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
$CommonDesktopDir       = [Environment]::GetFolderPath('CommonDesktopDirectory')
$CommonProgramsDir      = [Environment]::GetFolderPath('CommonPrograms')
$DesktopShortcutPath    = Join-Path $CommonDesktopDir "$CatalogDisplayName.lnk"
$StartMenuShortcutPath  = Join-Path $CommonProgramsDir "$CatalogDisplayName.lnk"

# ----------------------------
# Utility functions
# ----------------------------
function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )

    Ensure-Directory -Path $LogDir
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Set-DirectoryAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$UsersCanModify
    )

    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)

    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $sidUsers = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')

    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidSystem, 'FullControl', $inheritance, $propagation, 'Allow'
    )
    $ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidAdmins, 'FullControl', $inheritance, $propagation, 'Allow'
    )

    if ($UsersCanModify) {
        $ruleUsers = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sidUsers, 'Modify', $inheritance, $propagation, 'Allow'
        )
    }
    else {
        $ruleUsers = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sidUsers, 'ReadAndExecute, Synchronize', $inheritance, $propagation, 'Allow'
        )
    }

    $null = $acl.AddAccessRule($ruleSystem)
    $null = $acl.AddAccessRule($ruleAdmins)
    $null = $acl.AddAccessRule($ruleUsers)

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-FileAclAdminsOnly {
    param([Parameter(Mandatory)][string]$Path)

    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)

    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $sidUsers = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')

    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidSystem, 'FullControl', 'Allow'
    )
    $ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidAdmins, 'FullControl', 'Allow'
    )
    $ruleUsers = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidUsers, 'ReadAndExecute, Synchronize', 'Allow'
    )

    $null = $acl.AddAccessRule($ruleSystem)
    $null = $acl.AddAccessRule($ruleAdmins)
    $null = $acl.AddAccessRule($ruleUsers)

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-PolicyDword {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Default = 0
    )

    try {
        if (-not (Test-Path -LiteralPath $PolicyRoot)) {
            return $Default
        }

        $props = Get-ItemProperty -LiteralPath $PolicyRoot -ErrorAction Stop
        $property = $props.PSObject.Properties[$Name]
        if (-not $property) {
            return $Default
        }

        return [int]$property.Value
    }
    catch {
        Write-Log "Failed to read policy value '$Name': $($_.Exception.Message)" 'WARN'
        return $Default
    }
}

function Test-SoftwareCatalogPolicyEnabled {
    (Get-PolicyDword -Name 'Enabled' -Default 0) -eq 1
}

function Test-UserInstallsAllowed {
    (Get-PolicyDword -Name 'AllowUserInstalls' -Default 1) -eq 1
}

function Test-UserUninstallAllowed {
    (Get-PolicyDword -Name 'AllowUserUninstall' -Default 1) -eq 1
}

function Test-RequiredEnforcementEnabled {
    (Get-PolicyDword -Name 'EnforceRequired' -Default 1) -eq 1
}

function Get-PolicyStringValues {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $names = @($item.GetValueNames()) |
            Where-Object { $_ -and $_ -notmatch '^\*' } |
            Sort-Object |
            Select-Object -First $PolicyMaxEntries

        foreach ($name in $names) {
            $value = [string]$item.GetValue($name, '')
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                [pscustomobject]@{
                    Name  = [string]$name
                    Value = $value.Trim()
                }
            }
        }
    }
    catch {
        Write-Log "Failed to read policy list '$Path': $($_.Exception.Message)" 'WARN'
        return @()
    }
}

function Get-AppCatalogObjects {
    if (-not (Test-SoftwareCatalogPolicyEnabled)) {
        return @()
    }

    $seenAliases = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $rows = Get-PolicyStringValues -Path $PolicyCatalogRoot
    foreach ($row in $rows) {
        $alias = ([string]$row.Name).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($alias)) {
            continue
        }

        if (-not $seenAliases.Add($alias)) {
            Write-Log "Duplicate catalog alias '$alias' in policy; ignoring duplicate." 'WARN'
            continue
        }

        $parts = ([string]$row.Value) -split '\|', 3
        if (@($parts).Count -lt 2) {
            Write-Log "Malformed catalog row '$alias'. Expected: PackageId|DisplayName|Description" 'WARN'
            continue
        }

        $packageId = ([string]$parts[0]).Trim()
        $displayName = ([string]$parts[1]).Trim()
        $description = ''
        if (@($parts).Count -ge 3) {
            $description = ([string]$parts[2]).Trim()
        }

        if ([string]::IsNullOrWhiteSpace($packageId)) {
            Write-Log "Catalog row '$alias' has empty package ID; ignoring." 'WARN'
            continue
        }

        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = $alias
        }

        [pscustomobject]@{
            Alias       = $alias
            DisplayName = $displayName
            Description = $description
            PackageId   = $packageId
        }
    }
}

function Get-RequiredAliases {
    if (-not (Test-SoftwareCatalogPolicyEnabled)) {
        return @()
    }

    $seenAliases = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $rows = Get-PolicyStringValues -Path $PolicyRequiredRoot
    foreach ($row in $rows) {
        $value = ([string]$row.Value).Trim()
        if ($value -eq '0' -or $value -eq 'false') {
            continue
        }

        $alias = ([string]$row.Name).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($alias)) {
            continue
        }

        if ($seenAliases.Add($alias)) {
            $alias
        }
    }
}

function Get-PackageIdByAlias {
    param([Parameter(Mandatory)][string]$Alias)

    foreach ($app in Get-AppCatalogObjects) {
        if ([string]::Equals([string]$app.Alias, $Alias, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$app.PackageId
        }
    }

    return $null
}

function Get-AppCatalogObjectByAlias {
    param([Parameter(Mandatory)][string]$Alias)

    foreach ($app in Get-AppCatalogObjects) {
        if ([string]::Equals([string]$app.Alias, $Alias, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $app
        }
    }

    return $null
}

function Write-TextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content,
        [ValidateSet('Utf8Bom','Unicode')]
        [string]$Encoding = 'Utf8Bom'
    )

    $parent = Split-Path -Path $Path -Parent
    if ($parent) {
        Ensure-Directory -Path $parent
    }

    switch ($Encoding) {
        'Unicode' { $textEncoding = New-Object System.Text.UnicodeEncoding($false, $true) }
        default   { $textEncoding = New-Object System.Text.UTF8Encoding($true) }
    }

    [System.IO.File]::WriteAllText($Path, $Content, $textEncoding)
}

function Invoke-WithWingetLock {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 7200
    )

    $mutex = New-Object System.Threading.Mutex($false, $WingetMutexName)
    $hasLock = $false

    try {
        $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        if (-not $hasLock) {
            throw "Timed out waiting for winget lock '$WingetMutexName'."
        }

        & $ScriptBlock
    }
    finally {
        if ($hasLock) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Test-WingetLockAvailable {
    $mutex = New-Object System.Threading.Mutex($false, $WingetMutexName)
    $hasLock = $false

    try {
        $hasLock = $mutex.WaitOne(0)
        return $hasLock
    }
    finally {
        if ($hasLock) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory)][string]$Value)

    if ($Value -match '[\s"]') {
        return '"{0}"' -f ($Value.Replace('"', '\"'))
    }

    return $Value
}

function Get-WorkerScriptPath {
    if (Test-Path -LiteralPath $LocalScriptPath) {
        return $LocalScriptPath
    }

    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        return $PSCommandPath
    }

    throw 'Could not determine worker script path.'
}

function Start-SoftwarekatalogWorker {
    param(
        [Parameter(Mandatory)][ValidateSet('ApplyPolicy','ProcessRequest')][string]$WorkerMode,
        [ValidateSet('Install','Uninstall')][string]$WorkerAction = 'Install',
        [string]$WorkerAlias,
        [string]$WorkerRequestedBy,
        [string]$WorkerRequestedBySid
    )

    $workerScript = Get-WorkerScriptPath
    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $workerScript,
        '-Mode', $WorkerMode
    )

    if ($WorkerMode -eq 'ProcessRequest') {
        $args += @('-RequestAction', $WorkerAction, '-AppAlias', $WorkerAlias)

        if (-not [string]::IsNullOrWhiteSpace($WorkerRequestedBy)) {
            $args += @('-RequestedBy', $WorkerRequestedBy)
        }

        if (-not [string]::IsNullOrWhiteSpace($WorkerRequestedBySid)) {
            $args += @('-RequestedBySid', $WorkerRequestedBySid)
        }
    }

    $argumentLine = (@($args) | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join ' '
    Start-Process -FilePath $PowerShellExe -ArgumentList $argumentLine -WindowStyle Hidden | Out-Null
}

function Get-WingetPath {
    $candidates = @()

    try {
        $cmd = Get-Command winget.exe -ErrorAction Stop
        if ($cmd -and $cmd.Source) {
            $candidates += $cmd.Source
        }
    }
    catch {
    }

    try {
        $packages = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
            Where-Object { $_.InstallLocation } |
            Sort-Object Version -Descending

        foreach ($package in $packages) {
            $candidate = Join-Path $package.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $candidate) {
                $candidates += $candidate
            }
        }
    }
    catch {
    }

    $windowsAppsRoot = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path -LiteralPath $windowsAppsRoot) {
        try {
            $items = Get-ChildItem -LiteralPath $windowsAppsRoot -Directory -ErrorAction Stop |
                Where-Object { $_.Name -like 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' } |
                Sort-Object Name -Descending

            foreach ($item in $items) {
                $candidate = Join-Path $item.FullName 'winget.exe'
                if (Test-Path -LiteralPath $candidate) {
                    $candidates += $candidate
                }
            }
        }
        catch {
        }
    }

    $resolved = $candidates | Select-Object -Unique | Select-Object -First 1
    return $resolved
}

function Ensure-WingetAvailable {
    $wingetPath = Get-WingetPath
    if ($wingetPath) {
        Write-Log "winget already available at: $wingetPath"
        return $wingetPath
    }

    Write-Log 'winget.exe not found.'

    $isLocalSystem = $false
    try {
        $isLocalSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
    }
    catch {
    }

    if ($isLocalSystem) {
        Write-Log "App Installer package registration cannot run as LocalSystem; skipping Add-AppxPackage fallback for '$AppInstallerFamilyName'." 'ERROR'
        Write-Log 'winget is unavailable. Install/provision App Installer, or verify winget path discovery for this device.' 'ERROR'
        return $null
    }

    Write-Log "Attempting to register App Installer package family '$AppInstallerFamilyName'."

    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage $AppInstallerFamilyName
        Start-Sleep -Seconds 3
    }
    catch {
        Write-Log "Add-AppxPackage registration attempt failed: $($_.Exception.Message)" 'ERROR'
    }

    $wingetPath = Get-WingetPath
    if ($wingetPath) {
        Write-Log "winget became available after App Installer registration: $wingetPath"
        return $wingetPath
    }

    Write-Log "winget is still unavailable after App Installer registration attempt." 'ERROR'
    return $null
}

function New-UserRequestTool {
    $pipeLiteral   = $PipeName.Replace("'", "''")

$content = @"
[CmdletBinding()]
param(
    [string]`$AppAlias,
    [ValidateSet('Install','Uninstall')]
    [string]`$Action = 'Install',
    [switch]`$Uninstall,
    [switch]`$List
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$PipeName = '$pipeLiteral'

function Invoke-CatalogDaemon {
    param(
        [Parameter(Mandatory=`$true)][string]`$Command,
        [string]`$Alias
    )

    `$payload = [ordered]@{
        Command  = `$Command
        AppAlias = `$Alias
    }
    `$json = `$payload | ConvertTo-Json -Compress

    `$encoding = New-Object System.Text.UTF8Encoding(`$false)
    `$client = New-Object System.IO.Pipes.NamedPipeClientStream -ArgumentList @(
        '.',
        `$PipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::None,
        [System.Security.Principal.TokenImpersonationLevel]::Impersonation
    )

    try {
        `$client.Connect(60000)
        `$reader = New-Object System.IO.StreamReader(`$client, `$encoding)
        `$writer = New-Object System.IO.StreamWriter(`$client, `$encoding)
        `$writer.AutoFlush = `$true
        `$writer.WriteLine(`$json)

        `$line = `$reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace(`$line)) {
            throw 'Der Softwarekatalog-Dienst hat keine Antwort gesendet.'
        }

        `$response = `$line | ConvertFrom-Json
        if (-not `$response.Success) {
            throw ([string]`$response.Message)
        }

        return `$response
    }
    catch [System.TimeoutException] {
        throw 'Der Softwarekatalog-Dienst ist nicht erreichbar oder startet noch. Bitte versuchen Sie es erneut.'
    }
    finally {
        `$client.Dispose()
    }
}

if (`$Uninstall) {
    `$Action = 'Uninstall'
}

if (`$List) {
    `$response = Invoke-CatalogDaemon -Command 'GetCatalog'
    Write-Host 'Freigegebene Anwendungen:'
    @(`$response.Catalog) | Sort-Object DisplayName | ForEach-Object {
        Write-Host (" - {0} [{1}] : {2}" -f `$_.DisplayName, `$_.Alias, `$_.Description)
    }
    exit 0
}

if (-not `$AppAlias) {
    throw 'Sie müssen -AppAlias angeben oder -List verwenden.'
}

`$alias = `$AppAlias.Trim().ToLowerInvariant()
`$response = Invoke-CatalogDaemon -Command `$Action -Alias `$alias

if (`$Action -eq 'Uninstall') {
    Write-Host "Deinstallation für '`$alias' gestartet."
}
else {
    Write-Host "Installation für '`$alias' gestartet."
}

if (`$response.Message) {
    Write-Host `$response.Message
}
"@

    Write-TextFile -Path $RequestToolPath -Content $content -Encoding Utf8Bom
    Set-FileAclAdminsOnly -Path $RequestToolPath
}

function New-CatalogGui {
    $pipeLiteral      = $PipeName.Replace("'", "''")
    $titleLiteral     = $CatalogDisplayName.Replace("'", "''")
    $logLiteral       = $LogFile.Replace("'", "''")
    $installedLiteral = $InstalledPackagesPath.Replace("'", "''")

$content = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ('ListViewColumnSorter' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Windows.Forms;

public class ListViewColumnSorter : IComparer {
    public int Column = 0;
    public SortOrder Order = SortOrder.Ascending;

    public int Compare(object x, object y) {
        var itemX = x as ListViewItem;
        var itemY = y as ListViewItem;
        string a = string.Empty;
        string b = string.Empty;

        if (itemX != null && itemX.SubItems.Count > Column) {
            a = itemX.SubItems[Column].Text;
        }
        if (itemY != null && itemY.SubItems.Count > Column) {
            b = itemY.SubItems[Column].Text;
        }

        int result = StringComparer.CurrentCultureIgnoreCase.Compare(a, b);
        return Order == SortOrder.Descending ? -result : result;
    }
}
'@ -ReferencedAssemblies @('System.dll','System.Windows.Forms.dll')
}

if (-not ('ShellIconExtractor' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ShellIconExtractor {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern uint ExtractIconEx(string szFileName, int nIconIndex, IntPtr[] phiconLarge, IntPtr[] phiconSmall, uint nIcons);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
}

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

`$PipeName = '$pipeLiteral'
`$CatalogTitle = '$titleLiteral'
`$LogFile = '$logLiteral'
`$InstalledPackagesPath = '$installedLiteral'
`$AllowUserInstalls = `$true
`$AllowUserUninstall = `$true

function Set-FormIcon {
    param([Parameter(Mandatory=`$true)]`$Form)

    `$large = `$null
    `$small = `$null

    try {
        `$iconFile = Join-Path `$env:SystemRoot 'System32\shell32.dll'
        `$large = New-Object System.IntPtr[] 1
        `$small = New-Object System.IntPtr[] 1
        `$count = [ShellIconExtractor]::ExtractIconEx(`$iconFile, 80, `$large, `$small, 1)

        if (`$count -gt 0) {
            `$useHandle = [IntPtr]::Zero
            if (`$small[0] -ne [IntPtr]::Zero) {
                `$useHandle = `$small[0]
            }
            elseif (`$large[0] -ne [IntPtr]::Zero) {
                `$useHandle = `$large[0]
            }

            if (`$useHandle -ne [IntPtr]::Zero) {
                `$icon = [System.Drawing.Icon]::FromHandle(`$useHandle)
                `$Form.Icon = [System.Drawing.Icon]`$icon.Clone()
            }
        }
    }
    catch {
    }
    finally {
        try {
            if (`$small -and `$small[0] -ne [IntPtr]::Zero) {
                [void][ShellIconExtractor]::DestroyIcon(`$small[0])
            }
        }
        catch {
        }

        try {
            if (`$large -and `$large[0] -ne [IntPtr]::Zero) {
                [void][ShellIconExtractor]::DestroyIcon(`$large[0])
            }
        }
        catch {
        }
    }
}

function Invoke-CatalogDaemon {
    param(
        [Parameter(Mandatory=`$true)][string]`$Command,
        [string]`$Alias
    )

    `$payload = [ordered]@{
        Command  = `$Command
        AppAlias = `$Alias
    }
    `$json = `$payload | ConvertTo-Json -Compress

    `$encoding = New-Object System.Text.UTF8Encoding(`$false)
    `$client = New-Object System.IO.Pipes.NamedPipeClientStream -ArgumentList @(
        '.',
        `$PipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::None,
        [System.Security.Principal.TokenImpersonationLevel]::Impersonation
    )

    try {
        `$client.Connect(60000)
        `$reader = New-Object System.IO.StreamReader(`$client, `$encoding)
        `$writer = New-Object System.IO.StreamWriter(`$client, `$encoding)
        `$writer.AutoFlush = `$true
        `$writer.WriteLine(`$json)

        `$line = `$reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace(`$line)) {
            throw 'Der Softwarekatalog-Dienst hat keine Antwort gesendet.'
        }

        `$response = `$line | ConvertFrom-Json
        if (-not `$response.Success) {
            throw ([string]`$response.Message)
        }

        return `$response
    }
    catch [System.TimeoutException] {
        throw 'Der Softwarekatalog-Dienst ist nicht erreichbar oder startet noch. Bitte versuchen Sie es erneut.'
    }
    finally {
        `$client.Dispose()
    }
}

function New-AppRequest {
    param(
        [Parameter(Mandatory=`$true)][string]`$Alias,
        [Parameter(Mandatory=`$true)][ValidateSet('Install','Uninstall')][string]`$Action
    )

    return Invoke-CatalogDaemon -Command `$Action -Alias (`$Alias.Trim().ToLowerInvariant())
}

function Get-CatalogApps {
    `$response = Invoke-CatalogDaemon -Command 'GetCatalog'
    `$script:AllowUserInstalls = [bool]`$response.AllowUserInstalls
    `$script:AllowUserUninstall = [bool]`$response.AllowUserUninstall
    return @(`$response.Catalog)
}

function Get-InstalledPackageState {
    `$state = [ordered]@{
        GeneratedAt = `$null
        PackageSet  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }

    if (-not (Test-Path -LiteralPath `$InstalledPackagesPath)) {
        return [pscustomobject]`$state
    }

    try {
        `$raw = Get-Content -LiteralPath `$InstalledPackagesPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace(`$raw)) {
            return [pscustomobject]`$state
        }

        `$snapshot = `$raw | ConvertFrom-Json
        if (`$snapshot.GeneratedAt) {
            `$state.GeneratedAt = [string]`$snapshot.GeneratedAt
        }

        foreach (`$id in @(`$snapshot.InstalledPackageIds)) {
            if (`$id) {
                [void]`$state.PackageSet.Add(([string]`$id).Trim())
            }
        }
    }
    catch {
    }

    return [pscustomobject]`$state
}

function Get-AppStatus {
    param(
        [Parameter(Mandatory=`$true)]`$App,
        [Parameter(Mandatory=`$true)]`$InstalledSet
    )

    if (`$InstalledSet.Contains(`$App.PackageId)) {
        return 'Installiert'
    }

    return 'Installierbar'
}

`$form = New-Object System.Windows.Forms.Form
`$form.Text = `$CatalogTitle
`$form.StartPosition = 'CenterScreen'
`$form.Size = New-Object System.Drawing.Size(980, 660)
`$form.MinimumSize = New-Object System.Drawing.Size(960, 640)
`$form.TopMost = `$false
`$form.ShowIcon = `$true
`$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
`$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F3F3F3')
Set-FormIcon -Form `$form

`$headerPanel = New-Object System.Windows.Forms.Panel
`$headerPanel.Location = New-Object System.Drawing.Point(12, 12)
`$headerPanel.Size = New-Object System.Drawing.Size(940, 84)
`$headerPanel.Anchor = 'Top, Left, Right'
`$headerPanel.BackColor = [System.Drawing.SystemColors]::Window
`$headerPanel.BorderStyle = 'FixedSingle'

`$headerAccent = New-Object System.Windows.Forms.Panel
`$headerAccent.Location = New-Object System.Drawing.Point(0, 0)
`$headerAccent.Size = New-Object System.Drawing.Size(6, 82)
`$headerAccent.Anchor = 'Top, Left, Bottom'
`$headerAccent.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0F6CBD')

`$headerTitle = New-Object System.Windows.Forms.Label
`$headerTitle.Location = New-Object System.Drawing.Point(18, 12)
`$headerTitle.Size = New-Object System.Drawing.Size(900, 24)
`$headerTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
`$headerTitle.Text = `$CatalogTitle

`$headerPanel.Controls.Add(`$headerAccent)
`$headerPanel.Controls.Add(`$headerTitle)

`$groupApps = New-Object System.Windows.Forms.Panel
`$groupApps.Location = New-Object System.Drawing.Point(12, 104)
`$groupApps.Size = New-Object System.Drawing.Size(940, 352)
`$groupApps.Anchor = 'Top, Left, Right, Bottom'
`$groupApps.BackColor = [System.Drawing.SystemColors]::Window
`$groupApps.BorderStyle = 'FixedSingle'

`$listCaption = New-Object System.Windows.Forms.Label
`$listCaption.Location = New-Object System.Drawing.Point(12, 10)
`$listCaption.Size = New-Object System.Drawing.Size(912, 20)
`$listCaption.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
`$listCaption.Text = 'Freigegebene Anwendungen'

`$list = New-Object System.Windows.Forms.ListView
`$list.Location = New-Object System.Drawing.Point(12, 34)
`$list.Size = New-Object System.Drawing.Size(916, 306)
`$list.Anchor = 'Top, Left, Right, Bottom'
`$list.View = 'Details'
`$list.FullRowSelect = `$true
`$list.MultiSelect = `$false
`$list.GridLines = `$false
`$list.HideSelection = `$false
[void]`$list.Columns.Add('Anwendung', 260)
[void]`$list.Columns.Add('Beschreibung', 450)
[void]`$list.Columns.Add('Status', 150)
[void]`$list.Columns.Add('Alias', 110)
[void]`$list.Columns.Add('Paket-ID', 100)
`$list.BorderStyle = 'None'
`$list.HeaderStyle = 'Clickable'

`$columnSorter = New-Object ListViewColumnSorter
`$list.ListViewItemSorter = `$columnSorter

function Sort-ListByColumn {
    param([Parameter(Mandatory=`$true)][int]`$ColumnIndex)

    if (`$columnSorter.Column -eq `$ColumnIndex) {
        if (`$columnSorter.Order -eq [System.Windows.Forms.SortOrder]::Ascending) {
            `$columnSorter.Order = [System.Windows.Forms.SortOrder]::Descending
        }
        else {
            `$columnSorter.Order = [System.Windows.Forms.SortOrder]::Ascending
        }
    }
    else {
        `$columnSorter.Column = `$ColumnIndex
        `$columnSorter.Order = [System.Windows.Forms.SortOrder]::Ascending
    }

    `$list.Sort()
}

`$groupApps.Controls.Add(`$listCaption)
`$groupApps.Controls.Add(`$list)

`$infoPanel = New-Object System.Windows.Forms.Panel
`$infoPanel.Location = New-Object System.Drawing.Point(12, 466)
`$infoPanel.Size = New-Object System.Drawing.Size(940, 64)
`$infoPanel.Anchor = 'Left, Right, Bottom'
`$infoPanel.BorderStyle = 'FixedSingle'
`$infoPanel.BackColor = [System.Drawing.SystemColors]::Window

`$snapshotLabel = New-Object System.Windows.Forms.Label
`$snapshotLabel.Location = New-Object System.Drawing.Point(10, 8)
`$snapshotLabel.Size = New-Object System.Drawing.Size(914, 18)
`$snapshotLabel.Text = 'Installationsdaten: kein Datenstand vorhanden'

`$installedLabel = New-Object System.Windows.Forms.Label
`$installedLabel.Location = New-Object System.Drawing.Point(10, 30)
`$installedLabel.Size = New-Object System.Drawing.Size(914, 24)
`$installedLabel.Text = 'Bereits installiert: keine'

`$infoPanel.Controls.Add(`$snapshotLabel)
`$infoPanel.Controls.Add(`$installedLabel)

function Update-InstallButtonState {
    if (`$list.SelectedItems.Count -lt 1) {
        `$btnInstall.Enabled = `$false
        `$btnUninstall.Enabled = `$false
        return
    }

    `$selectedItem = `$list.SelectedItems[0]
    `$state = `$selectedItem.SubItems[2].Text

    `$btnInstall.Enabled = (`$script:AllowUserInstalls -and `$state -eq 'Installierbar')
    `$btnUninstall.Enabled = (`$script:AllowUserUninstall -and `$state -eq 'Installiert')
}

function Load-AppList {
    `$selectedAlias = `$null
    `$list.BeginUpdate()
    try {
        if (`$list.SelectedItems.Count -gt 0) {
            `$selectedAlias = [string]`$list.SelectedItems[0].SubItems[3].Text
        }

        `$list.Items.Clear()

        `$apps = Get-CatalogApps
        `$installedState = Get-InstalledPackageState
        `$installedSet = `$installedState.PackageSet

        if (-not `$installedSet) {
            `$installedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        }

        `$installedNames = New-Object 'System.Collections.Generic.List[string]'

        foreach (`$app in (`$apps | Sort-Object DisplayName)) {
            `$state = Get-AppStatus -App `$app -InstalledSet `$installedSet

            `$item = New-Object System.Windows.Forms.ListViewItem(`$app.DisplayName)
            [void]`$item.SubItems.Add(`$app.Description)
            [void]`$item.SubItems.Add(`$state)
            [void]`$item.SubItems.Add(`$app.Alias)
            [void]`$item.SubItems.Add(`$app.PackageId)
            `$item.Tag = `$app

            if (`$state -eq 'Installiert') {
                `$item.ForeColor = [System.Drawing.Color]::DarkGreen
                [void]`$installedNames.Add(`$app.DisplayName)
            }

            [void]`$list.Items.Add(`$item)
        }

        foreach (`$col in `$list.Columns) {
            if (`$col.Text -eq 'Paket-ID') { `$col.Width = 0 }
        }

        `$list.Sort()

        if (`$installedState.GeneratedAt) {
            try {
                `$timestamp = [DateTime]::Parse(`$installedState.GeneratedAt).ToLocalTime()
                `$snapshotLabel.Text = 'Installationsdaten vom: ' + `$timestamp.ToString('dd.MM.yyyy HH:mm:ss')
            }
            catch {
                `$snapshotLabel.Text = 'Installationsdaten vom: ' + `$installedState.GeneratedAt
            }
        }
        else {
            `$snapshotLabel.Text = 'Installationsdaten: kein Datenstand vorhanden'
        }

        if (`$installedNames.Count -gt 0) {
            `$installedLabel.Text = 'Bereits installiert: ' + (`$installedNames -join ', ')
        }
        else {
            `$installedLabel.Text = 'Bereits installiert: keine freigegebene Software erkannt'
        }

        `$status.Text = 'Liste aktualisiert.'
    }
    finally {
        `$list.EndUpdate()

        if (-not [string]::IsNullOrWhiteSpace(`$selectedAlias)) {
            foreach (`$item in `$list.Items) {
                if (`$item.SubItems.Count -gt 3 -and [string]::Equals(`$item.SubItems[3].Text, `$selectedAlias, [System.StringComparison]::OrdinalIgnoreCase)) {
                    `$item.Selected = `$true
                    `$item.EnsureVisible()
                    break
                }
            }
        }

        Update-InstallButtonState
    }
}

`$status = New-Object System.Windows.Forms.Label
`$status.Location = New-Object System.Drawing.Point(12, 544)
`$status.Size = New-Object System.Drawing.Size(700, 20)
`$status.Anchor = 'Left, Right, Bottom'
`$status.ForeColor = [System.Drawing.Color]::DimGray
`$status.Text = 'Bereit.'

`$btnInstall = New-Object System.Windows.Forms.Button
`$btnInstall.Location = New-Object System.Drawing.Point(12, 568)
`$btnInstall.Size = New-Object System.Drawing.Size(170, 30)
`$btnInstall.Anchor = 'Left, Bottom'
`$btnInstall.Text = 'Installieren'
`$btnInstall.Enabled = `$false

`$btnUninstall = New-Object System.Windows.Forms.Button
`$btnUninstall.Location = New-Object System.Drawing.Point(190, 568)
`$btnUninstall.Size = New-Object System.Drawing.Size(140, 30)
`$btnUninstall.Anchor = 'Left, Bottom'
`$btnUninstall.Text = 'Deinstallation'
`$btnUninstall.Enabled = `$false

`$btnRefresh = New-Object System.Windows.Forms.Button
`$btnRefresh.Location = New-Object System.Drawing.Point(338, 568)
`$btnRefresh.Size = New-Object System.Drawing.Size(110, 30)
`$btnRefresh.Anchor = 'Left, Bottom'
`$btnRefresh.Text = 'Aktualisieren'

`$btnOpenLog = New-Object System.Windows.Forms.Button
`$btnOpenLog.Location = New-Object System.Drawing.Point(456, 568)
`$btnOpenLog.Size = New-Object System.Drawing.Size(130, 30)
`$btnOpenLog.Anchor = 'Left, Bottom'
`$btnOpenLog.Text = 'Protokoll öffnen'

`$btnClose = New-Object System.Windows.Forms.Button
`$btnClose.Location = New-Object System.Drawing.Point(832, 568)
`$btnClose.Size = New-Object System.Drawing.Size(120, 30)
`$btnClose.Anchor = 'Right, Bottom'
`$btnClose.Text = 'Schließen'

`$autoRefreshTimer = New-Object System.Windows.Forms.Timer
`$autoRefreshTimer.Interval = 15000

`$btnInstall.Add_Click({
    try {
        if (`$list.SelectedItems.Count -lt 1) {
            [System.Windows.Forms.MessageBox]::Show(
                'Bitte zuerst eine Anwendung auswählen.',
                `$CatalogTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        `$selectedItem = `$list.SelectedItems[0]
        `$selected = `$selectedItem.Tag
        `$currentState = `$selectedItem.SubItems[2].Text

        if (`$currentState -eq 'Installiert') {
            [System.Windows.Forms.MessageBox]::Show(
                ("{0} ist bereits installiert." -f `$selected.DisplayName),
                `$CatalogTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        `$status.Text = "Installation läuft: {0}" -f `$selected.DisplayName
        `$response = New-AppRequest -Alias `$selected.Alias -Action 'Install'
        `$status.Text = if (`$response.Message) { `$response.Message } else { "Installation gestartet: {0}" -f `$selected.DisplayName }

        [System.Windows.Forms.MessageBox]::Show(
            ("Installation gestartet:`r`n`r`n{0}`r`nAlias: {1}" -f `$selected.DisplayName, `$selected.Alias),
            `$CatalogTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        Load-AppList
    }
    catch {
        `$status.Text = "Fehler: " + `$_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show(
            `$_.Exception.Message,
            `$CatalogTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

`$btnUninstall.Add_Click({
    try {
        if (`$list.SelectedItems.Count -lt 1) {
            [System.Windows.Forms.MessageBox]::Show(
                'Bitte zuerst eine Anwendung auswählen.',
                `$CatalogTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        `$selectedItem = `$list.SelectedItems[0]
        `$selected = `$selectedItem.Tag
        `$currentState = `$selectedItem.SubItems[2].Text

        if (`$currentState -ne 'Installiert') {
            [System.Windows.Forms.MessageBox]::Show(
                ("{0} ist derzeit nicht als installiert markiert." -f `$selected.DisplayName),
                `$CatalogTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        `$status.Text = "Deinstallation läuft: {0}" -f `$selected.DisplayName
        `$response = New-AppRequest -Alias `$selected.Alias -Action 'Uninstall'
        `$status.Text = if (`$response.Message) { `$response.Message } else { "Deinstallation gestartet: {0}" -f `$selected.DisplayName }

        [System.Windows.Forms.MessageBox]::Show(
            ("Deinstallation gestartet:`r`n`r`n{0}`r`nAlias: {1}" -f `$selected.DisplayName, `$selected.Alias),
            `$CatalogTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        Load-AppList
    }
    catch {
        `$status.Text = "Fehler: " + `$_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show(
            `$_.Exception.Message,
            `$CatalogTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

`$btnRefresh.Add_Click({
    try {
        `$status.Text = 'Installationsdaten werden aktualisiert...'
        `$null = Invoke-CatalogDaemon -Command 'RefreshStatus'
        Load-AppList
    }
    catch {
        `$status.Text = "Fehler: " + `$_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show(
            `$_.Exception.Message,
            `$CatalogTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

`$autoRefreshTimer.Add_Tick({
    try {
        Load-AppList
    }
    catch {
        `$status.Text = "Fehler bei automatischer Aktualisierung: " + `$_.Exception.Message
    }
})

`$btnOpenLog.Add_Click({
    try {
        if ([string]::IsNullOrWhiteSpace(`$LogFile)) {
            throw 'Der Pfad zur Protokolldatei ist leer.'
        }

        if (Test-Path -LiteralPath `$LogFile) {
            Start-Process -FilePath 'notepad.exe' -ArgumentList @(`$LogFile)
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                'Die Protokolldatei wurde noch nicht erstellt.',
                `$CatalogTitle,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            `$_.Exception.Message,
            `$CatalogTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

`$btnClose.Add_Click({ `$form.Close() })

`$form.Add_Shown({ `$autoRefreshTimer.Start() })
`$form.Add_FormClosing({
    `$autoRefreshTimer.Stop()
    `$autoRefreshTimer.Dispose()
})

`$list.Add_SelectedIndexChanged({ Update-InstallButtonState })
`$list.Add_ColumnClick({
    param(`$sender, `$eventArgs)
    Sort-ListByColumn -ColumnIndex `$eventArgs.Column
})

`$list.Add_DoubleClick({
    if (`$list.SelectedItems.Count -gt 0) {
        if (`$btnInstall.Enabled) {
            `$btnInstall.PerformClick()
        }
    }
})

`$form.Controls.Add(`$headerPanel)
`$form.Controls.Add(`$groupApps)
`$form.Controls.Add(`$infoPanel)
`$form.Controls.Add(`$status)
`$form.Controls.Add(`$btnInstall)
`$form.Controls.Add(`$btnUninstall)
`$form.Controls.Add(`$btnRefresh)
`$form.Controls.Add(`$btnOpenLog)
`$form.Controls.Add(`$btnClose)

`$form.AcceptButton = `$btnInstall
`$form.CancelButton = `$btnClose

try {
    `$null = Invoke-CatalogDaemon -Command 'RefreshStatus'
    Load-AppList
}
catch {
    `$status.Text = "Fehler beim Laden: " + `$_.Exception.Message
    [System.Windows.Forms.MessageBox]::Show(
        "Der Softwarekatalog konnte nicht vollständig geladen werden.`r`n`r`n" + `$_.Exception.Message,
        `$CatalogTitle,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

[void]`$form.ShowDialog()
"@

    Write-TextFile -Path $CatalogGuiPath -Content $content -Encoding Utf8Bom
    Set-FileAclAdminsOnly -Path $CatalogGuiPath
}

function New-CatalogLauncher {
    $psQuoted = $PowerShellExe.Replace('"', '""')
    $guiQuoted = $CatalogGuiPath.Replace('"', '""')

    $vbs = @"
Set shell = CreateObject("WScript.Shell")
cmdLine = Chr(34) & "$psQuoted" & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & "$guiQuoted" & Chr(34)
shell.Run cmdLine, 0, False
"@

    Write-TextFile -Path $CatalogLauncherPath -Content $vbs -Encoding Unicode
    Set-FileAclAdminsOnly -Path $CatalogLauncherPath
}

function New-Shortcut {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath
    )

    $parent = Split-Path -Path $ShortcutPath -Parent
    Ensure-Directory -Path $parent

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $WScriptExe
    $shortcut.Arguments = "`"$CatalogLauncherPath`""
    $shortcut.WorkingDirectory = $BaseDir
    $shortcut.WindowStyle = 1
    $shortcut.Description = $CatalogDisplayName
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,80"
    $shortcut.Save()
}

function Unregister-LegacyQueueTask {
    try {
        $task = Get-ScheduledTask -TaskName $LegacyQueueTaskName -ErrorAction SilentlyContinue
        if ($task) {
            Write-Log "Removing legacy scheduled task '$LegacyQueueTaskName'."
            Unregister-ScheduledTask -TaskName $LegacyQueueTaskName -Confirm:$false
        }
    }
    catch {
        Write-Log "Could not remove legacy scheduled task '$LegacyQueueTaskName': $($_.Exception.Message)" 'WARN'
    }
}

function Register-OrUpdateTasks {
    Unregister-LegacyQueueTask

    try {
        $existingDaemon = Get-ScheduledTask -TaskName $DaemonTaskName -ErrorAction SilentlyContinue
        if ($existingDaemon) {
            Write-Log "Stopping scheduled task '$DaemonTaskName' before update."
            Stop-ScheduledTask -TaskName $DaemonTaskName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }
    catch {
        Write-Log "Could not stop daemon task '$DaemonTaskName': $($_.Exception.Message)" 'WARN'
    }

    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    Write-Log "Registering/updating scheduled task '$DaemonTaskName'."
    $daemonArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$LocalScriptPath`" -Mode Daemon"
    $daemonAction = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $daemonArgs
    $daemonTrigger = New-ScheduledTaskTrigger -AtStartup
    $daemonSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    $daemonTask = New-ScheduledTask `
        -Action $daemonAction `
        -Trigger $daemonTrigger `
        -Principal $principal `
        -Settings $daemonSettings

    Register-ScheduledTask -TaskName $DaemonTaskName -InputObject $daemonTask -Force | Out-Null

    Write-Log "Registering/updating scheduled task '$UpgradeTaskName'."
    $upgradeArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$LocalScriptPath`" -Mode UpgradeAll"
    $upgradeAction = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $upgradeArgs
    $upgradeTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(2)) `
        -RepetitionInterval (New-TimeSpan -Hours 2) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $upgradeSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    $upgradeTask = New-ScheduledTask `
        -Action $upgradeAction `
        -Trigger $upgradeTrigger `
        -Principal $principal `
        -Settings $upgradeSettings

    Register-ScheduledTask -TaskName $UpgradeTaskName -InputObject $upgradeTask -Force | Out-Null

    try {
        Start-ScheduledTask -TaskName $DaemonTaskName
    }
    catch {
        Write-Log "Could not start daemon task '$DaemonTaskName': $($_.Exception.Message)" 'WARN'
    }
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId
    )

    $arguments = @(
        'install'
        '--id', $PackageId
        '--exact'
        '--scope', 'machine'
        '--silent'
        '--accept-package-agreements'
        '--accept-source-agreements'
        '--disable-interactivity'
    )

    Write-Log "Executing: `"$WingetPath`" $($arguments -join ' ')"
    $output = & $WingetPath @arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($output) {
        foreach ($line in ($output -split "`r?`n")) {
            if ($line.Trim()) {
                Write-Log "winget: $line"
            }
        }
    }

    return $exitCode
}

function Invoke-WingetUninstall {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId
    )

    $arguments = @(
        'uninstall'
        '--id', $PackageId
        '--exact'
        '--scope', 'machine'
        '--silent'
        '--accept-source-agreements'
        '--disable-interactivity'
    )

    Write-Log "Executing: `"$WingetPath`" $($arguments -join ' ')"
    $output = & $WingetPath @arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($output) {
        foreach ($line in ($output -split "`r?`n")) {
            if ($line.Trim()) {
                Write-Log "winget: $line"
            }
        }
    }

    return $exitCode
}

function Invoke-WingetUpgradeAll {
    param([Parameter(Mandatory)][string]$WingetPath)

    $arguments = @(
        'upgrade'
        '--all'
        '--scope', 'machine'
        '--silent'
        '--accept-package-agreements'
        '--accept-source-agreements'
        '--disable-interactivity'
    )

    Write-Log "Executing 2-hour upgrade: `"$WingetPath`" $($arguments -join ' ')"
    $output = & $WingetPath @arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($output) {
        foreach ($line in ($output -split "`r?`n")) {
            if ($line.Trim()) {
                Write-Log "winget upgrade: $line"
            }
        }
    }

    return $exitCode
}

function Update-InstalledPackagesSnapshot {
    param([Parameter(Mandatory)][string]$WingetPath)

    Ensure-Directory -Path $BaseDir

    $tempRoot = if ($env:TEMP) { $env:TEMP } elseif ($env:TMP) { $env:TMP } else { $BaseDir }
    $tempFile = Join-Path $tempRoot ("selfservice-winget-export-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    $snapshotTempFile = Join-Path $BaseDir ("Installed-Packages-{0}.json.tmp" -f [Guid]::NewGuid().ToString('N'))

    $arguments = @(
        'export'
        '--output', $tempFile
        '--accept-source-agreements'
        '--disable-interactivity'
    )

    Write-Log 'Refreshing installed package snapshot.'
    $output = & $WingetPath @arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($output) {
        foreach ($line in ($output -split "`r?`n")) {
            if ($line.Trim()) {
                Write-Log "winget export: $line"
            }
        }
    }

    if ($exitCode -ne 0) {
        Write-Log "winget export failed with code $exitCode; snapshot was not updated." 'WARN'
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        return $false
    }

    if (-not (Test-Path -LiteralPath $tempFile)) {
        Write-Log 'winget export did not produce an output file; snapshot was not updated.' 'WARN'
        return $false
    }

    try {
        $raw = Get-Content -LiteralPath $tempFile -Raw -Encoding UTF8
        $export = $raw | ConvertFrom-Json

        $packageIds = @()
        foreach ($source in @($export.Sources)) {
            foreach ($pkg in @($source.Packages)) {
                if ($pkg.PackageIdentifier) {
                    $packageIds += [string]$pkg.PackageIdentifier
                }
                elseif ($pkg.PackageId) {
                    $packageIds += [string]$pkg.PackageId
                }
            }
        }

        $packageIds = $packageIds |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Sort-Object -Unique

        $snapshot = [ordered]@{
            GeneratedAt          = (Get-Date).ToString('o')
            InstalledPackageIds  = @($packageIds)
        }

        $snapshot | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $snapshotTempFile -Encoding UTF8
        Move-Item -LiteralPath $snapshotTempFile -Destination $InstalledPackagesPath -Force
        Write-Log "Installed package snapshot written to '$InstalledPackagesPath' (count=$(@($packageIds).Count))."
        return $true
    }
    catch {
        Write-Log "Failed to write installed package snapshot: $($_.Exception.Message)" 'WARN'
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $snapshotTempFile) {
            Remove-Item -LiteralPath $snapshotTempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-InstalledPackageIdSet {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path -LiteralPath $InstalledPackagesPath)) {
        return $set
    }

    try {
        $raw = Get-Content -LiteralPath $InstalledPackagesPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $set
        }

        $snapshot = $raw | ConvertFrom-Json
        foreach ($id in @($snapshot.InstalledPackageIds)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$id)) {
                [void]$set.Add(([string]$id).Trim())
            }
        }
    }
    catch {
        Write-Log "Failed to read installed package snapshot: $($_.Exception.Message)" 'WARN'
    }

    return $set
}

function Invoke-RequiredSoftwarePolicy {
    param([Parameter(Mandatory)][string]$WingetPath)

    if (-not (Test-SoftwareCatalogPolicyEnabled)) {
        Write-Log 'Required software policy skipped because Softwarekatalog policy is disabled or not configured.' 'WARN'
        return [pscustomobject]@{ Installed = 0; Failed = 0; Skipped = 0 }
    }

    if (-not (Test-RequiredEnforcementEnabled)) {
        Write-Log 'Required software enforcement is disabled by policy.'
        return [pscustomobject]@{ Installed = 0; Failed = 0; Skipped = 0 }
    }

    $requiredAliases = @(Get-RequiredAliases)
    if ($requiredAliases.Count -lt 1) {
        Write-Log 'No required software configured by policy.'
        return [pscustomobject]@{ Installed = 0; Failed = 0; Skipped = 0 }
    }

    $installedCount = 0
    $failedCount = 0
    $skippedCount = 0

    $result = Invoke-WithWingetLock -ScriptBlock {
        $snapshotUpdated = Update-InstalledPackagesSnapshot -WingetPath $WingetPath
        if (-not $snapshotUpdated) {
            throw 'Could not refresh installed package snapshot before required software enforcement.'
        }

        $installedSet = Get-InstalledPackageIdSet
        foreach ($alias in $requiredAliases) {
            $app = Get-AppCatalogObjectByAlias -Alias $alias
            if (-not $app) {
                Write-Log "Required alias '$alias' is not present in catalog policy; skipping." 'WARN'
                $skippedCount++
                continue
            }

            if ($installedSet.Contains([string]$app.PackageId)) {
                $skippedCount++
                continue
            }

            Write-Log "Installing required software alias '$($app.Alias)' package '$($app.PackageId)'."
            $exitCode = Invoke-WingetInstall -WingetPath $WingetPath -PackageId ([string]$app.PackageId)
            if ($exitCode -eq 0) {
                $installedCount++
                [void]$installedSet.Add([string]$app.PackageId)
            }
            else {
                $failedCount++
                Write-Log "Required install failed for alias '$($app.Alias)' package '$($app.PackageId)' with code $exitCode." 'ERROR'
            }
        }

        $null = Update-InstalledPackagesSnapshot -WingetPath $WingetPath
        [pscustomobject]@{
            Installed = $installedCount
            Failed    = $failedCount
            Skipped   = $skippedCount
        }
    }

    return @($result)[-1]
}

function New-CatalogPipeSecurity {
    $pipeSecurity = New-Object System.IO.Pipes.PipeSecurity

    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $sidUsers = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')

    $ruleSystem = New-Object System.IO.Pipes.PipeAccessRule(
        $sidSystem,
        [System.IO.Pipes.PipeAccessRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $ruleAdmins = New-Object System.IO.Pipes.PipeAccessRule(
        $sidAdmins,
        [System.IO.Pipes.PipeAccessRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    $ruleUsers = New-Object System.IO.Pipes.PipeAccessRule(
        $sidUsers,
        [System.IO.Pipes.PipeAccessRights]::ReadWrite,
        [System.Security.AccessControl.AccessControlType]::Allow
    )

    $null = $pipeSecurity.AddAccessRule($ruleSystem)
    $null = $pipeSecurity.AddAccessRule($ruleAdmins)
    $null = $pipeSecurity.AddAccessRule($ruleUsers)

    return $pipeSecurity
}

function New-CatalogPipeServer {
    $pipeSecurity = New-CatalogPipeSecurity
    return New-Object System.IO.Pipes.NamedPipeServerStream -ArgumentList @(
        $PipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::None,
        4096,
        4096,
        $pipeSecurity
    )
}

function Get-PipeClientIdentity {
    param([Parameter(Mandatory)][System.IO.Pipes.NamedPipeServerStream]$Pipe)

    $script:PipeClientIdentityName = $null
    $script:PipeClientIdentitySid = $null

    try {
        $Pipe.RunAsClient([System.IO.Pipes.PipeStreamImpersonationWorker]{
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $script:PipeClientIdentityName = $identity.Name
            if ($identity.User) {
                $script:PipeClientIdentitySid = $identity.User.Value
            }
        })
    }
    catch {
        try {
            $script:PipeClientIdentityName = $Pipe.GetImpersonationUserName()
        }
        catch {
        }
    }

    if ([string]::IsNullOrWhiteSpace($script:PipeClientIdentityName)) {
        $script:PipeClientIdentityName = 'Unknown'
    }

    return [pscustomobject]@{
        Name = $script:PipeClientIdentityName
        Sid  = $script:PipeClientIdentitySid
    }
}

function Invoke-CatalogDaemonCommand {
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)]$ClientIdentity
    )

    if (-not $ClientIdentity -or [string]::IsNullOrWhiteSpace($ClientIdentity.Name) -or $ClientIdentity.Name -eq 'Unknown') {
        throw 'Named pipe client could not be authenticated.'
    }

    $command = $null
    $commandProperty = $Request.PSObject.Properties['Command']
    $actionProperty = $Request.PSObject.Properties['Action']
    if ($commandProperty -and $commandProperty.Value) {
        $command = [string]$commandProperty.Value
    }
    elseif ($actionProperty -and $actionProperty.Value) {
        $command = [string]$actionProperty.Value
    }

    if ([string]::IsNullOrWhiteSpace($command)) {
        throw 'Missing command.'
    }

    $command = $command.Trim().ToLowerInvariant()

    switch ($command) {
        'getcatalog' {
            $catalog = @(Get-AppCatalogObjects | Sort-Object DisplayName)
            $requiredAliases = @(Get-RequiredAliases)
            return [pscustomobject]@{
                Success            = $true
                Command            = $command
                RequestedBy        = $ClientIdentity.Name
                RequestedBySid     = $ClientIdentity.Sid
                Catalog            = $catalog
                RequiredAliases    = $requiredAliases
                AllowUserInstalls  = (Test-UserInstallsAllowed)
                AllowUserUninstall = (Test-UserUninstallAllowed)
                EnforceRequired    = (Test-RequiredEnforcementEnabled)
                Message            = 'Katalog geladen.'
            }
        }

        'applypolicy' {
            Write-Log "Authenticated policy apply requested by user='$($ClientIdentity.Name)' sid='$($ClientIdentity.Sid)'"

            if (-not (Test-WingetLockAvailable)) {
                throw 'Der Softwarekatalog-Dienst ist gerade mit einer anderen winget-Aktion beschäftigt. Bitte später erneut versuchen.'
            }

            Start-SoftwarekatalogWorker -WorkerMode ApplyPolicy
            return [pscustomobject]@{
                Success        = $true
                Command        = $command
                RequestedBy    = $ClientIdentity.Name
                RequestedBySid = $ClientIdentity.Sid
                Message        = 'Policyanwendung gestartet.'
            }
        }

        { $_ -in @('install','uninstall') } {
            if ($command -eq 'install' -and -not (Test-UserInstallsAllowed)) {
                throw 'Benutzerinstallationen sind per Richtlinie deaktiviert.'
            }

            if ($command -eq 'uninstall' -and -not (Test-UserUninstallAllowed)) {
                throw 'Benutzerdeinstallationen sind per Richtlinie deaktiviert.'
            }

            $appAliasProperty = $Request.PSObject.Properties['AppAlias']
            if (-not $appAliasProperty -or [string]::IsNullOrWhiteSpace([string]$appAliasProperty.Value)) {
                throw 'Missing AppAlias.'
            }

            $alias = ([string]$appAliasProperty.Value).Trim().ToLowerInvariant()
            $packageId = Get-PackageIdByAlias -Alias $alias
            if (-not $packageId) {
                throw "Alias '$alias' is not in the allowlist."
            }

            $actionText = if ($command -eq 'uninstall') { 'uninstall' } else { 'install' }
            Write-Log "Authenticated request: action=$actionText alias='$alias' package='$packageId' user='$($ClientIdentity.Name)' sid='$($ClientIdentity.Sid)'"

            if (-not (Test-WingetLockAvailable)) {
                throw 'Der Softwarekatalog-Dienst ist gerade mit einer anderen winget-Aktion beschäftigt. Bitte später erneut versuchen.'
            }

            Start-SoftwarekatalogWorker -WorkerMode ProcessRequest -WorkerAction $command -WorkerAlias $alias -WorkerRequestedBy $ClientIdentity.Name -WorkerRequestedBySid $ClientIdentity.Sid

            $verb = if ($command -eq 'uninstall') { 'Deinstallation' } else { 'Installation' }
            return [pscustomobject]@{
                Success         = $true
                Command         = $command
                AppAlias        = $alias
                PackageId       = $packageId
                RequestedBy     = $ClientIdentity.Name
                RequestedBySid  = $ClientIdentity.Sid
                Message         = "$verb gestartet: $alias"
            }
        }

        { $_ -in @('refreshstatus','getstatus') } {
            Write-Log "Authenticated status refresh requested by user='$($ClientIdentity.Name)' sid='$($ClientIdentity.Sid)'"
            $wingetPath = Ensure-WingetAvailable
            if (-not $wingetPath) {
                throw 'winget is unavailable.'
            }

            try {
                $result = Invoke-WithWingetLock -TimeoutSeconds 2 -ScriptBlock {
                    $snapshotUpdated = Update-InstalledPackagesSnapshot -WingetPath $wingetPath
                    [pscustomobject]@{ SnapshotUpdated = [bool]$snapshotUpdated }
                }
            }
            catch {
                if ($_.Exception.Message -like 'Timed out waiting for winget lock*') {
                    throw 'Der Softwarekatalog-Dienst ist gerade mit einer anderen winget-Aktion beschäftigt. Bitte später erneut versuchen.'
                }

                throw
            }
            $result = @($result)[-1]

            return [pscustomobject]@{
                Success         = [bool]$result.SnapshotUpdated
                Command         = $command
                RequestedBy     = $ClientIdentity.Name
                RequestedBySid  = $ClientIdentity.Sid
                SnapshotUpdated = [bool]$result.SnapshotUpdated
                Message         = 'Installationsdaten aktualisiert.'
            }
        }

        default {
            throw "Unsupported command '$command'."
        }
    }
}

function Start-CatalogDaemon {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir

    Write-Log "Named pipe daemon starting on '\\.\pipe\$PipeName'."

    try {
        Start-SoftwarekatalogWorker -WorkerMode ApplyPolicy
    }
    catch {
        Write-Log "Could not start initial required software enforcement worker: $($_.Exception.Message)" 'WARN'
    }

    while ($true) {
        $pipe = $null
        try {
            $pipe = New-CatalogPipeServer
            $pipe.WaitForConnection()

            $clientIdentity = Get-PipeClientIdentity -Pipe $pipe
            $encoding = New-Object System.Text.UTF8Encoding($false)
            $reader = New-Object System.IO.StreamReader($pipe, $encoding)
            $writer = New-Object System.IO.StreamWriter($pipe, $encoding)
            $writer.AutoFlush = $true

            $response = $null
            try {
                $line = $reader.ReadLine()
                if ([string]::IsNullOrWhiteSpace($line)) {
                    throw 'Empty request.'
                }

                $request = $line | ConvertFrom-Json
                $response = Invoke-CatalogDaemonCommand -Request $request -ClientIdentity $clientIdentity
            }
            catch {
                Write-Log "Named pipe request failed: $($_.Exception.Message)" 'ERROR'
                $response = [pscustomobject]@{
                    Success        = $false
                    RequestedBy    = $clientIdentity.Name
                    RequestedBySid = $clientIdentity.Sid
                    Message        = $_.Exception.Message
                }
            }

            $writer.WriteLine(($response | ConvertTo-Json -Compress -Depth 6))
        }
        catch {
            Write-Log "Named pipe daemon error: $($_.Exception.Message)" 'ERROR'
            Start-Sleep -Seconds 3
        }
        finally {
            if ($pipe) {
                $pipe.Dispose()
            }
        }
    }
}

function Invoke-UpgradeAllMode {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir

    $wingetPath = Ensure-WingetAvailable
    if (-not $wingetPath) {
        Write-Log 'Aborting upgrade because winget is unavailable.' 'ERROR'
        return
    }

    $result = Invoke-WithWingetLock -ScriptBlock {
        $exitCode = Invoke-WingetUpgradeAll -WingetPath $wingetPath
        $snapshotUpdated = Update-InstalledPackagesSnapshot -WingetPath $wingetPath
        [pscustomobject]@{
            ExitCode        = $exitCode
            SnapshotUpdated = [bool]$snapshotUpdated
        }
    }
    $result = @($result)[-1]

    if ($result.ExitCode -eq 0) {
        Write-Log "2-hour winget upgrade completed successfully. SnapshotUpdated=$($result.SnapshotUpdated)."
    }
    else {
        Write-Log "2-hour winget upgrade failed with code $($result.ExitCode). SnapshotUpdated=$($result.SnapshotUpdated)." 'WARN'
    }

    try {
        $requiredResult = Invoke-RequiredSoftwarePolicy -WingetPath $wingetPath
        Write-Log "Required policy after upgrade completed. Installed=$($requiredResult.Installed), Failed=$($requiredResult.Failed), Skipped=$($requiredResult.Skipped)."
    }
    catch {
        Write-Log "Required policy after upgrade failed: $($_.Exception.Message)" 'ERROR'
    }
}

function Invoke-ApplyPolicyMode {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir

    $wingetPath = Ensure-WingetAvailable
    if (-not $wingetPath) {
        Write-Log 'Aborting policy apply because winget is unavailable.' 'ERROR'
        return
    }

    $result = Invoke-RequiredSoftwarePolicy -WingetPath $wingetPath
    if ($result.Failed -eq 0) {
        Write-Log "Required policy apply completed. Installed=$($result.Installed), Failed=$($result.Failed), Skipped=$($result.Skipped)."
    }
    else {
        Write-Log "Required policy apply completed with failures. Installed=$($result.Installed), Failed=$($result.Failed), Skipped=$($result.Skipped)." 'WARN'
    }
}

function Invoke-ProcessRequestMode {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir

    if ([string]::IsNullOrWhiteSpace($AppAlias)) {
        throw 'AppAlias is required for ProcessRequest mode.'
    }

    $alias = $AppAlias.Trim().ToLowerInvariant()
    $app = Get-AppCatalogObjectByAlias -Alias $alias
    if (-not $app) {
        Write-Log "Worker rejected alias '$alias' because it is no longer in catalog policy. RequestedBy='$RequestedBy' Sid='$RequestedBySid'" 'WARN'
        return
    }

    if ($RequestAction -eq 'Install' -and -not (Test-UserInstallsAllowed)) {
        Write-Log "Worker rejected install for alias '$alias' because user installs are disabled. RequestedBy='$RequestedBy' Sid='$RequestedBySid'" 'WARN'
        return
    }

    if ($RequestAction -eq 'Uninstall' -and -not (Test-UserUninstallAllowed)) {
        Write-Log "Worker rejected uninstall for alias '$alias' because user uninstalls are disabled. RequestedBy='$RequestedBy' Sid='$RequestedBySid'" 'WARN'
        return
    }

    $wingetPath = Ensure-WingetAvailable
    if (-not $wingetPath) {
        Write-Log "Worker aborting $RequestAction for alias '$alias' because winget is unavailable. RequestedBy='$RequestedBy' Sid='$RequestedBySid'" 'ERROR'
        return
    }

    Write-Log "Worker starting action=$RequestAction alias='$alias' package='$($app.PackageId)' RequestedBy='$RequestedBy' Sid='$RequestedBySid'"

    $result = Invoke-WithWingetLock -ScriptBlock {
        if ($RequestAction -eq 'Uninstall') {
            $exitCode = Invoke-WingetUninstall -WingetPath $wingetPath -PackageId ([string]$app.PackageId)
        }
        else {
            $exitCode = Invoke-WingetInstall -WingetPath $wingetPath -PackageId ([string]$app.PackageId)
        }

        $snapshotUpdated = $false
        if ($exitCode -eq 0) {
            $snapshotUpdated = Update-InstalledPackagesSnapshot -WingetPath $wingetPath
        }

        [pscustomobject]@{
            ExitCode        = $exitCode
            SnapshotUpdated = [bool]$snapshotUpdated
        }
    }
    $result = @($result)[-1]

    if ($result.ExitCode -eq 0) {
        Write-Log "Worker completed action=$RequestAction alias='$alias' package='$($app.PackageId)' SnapshotUpdated=$($result.SnapshotUpdated) RequestedBy='$RequestedBy' Sid='$RequestedBySid'"
    }
    else {
        Write-Log "Worker failed action=$RequestAction alias='$alias' package='$($app.PackageId)' code=$($result.ExitCode) RequestedBy='$RequestedBy' Sid='$RequestedBySid'" 'ERROR'
    }
}

function Install-Service {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir

    Set-DirectoryAcl -Path $BaseDir -UsersCanModify:$false
    Set-DirectoryAcl -Path $LogDir -UsersCanModify:$false

    foreach ($legacyDirName in @('Requests','Processed','Failed')) {
        $legacyDirPath = Join-Path $BaseDir $legacyDirName
        if (Test-Path -LiteralPath $legacyDirPath) {
            Set-DirectoryAcl -Path $legacyDirPath -UsersCanModify:$false
        }
    }

    if (-not $PSCommandPath) {
        throw 'PSCommandPath is empty; cannot determine the source script path.'
    }

    Copy-Item -LiteralPath $PSCommandPath -Destination $LocalScriptPath -Force
    Set-FileAclAdminsOnly -Path $LocalScriptPath

    New-UserRequestTool
    New-CatalogGui
    New-CatalogLauncher
    New-Shortcut -ShortcutPath $DesktopShortcutPath
    New-Shortcut -ShortcutPath $StartMenuShortcutPath
    Register-OrUpdateTasks

    Write-Log 'Install/update completed successfully.'
}

# ----------------------------
# Entry point
# ----------------------------
try {
    switch ($Mode) {
        'Install'    { Install-Service }
        'Daemon'     { Start-CatalogDaemon }
        'UpgradeAll' { Invoke-UpgradeAllMode }
        'ApplyPolicy' { Invoke-ApplyPolicyMode }
        'ProcessRequest' { Invoke-ProcessRequestMode }
        default      { throw "Unsupported mode '$Mode'." }
    }
}
catch {
    try {
        Write-Log "Fatal error in mode '$Mode': $($_.Exception.Message)" 'ERROR'
    }
    catch {
    }
    throw
}
