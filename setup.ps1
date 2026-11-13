<#
SelfServiceWinget.ps1

Use as:
- Computer Startup GPO script (default mode = Install)
- Scheduled task target (Mode = ProcessRequests / UpgradeAll / ApplyPolicy / ProcessQueue / ProcessRequest)

Behavior:
User -> GUI / request helper -> request drop dir -> SYSTEM request worker -> winget install --scope machine

Created paths:
C:\ProgramData\__Softwarekatalog\
  SelfServiceWinget.ps1
  Request-App.ps1
  Software-Catalog.ps1
  Launch-Software-Catalog.vbs
  Installed-Packages.json
  Requests\
  Processed\
  Failed\
  Logs\service.log
#>

[CmdletBinding()]
param(
    [ValidateSet('Install','UpgradeAll','ApplyPolicy','ProcessQueue','ProcessRequest','ProcessRequests')]
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
$ScopeRepairPath        = Join-Path $BaseDir 'Scope-Repairs.json'
$QueueStatePath         = Join-Path $BaseDir 'Queue-State.json'
$QueueLockInfoPath      = Join-Path $BaseDir 'Queue-Lock.json'
$QueueRootDir           = Join-Path $BaseDir 'Queue'
$QueuePendingDir        = Join-Path $QueueRootDir 'Pending'
$QueueRunningDir        = Join-Path $QueueRootDir 'Running'
$QueueSucceededDir      = Join-Path $QueueRootDir 'Succeeded'
$QueueFailedDir         = Join-Path $QueueRootDir 'Failed'
$QueueCompletedRetention = 100
$RequestsDir            = Join-Path $BaseDir 'Requests'
$ProcessedRequestsDir   = Join-Path $BaseDir 'Processed'
$FailedRequestsDir      = Join-Path $BaseDir 'Failed'
$LogDir                 = Join-Path $BaseDir 'Logs'
$LogFile                = Join-Path $LogDir 'service.log'
$PolicyRoot             = 'HKLM:\Software\Policies\STL\Softwarekatalog'
$PolicyCatalogRoot      = Join-Path $PolicyRoot 'Catalog'
$PolicyRequiredRoot     = Join-Path $PolicyRoot 'Required'
$PolicyMaxEntries       = 500
$LegacyQueueTaskName    = 'Softwarekatalog - Winget Queue'
$DaemonTaskName         = 'Softwarekatalog - Daemon'
$RequestTaskName        = 'Softwarekatalog - Requests'
$QueueTaskName          = 'Softwarekatalog - Queue'
$UpgradeTaskName        = 'Softwarekatalog - Winget Upgrade'
$WingetSourceName       = 'winget'
$WingetMutexName        = 'Global\Softwarekatalog-Winget'
$QueueStateMutexName    = 'Global\Softwarekatalog-QueueState'
$PowerShellExe          = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$WScriptExe             = Join-Path $env:SystemRoot 'System32\wscript.exe'
$AppInstallerFamilyName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
$CommonDesktopDir       = [Environment]::GetFolderPath('CommonDesktopDirectory')
$CommonProgramsDir      = [Environment]::GetFolderPath('CommonPrograms')
$DesktopShortcutPath    = Join-Path $CommonDesktopDir "$CatalogDisplayName.lnk"
$StartMenuShortcutPath  = Join-Path $CommonProgramsDir "$CatalogDisplayName.lnk"
$script:QueueProgressThrottle = @{}
$script:SoftwarekatalogBuildCommit = $null
$script:ScopeRepairFailures = @()
$script:MsiInspectionFailures = @()

# <SoftwarekatalogModules>
# The distribution builder replaces this source-only loader with both modules.
foreach ($module in @('ArtCraft.Catalog.ps1', 'ArtCraft.Provider.ps1')) {
    $modulePath = Join-Path (Join-Path $PSScriptRoot 'modules') $module
    . ([scriptblock]::Create([IO.File]::ReadAllText($modulePath, [Text.Encoding]::UTF8)))
}
# </SoftwarekatalogModules>

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

function Get-SoftwarekatalogBuildCommit {
    if (-not [string]::IsNullOrWhiteSpace($script:SoftwarekatalogBuildCommit)) {
        return $script:SoftwarekatalogBuildCommit
    }

    $paths = @()
    if ($PSCommandPath) {
        $paths += $PSCommandPath
    }
    elseif ($MyInvocation.MyCommand.Path) {
        $paths += $MyInvocation.MyCommand.Path
    }
    elseif ($LocalScriptPath) {
        $paths += $LocalScriptPath
    }

    foreach ($path in @($paths | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) { continue }

        try {
            foreach ($line in @(Get-Content -LiteralPath $path -TotalCount 5 -Encoding UTF8 -ErrorAction Stop)) {
                $match = [regex]::Match([string]$line, '^#\s*Softwarekatalog build commit:\s*(.+?)\s*$')
                if ($match.Success) {
                    $script:SoftwarekatalogBuildCommit = $match.Groups[1].Value
                    return $script:SoftwarekatalogBuildCommit
                }
            }
        }
        catch {
        }
    }

    $script:SoftwarekatalogBuildCommit = 'unknown'
    return $script:SoftwarekatalogBuildCommit
}

function Clear-QueueLockOwnerInfo {
    try {
        if (Test-Path -LiteralPath $QueueLockInfoPath) {
            Remove-Item -LiteralPath $QueueLockInfoPath -Force -ErrorAction Stop
        }
    }
    catch {
    }
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

function Set-RequestDirectoryAcl {
    param([Parameter(Mandatory)][string]$Path)

    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $inheritOnly = [System.Security.AccessControl.PropagationFlags]::InheritOnly
    $noInheritance = [System.Security.AccessControl.InheritanceFlags]::None
    $noPropagation = [System.Security.AccessControl.PropagationFlags]::None

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)

    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $sidUsers = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $sidCreatorOwner = New-Object System.Security.Principal.SecurityIdentifier('S-1-3-0')

    $ruleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidSystem, 'FullControl', $inheritance, $noPropagation, 'Allow'
    )
    $ruleAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidAdmins, 'FullControl', $inheritance, $noPropagation, 'Allow'
    )
    $ruleUsers = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidUsers, 'ReadAndExecute, Write, Synchronize', $noInheritance, $noPropagation, 'Allow'
    )
    $ruleCreatorOwner = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidCreatorOwner, 'Modify', $inheritance, $inheritOnly, 'Allow'
    )

    $null = $acl.AddAccessRule($ruleSystem)
    $null = $acl.AddAccessRule($ruleAdmins)
    $null = $acl.AddAccessRule($ruleUsers)
    $null = $acl.AddAccessRule($ruleCreatorOwner)

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

function Get-PolicyCatalogObjects {
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

function Get-AppCatalogObjects {
    if (-not (Test-SoftwareCatalogPolicyEnabled)) { return @() }
    Merge-ArtCraftCatalog -PolicyApps @(Get-PolicyCatalogObjects)
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

function Ensure-QueueDirectories {
    foreach ($path in @($QueueRootDir, $QueuePendingDir, $QueueRunningDir, $QueueSucceededDir, $QueueFailedDir)) {
        Ensure-Directory -Path $path
    }
}

function New-QueueStateObject {
    [pscustomobject][ordered]@{
        Version = [int64](Get-Date).ToUniversalTime().Ticks
        UpdatedAt = (Get-Date).ToString('o')
        Current = $null
        Queue = @()
    }
}

function Backup-CorruptQueueState {
    param([string]$Reason)

    if (-not (Test-Path -LiteralPath $QueueStatePath)) { return }

    try {
        $backupPath = Join-Path $BaseDir ("Queue-State.corrupt-{0}.json" -f (Get-Date -Format 'yyyyMMddHHmmss'))
        Copy-Item -LiteralPath $QueueStatePath -Destination $backupPath -Force -ErrorAction Stop
        Write-Log "Backed up corrupt queue state to '$backupPath': $Reason" 'WARN'
    }
    catch {
        Write-Log "Could not back up corrupt queue state: $($_.Exception.Message)" 'WARN'
    }
}

function Get-QueueObjectValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }

    try {
        $property = $Object.PSObject.Properties[$Name]
        if (-not $property) { return $Default }
        if ($null -eq $property.Value) { return $Default }
        return $property.Value
    }
    catch {
        return $Default
    }
}

function ConvertTo-QueueBool {
    param(
        $Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
    if ($text -in @('0','false','no','nein')) { return $false }
    if ($text -in @('1','true','yes','ja')) { return $true }
    return [bool]$Value
}

function ConvertTo-QueueNullableInt {
    param($Value)

    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    try {
        $number = [int]$text
        if ($number -lt 0) { return 0 }
        if ($number -gt 100) { return 100 }
        return $number
    }
    catch {
        return $null
    }
}

function ConvertTo-QueueTimestampString {
    param(
        $Value,
        [string]$Default
    )

    if ($null -eq $Value) { return $Default }
    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $Default }

    try {
        return ([DateTime]::Parse($text)).ToString('o')
    }
    catch {
        return $Default
    }
}

function ConvertTo-QueueItemRecord {
    param(
        [Parameter(Mandatory)]$Item,
        [ValidateSet('Queued','Running','Succeeded','Failed')][string]$DefaultState = 'Queued'
    )

    $now = (Get-Date).ToString('o')
    $id = [string](Get-QueueObjectValue -Object $Item -Name 'Id' -Default '')
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [Guid]::NewGuid().ToString('N') }

    $action = [string](Get-QueueObjectValue -Object $Item -Name 'Action' -Default '')
    $state = [string](Get-QueueObjectValue -Object $Item -Name 'State' -Default $DefaultState)
    if ($state -notin @('Queued','Running','Succeeded','Failed')) { $state = $DefaultState }

    $createdAt = ConvertTo-QueueTimestampString -Value (Get-QueueObjectValue -Object $Item -Name 'CreatedAt' -Default $null) -Default $now
    $startedAt = ConvertTo-QueueTimestampString -Value (Get-QueueObjectValue -Object $Item -Name 'StartedAt' -Default $null) -Default $null
    $finishedAt = ConvertTo-QueueTimestampString -Value (Get-QueueObjectValue -Object $Item -Name 'FinishedAt' -Default $null) -Default $null

    [pscustomobject][ordered]@{
        Id = $id
        Action = $action
        Alias = [string](Get-QueueObjectValue -Object $Item -Name 'Alias' -Default '')
        PackageId = [string](Get-QueueObjectValue -Object $Item -Name 'PackageId' -Default '')
        DisplayName = [string](Get-QueueObjectValue -Object $Item -Name 'DisplayName' -Default '')
        Source = [string](Get-QueueObjectValue -Object $Item -Name 'Source' -Default 'User')
        Required = ConvertTo-QueueBool -Value (Get-QueueObjectValue -Object $Item -Name 'Required' -Default $false)
        RequestedBy = [string](Get-QueueObjectValue -Object $Item -Name 'RequestedBy' -Default '')
        RequestedBySid = [string](Get-QueueObjectValue -Object $Item -Name 'RequestedBySid' -Default '')
        State = $state
        Stage = [string](Get-QueueObjectValue -Object $Item -Name 'Stage' -Default $state)
        StageText = [string](Get-QueueObjectValue -Object $Item -Name 'StageText' -Default '')
        ProgressPercent = ConvertTo-QueueNullableInt -Value (Get-QueueObjectValue -Object $Item -Name 'ProgressPercent' -Default $null)
        IsIndeterminate = ConvertTo-QueueBool -Value (Get-QueueObjectValue -Object $Item -Name 'IsIndeterminate' -Default $false)
        CreatedAt = $createdAt
        StartedAt = $startedAt
        FinishedAt = $finishedAt
        ExitCode = Get-QueueObjectValue -Object $Item -Name 'ExitCode' -Default $null
        Message = [string](Get-QueueObjectValue -Object $Item -Name 'Message' -Default '')
    }
}

function ConvertTo-SafeQueueFileName {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        $Id = [Guid]::NewGuid().ToString('N')
    }

    $safe = [regex]::Replace($Id, '[^A-Za-z0-9._-]', '_')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        $safe = [Guid]::NewGuid().ToString('N')
    }

    return $safe
}

function Get-QueueItemPath {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Id
    )

    Join-Path $Directory ("{0}.json" -f (ConvertTo-SafeQueueFileName -Id $Id))
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [int]$Depth = 8
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory) { Ensure-Directory -Path $directory }

    $tempPath = Join-Path $directory ("{0}.{1}.tmp" -f (Split-Path -Path $Path -Leaf), [Guid]::NewGuid().ToString('N'))
    try {
        $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-QueueItemFile {
    param(
        [Parameter(Mandatory)]$Item,
        [string]$Directory,
        [string]$Path,
        [ValidateSet('Queued','Running','Succeeded','Failed')][string]$DefaultState = 'Queued'
    )

    $record = ConvertTo-QueueItemRecord -Item $Item -DefaultState $DefaultState
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ([string]::IsNullOrWhiteSpace($Directory)) { throw 'Directory or Path is required when writing a queue item.' }
        $Path = Get-QueueItemPath -Directory $Directory -Id $record.Id
    }

    Write-JsonFileAtomic -Path $Path -Value $record -Depth 8
    return $record
}

function Get-QueueDefaultStateForDirectory {
    param([Parameter(Mandatory)][string]$Directory)

    if ([string]::Equals($Directory, $QueueRunningDir, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Running' }
    if ([string]::Equals($Directory, $QueueSucceededDir, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Succeeded' }
    if ([string]::Equals($Directory, $QueueFailedDir, [System.StringComparison]::OrdinalIgnoreCase)) { return 'Failed' }
    return 'Queued'
}

function Read-QueueItemFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Queued','Running','Succeeded','Failed')][string]$DefaultState = 'Queued'
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Queue item file is empty.' }
        # Validate the root before ConvertFrom-Json can unwrap singleton arrays.
        if (-not $raw.TrimStart().StartsWith('{')) { throw 'Queue item JSON root is not an object.' }
        $item = $raw | ConvertFrom-Json
        if ($item -is [System.Array] -or $item -isnot [pscustomobject]) { throw 'Queue item JSON root is not an object.' }
        return (ConvertTo-QueueItemRecord -Item $item -DefaultState $DefaultState)
    }
    catch {
        Write-Log "Could not read queue item file '$Path': $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Get-QueueItemFiles {
    param([Parameter(Mandatory)][string]$Directory)

    if (-not (Test-Path -LiteralPath $Directory)) { return @() }
    return @(Get-ChildItem -LiteralPath $Directory -Filter '*.json' -File -ErrorAction SilentlyContinue)
}

function Get-QueueItemsInDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [ValidateSet('Queued','Running','Succeeded','Failed')][string]$DefaultState = 'Queued'
    )

    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in @(Get-QueueItemFiles -Directory $Directory)) {
        $item = Read-QueueItemFile -Path $file.FullName -DefaultState $DefaultState
        if ($item) { [void]$items.Add($item) }
    }
    return @($items.ToArray())
}

function Find-QueueItemFile {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string[]]$Directories
    )

    foreach ($directory in $Directories) {
        $path = Get-QueueItemPath -Directory $directory -Id $Id
        if (Test-Path -LiteralPath $path) {
            $item = Read-QueueItemFile -Path $path -DefaultState (Get-QueueDefaultStateForDirectory -Directory $directory)
            return [pscustomobject]@{ Path = $path; Directory = $directory; Item = $item }
        }
    }

    foreach ($directory in $Directories) {
        foreach ($file in Get-QueueItemFiles -Directory $directory) {
            $item = Read-QueueItemFile -Path $file.FullName -DefaultState (Get-QueueDefaultStateForDirectory -Directory $directory)
            if ($item -and [string]::Equals([string]$item.Id, $Id, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Path = $file.FullName; Directory = $directory; Item = $item }
            }
        }
    }

    return $null
}

function Get-QueueItemSortTimestamp {
    param($Item)

    foreach ($propertyName in @('FinishedAt','StartedAt','CreatedAt')) {
        $value = Get-QueueObjectValue -Object $Item -Name $propertyName -Default $null
        if ($value) {
            try { return [DateTime]::Parse([string]$value) }
            catch { }
        }
    }

    return [DateTime]::MinValue
}

function ConvertTo-QueueCurrentRecord {
    param($Item)

    if (-not $Item) { return $null }
    [pscustomobject][ordered]@{
        Id = $Item.Id
        Action = $Item.Action
        Alias = $Item.Alias
        DisplayName = $Item.DisplayName
        Stage = $Item.Stage
        StageText = $Item.StageText
        ProgressPercent = $Item.ProgressPercent
        IsIndeterminate = $Item.IsIndeterminate
    }
}

function New-QueueStateSnapshot {
    Ensure-QueueDirectories

    $running = @(Get-QueueItemsInDirectory -Directory $QueueRunningDir -DefaultState Running | Sort-Object { Get-QueueItemSortTimestamp -Item $_ })
    $pending = @(Get-QueueItemsInDirectory -Directory $QueuePendingDir -DefaultState Queued | Sort-Object { Get-QueueItemSortTimestamp -Item $_ })
    $completed = @(
        @(Get-QueueItemsInDirectory -Directory $QueueSucceededDir -DefaultState Succeeded) +
        @(Get-QueueItemsInDirectory -Directory $QueueFailedDir -DefaultState Failed)
    ) | Sort-Object { Get-QueueItemSortTimestamp -Item $_ } -Descending | Select-Object -First $QueueCompletedRetention

    $snapshot = New-QueueStateObject
    if ($running.Count -gt 0) {
        $snapshot.Current = ConvertTo-QueueCurrentRecord -Item $running[0]
    }

    $snapshot.Queue = @(
        @($running) +
        @($pending) +
        @($completed | Sort-Object { Get-QueueItemSortTimestamp -Item $_ })
    )
    return $snapshot
}

function Write-QueueState {
    param([Parameter(Mandatory)]$State)

    Write-JsonFileAtomic -Path $QueueStatePath -Value $State -Depth 8
}

function Publish-QueueStateSnapshot {
    try {
        Write-QueueState -State (New-QueueStateSnapshot)
    }
    catch {
        Write-Log "Could not publish queue state snapshot: $($_.Exception.Message)" 'WARN'
    }
}

function Get-QueueStateSnapshot {
    param([int]$TimeoutSeconds = 30)

    return New-QueueStateSnapshot
}

function Test-QueueHasPendingWork {
    Ensure-QueueDirectories
    return (@(Get-QueueItemFiles -Directory $QueuePendingDir).Count -gt 0)
}

function Limit-QueueHistory {
    foreach ($directory in @($QueueSucceededDir, $QueueFailedDir)) {
        if (-not (Test-Path -LiteralPath $directory)) { continue }
        $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
        foreach ($file in @($files | Select-Object -Skip $QueueCompletedRetention)) {
            try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop }
            catch { Write-Log "Could not remove old queue history file '$($file.FullName)': $($_.Exception.Message)" 'WARN' }
        }
    }
}

function Move-CorruptQueueFileToFailed {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Message = 'Queue item could not be read.'
    )

    try {
        Ensure-QueueDirectories
        $destination = Join-Path $QueueFailedDir ("corrupt-{0}.json" -f [Guid]::NewGuid().ToString('N'))
        Move-Item -LiteralPath $Path -Destination $destination -Force -ErrorAction Stop
        Set-Content -LiteralPath ($destination + '.error.txt') -Value $Message -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log "Could not move corrupt queue item '$Path' to failed queue: $($_.Exception.Message)" 'WARN'
    }
}

function Migrate-LegacyQueueState {
    if (Test-Path -LiteralPath $QueueRootDir) { return }
    if (-not (Test-Path -LiteralPath $QueueStatePath)) { return }

    $legacyPath = Join-Path $BaseDir ("Queue-State.legacy-{0}.json" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    try {
        $raw = Get-Content -LiteralPath $QueueStatePath -Raw -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $QueueStatePath -Destination $legacyPath -Force -ErrorAction Stop
        Write-Log "Moved legacy queue state to '$legacyPath'."

        if ([string]::IsNullOrWhiteSpace($raw)) {
            Ensure-QueueDirectories
            Publish-QueueStateSnapshot
            return
        }

        if (-not $raw.TrimStart().StartsWith('{')) { throw 'Legacy queue state root is not a JSON object.' }
        $legacy = $raw | ConvertFrom-Json
        if ($legacy -is [System.Array] -or $legacy -isnot [pscustomobject]) {
            Write-Log "Legacy queue state '$legacyPath' was not a JSON object; starting with an empty queue." 'WARN'
            Ensure-QueueDirectories
            Publish-QueueStateSnapshot
            return
        }

        Ensure-QueueDirectories
        $migrated = 0
        foreach ($item in @($legacy.Queue)) {
            if (-not $item) { continue }
            $state = [string](Get-QueueObjectValue -Object $item -Name 'State' -Default '')
            if ($state -notin @('Queued','Running')) { continue }

            $record = ConvertTo-QueueItemRecord -Item $item -DefaultState Queued
            $record.State = 'Queued'
            $record.Stage = 'Queued'
            $record.StageText = 'Nach Queue-Migration erneut eingereiht'
            $record.ProgressPercent = $null
            $record.IsIndeterminate = $false
            $record.StartedAt = $null
            $record.FinishedAt = $null
            $record.ExitCode = $null
            $record.Message = ''
            $result = Add-QueueItem -Item $record
            if ($result -and $result.Added) { $migrated++ }
        }

        Write-Log "Migrated active legacy queue items count=$migrated."
        Publish-QueueStateSnapshot
    }
    catch {
        Write-Log "Could not migrate legacy queue state: $($_.Exception.Message)" 'WARN'
        Ensure-QueueDirectories
        Publish-QueueStateSnapshot
    }
}

function New-QueueItem {
    param(
        [Parameter(Mandatory)][ValidateSet('Install','Uninstall','UpgradeAll')][string]$Action,
        [string]$Alias,
        [string]$PackageId,
        [string]$DisplayName,
        [ValidateSet('User','Required','System')][string]$Source = 'User',
        [bool]$Required = $false,
        [string]$RequestedBy,
        [string]$RequestedBySid
    )

    [pscustomobject][ordered]@{
        Id = [Guid]::NewGuid().ToString('N')
        Action = $Action
        Alias = $Alias
        PackageId = $PackageId
        DisplayName = $DisplayName
        Source = $Source
        Required = [bool]$Required
        RequestedBy = $RequestedBy
        RequestedBySid = $RequestedBySid
        State = 'Queued'
        Stage = 'Queued'
        StageText = 'In Warteschlange'
        ProgressPercent = $null
        IsIndeterminate = $false
        CreatedAt = (Get-Date).ToString('o')
        StartedAt = $null
        FinishedAt = $null
        ExitCode = $null
        Message = $null
    }
}

function Get-ProgressPercentFromLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $match = [regex]::Match($Line, '(?<!\d)(100|[1-9]?\d)(?:[\.,]\d+)?\s*%')
    if ($match.Success) {
        $value = [int]$match.Groups[1].Value
        if ($value -lt 0) { return 0 }
        if ($value -gt 100) { return 100 }
        return $value
    }

    $transferMatch = [regex]::Match(
        $Line,
        '(?<current>\d+(?:[\.,]\d+)?)\s*(?<currentUnit>TB|GB|MB|KB|B)\s*/\s*(?<total>\d+(?:[\.,]\d+)?)\s*(?<totalUnit>TB|GB|MB|KB|B)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if (-not $transferMatch.Success) { return $null }

    try {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $current = [double]::Parse($transferMatch.Groups['current'].Value.Replace(',', '.'), $culture)
        $total = [double]::Parse($transferMatch.Groups['total'].Value.Replace(',', '.'), $culture)

        switch ($transferMatch.Groups['currentUnit'].Value.ToUpperInvariant()) {
            'TB' { $current *= 1099511627776 }
            'GB' { $current *= 1073741824 }
            'MB' { $current *= 1048576 }
            'KB' { $current *= 1024 }
        }
        switch ($transferMatch.Groups['totalUnit'].Value.ToUpperInvariant()) {
            'TB' { $total *= 1099511627776 }
            'GB' { $total *= 1073741824 }
            'MB' { $total *= 1048576 }
            'KB' { $total *= 1024 }
        }

        if ($total -le 0) { return $null }
        $value = [int][Math]::Round(($current / $total) * 100)
        if ($value -lt 0) { return 0 }
        if ($value -gt 100) { return 100 }
        return $value
    }
    catch {
        return $null
    }
}

function ConvertTo-WingetOutputLine {
    param([string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }

    $text = [regex]::Replace($Line, '\x1B\[[0-?]*[ -/]*[@-~]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $transferMatch = [regex]::Match(
        $text,
        '\d+(?:[\.,]\d+)?\s*(?:TB|GB|MB|KB|B)\s*/\s*\d+(?:[\.,]\d+)?\s*(?:TB|GB|MB|KB|B)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($transferMatch.Success) {
        return $transferMatch.Value
    }

    # Older winget versions emit spinner and block-bar frames even when stdout is
    # redirected. Ignore lines that contain no useful ASCII text; this also drops
    # progress glyphs decoded through an OEM code page (for example, "Ôûê").
    if ($text -notmatch '[A-Za-z0-9]') { return $null }
    return $text
}

function Set-WingetOutputEncoding {
    try {
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    catch {
        # Some non-interactive hosts do not expose a mutable console encoding.
    }
}

function Update-QueueItemProgress {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Stage = 'Running',
        [string]$StageText = 'Aktion läuft...',
        [Nullable[int]]$ProgressPercent,
        [bool]$IsIndeterminate = $true
    )

    if (-not $script:QueueProgressThrottle) { $script:QueueProgressThrottle = @{} }
    $now = Get-Date
    $last = $script:QueueProgressThrottle[$Id]
    if ($last) {
        $sameStage = [string]::Equals([string]$last.Stage, [string]$Stage, [System.StringComparison]::Ordinal)
        $sameText = [string]::Equals([string]$last.StageText, [string]$StageText, [System.StringComparison]::Ordinal)
        $samePercent = ([string]$last.ProgressPercent) -eq ([string]$ProgressPercent)
        $sameIndeterminate = ([bool]$last.IsIndeterminate) -eq ([bool]$IsIndeterminate)
        if ($sameStage -and $sameText -and $samePercent -and $sameIndeterminate -and (($now - $last.UpdatedAt).TotalSeconds -lt 5)) {
            return
        }
    }

    $script:QueueProgressThrottle[$Id] = [pscustomobject]@{
        Stage = $Stage
        StageText = $StageText
        ProgressPercent = $ProgressPercent
        IsIndeterminate = $IsIndeterminate
        UpdatedAt = $now
    }

    $found = Find-QueueItemFile -Id $Id -Directories @($QueueRunningDir, $QueuePendingDir)
    if (-not $found -or -not $found.Item) { return }

    $item = $found.Item
    $item.Stage = $Stage
    $item.StageText = $StageText
    $item.ProgressPercent = $ProgressPercent
    $item.IsIndeterminate = $IsIndeterminate
    [void](Write-QueueItemFile -Item $item -Path $found.Path -DefaultState (Get-QueueDefaultStateForDirectory -Directory $found.Directory))
    Publish-QueueStateSnapshot
}

function Get-RequiredAliasSet {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $aliases = @(Get-RequiredAliases)
    if ($aliases.Count -eq 0) { return ,$set }
    foreach ($alias in @(Expand-RequiredCatalogAliases -Aliases $aliases -Catalog @(Get-AppCatalogObjects))) {
        if (-not [string]::IsNullOrWhiteSpace($alias)) {
            [void]$set.Add([string]$alias)
        }
    }
    return ,$set
}

function Add-QueueItem {
    param(
        [Parameter(Mandatory)]$Item,
        [int]$TimeoutSeconds = 30
    )

    Ensure-QueueDirectories
    $record = ConvertTo-QueueItemRecord -Item $Item -DefaultState Queued
    $record.State = 'Queued'
    if ([string]::IsNullOrWhiteSpace($record.Stage)) { $record.Stage = 'Queued' }
    if ([string]::IsNullOrWhiteSpace($record.StageText)) { $record.StageText = 'In Warteschlange' }
    $record.ProgressPercent = $null
    $record.IsIndeterminate = $false
    $record.StartedAt = $null
    $record.FinishedAt = $null
    $record.ExitCode = $null
    $record.Message = ''

    foreach ($existing in @(
        @(Get-QueueItemsInDirectory -Directory $QueuePendingDir -DefaultState Queued) +
        @(Get-QueueItemsInDirectory -Directory $QueueRunningDir -DefaultState Running)
    )) {
        if (-not $existing) { continue }
        if ($existing.Action -eq $record.Action -and [string]::Equals([string]$existing.Alias, [string]$record.Alias, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Added = $false; Item = $existing }
        }
    }

    $path = Get-QueueItemPath -Directory $QueuePendingDir -Id $record.Id
    if (Test-Path -LiteralPath $path) {
        $record.Id = [Guid]::NewGuid().ToString('N')
        $path = Get-QueueItemPath -Directory $QueuePendingDir -Id $record.Id
    }

    $written = Write-QueueItemFile -Item $record -Path $path -DefaultState Queued
    Publish-QueueStateSnapshot
    return [pscustomobject]@{ Added = $true; Item = $written }
}

function Add-SoftwareRequestToQueue {
    param(
        [Parameter(Mandatory)][ValidateSet('Install','Uninstall')][string]$Action,
        [Parameter(Mandatory)][string]$Alias,
        [string]$RequestedBy,
        [string]$RequestedBySid,
        [ValidateSet('User','Required')][string]$Source = 'User',
        [int]$TimeoutSeconds = 30
    )

    $normalizedAlias = $Alias.Trim().ToLowerInvariant()
    $app = Get-AppCatalogObjectByAlias -Alias $normalizedAlias
    if (-not $app) {
        throw "Alias '$normalizedAlias' is not in the allowlist."
    }

    $requiredSet = Get-RequiredAliasSet
    $isRequired = $requiredSet.Contains($normalizedAlias)
    if ($Action -eq 'Uninstall' -and $isRequired) {
        throw 'Pflichtsoftware kann nicht zur Deinstallation angefragt werden.'
    }

    $item = New-QueueItem `
        -Action $Action `
        -Alias $normalizedAlias `
        -PackageId ([string]$app.PackageId) `
        -DisplayName ([string]$app.DisplayName) `
        -Source $Source `
        -Required:$isRequired `
        -RequestedBy $RequestedBy `
        -RequestedBySid $RequestedBySid

    return Add-QueueItem -Item $item -TimeoutSeconds $TimeoutSeconds
}

function Ensure-RequiredSoftwareQueued {
    param([int]$TimeoutSeconds = 30)

    $addedCount = 0
    if (-not (Test-SoftwareCatalogPolicyEnabled)) { return 0 }
    if (-not (Test-RequiredEnforcementEnabled)) { return 0 }

    $installedSet = Get-InstalledPackageIdSet
    foreach ($alias in @(Get-RequiredAliases)) {
        $app = Get-AppCatalogObjectByAlias -Alias $alias
        if (-not $app) {
            Write-Log "Required alias '$alias' is not present in catalog policy; skipping." 'WARN'
            continue
        }

        if ($installedSet.Contains([string]$app.PackageId)) {
            continue
        }

        $result = Add-SoftwareRequestToQueue -Action Install -Alias $alias -RequestedBy 'Policy' -RequestedBySid 'Policy' -Source Required -TimeoutSeconds $TimeoutSeconds
        if ($result -and $result.Added) {
            $addedCount++
            Write-Log "Queued required software alias '$alias' package '$($app.PackageId)'."
        }
    }

    return $addedCount
}

function Invoke-WithWingetLock {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 7200
    )

    $mutex = New-Object System.Threading.Mutex($false, $WingetMutexName)
    $hasLock = $false

    try {
        try {
            $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
            Write-Log "Recovered abandoned winget lock '$WingetMutexName'." 'WARN'
        }

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
        try {
            $hasLock = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
            Write-Log "Recovered abandoned winget lock '$WingetMutexName' while checking availability." 'WARN'
        }

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
        [Parameter(Mandatory)][ValidateSet('ApplyPolicy','ProcessRequest','ProcessRequests','ProcessQueue')][string]$WorkerMode,
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

function Start-QueueWorker {
    try {
        $task = Get-ScheduledTask -TaskName $QueueTaskName -ErrorAction SilentlyContinue
        if ($task) {
            if ([string]$task.State -eq 'Running') {
                Write-Log "Scheduled queue task '$QueueTaskName' is already running."
                return $true
            }

            Start-ScheduledTask -TaskName $QueueTaskName -ErrorAction Stop
            Write-Log "Started scheduled queue task '$QueueTaskName'."
            return $true
        }
    }
    catch {
        Write-Log "Could not start scheduled queue task '$QueueTaskName': $($_.Exception.Message)" 'WARN'
    }

    try {
        Start-SoftwarekatalogWorker -WorkerMode ProcessQueue
        Write-Log 'Started queue worker process fallback.' 'WARN'
        return $true
    }
    catch {
        Write-Log "Could not start queue worker process fallback: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Start-QueueWorkerIfAvailable {
    return (Start-QueueWorker)
}

function Get-NativeWindowsArchitecture {
    try {
        if (-not ('Softwarekatalog.NativeArchitecture' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Softwarekatalog {
    public static class NativeArchitecture {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
        public static ushort GetNativeMachine() {
            ushort processMachine, nativeMachine;
            if (!IsWow64Process2(new IntPtr(-1), out processMachine, out nativeMachine))
                throw new InvalidOperationException("Cannot determine native Windows architecture.");
            return nativeMachine;
        }
    }
}
'@
        }
        switch ([Softwarekatalog.NativeArchitecture]::GetNativeMachine()) {
            0xAA64 { return 'arm64' }
            0x8664 { return 'x64' }
            0x014c { return 'x86' }
        }
    }
    catch { }
    # Compatibility fallback for older Windows. W6432 describes the host OS,
    # unlike PROCESSOR_ARCHITECTURE in an emulated x86/x64 process on ARM64.
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture) { return $architecture.ToLowerInvariant().Replace('amd64', 'x64') }
}

function Select-WingetPath {
    param([string[]]$Candidates, [string]$NativeArchitecture)

    $preference = switch ($NativeArchitecture) {
        'arm64' { @('arm64', 'neutral', 'unknown', 'x64', 'x86') }
        'x64' { @('x64', 'neutral', 'unknown', 'x86') }
        'x86' { @('x86', 'neutral', 'unknown') }
        default { @('unknown', 'neutral', 'arm64', 'x64', 'x86') }
    }
    $ranked = @()
    $index = 0
    foreach ($candidate in @($Candidates | Select-Object -Unique)) {
        $architecture = 'unknown'
        $version = [version]'0.0.0.0'
        if ($candidate -match '(?i)(?:^|[\\/])Microsoft\.DesktopAppInstaller_(?<Version>\d+(?:\.\d+){3})_(?<Architecture>arm64|x64|x86|arm|neutral)_') {
            $architecture = $Matches.Architecture.ToLowerInvariant()
            $version = [version]$Matches.Version
        }
        $rank = [array]::IndexOf($preference, $architecture)
        if ($rank -ge 0) {
            $ranked += [pscustomobject]@{ Path = $candidate; Rank = $rank; Version = $version; Index = $index }
        }
        $index++
    }
    $selected = $ranked | Sort-Object Rank, @{ Expression = { $_.Version }; Descending = $true }, Index | Select-Object -First 1
    if ($selected) { return $selected.Path }
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

    $nativeProgramFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $windowsAppsRoot = Join-Path $nativeProgramFiles 'WindowsApps'
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

    return (Select-WingetPath -Candidates $candidates -NativeArchitecture (Get-NativeWindowsArchitecture))
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

function Get-ArtCraftClientFunctionText {
    # Render the actual shared functions, not another hand-maintained product list.
    $names = @('Get-ArtCraftDefinitions', 'Test-ArtCraftEnabled', 'Write-CatalogPolicyWarning',
        'Merge-ArtCraftCatalog', 'Expand-RequiredCatalogAliases', 'Test-SoftwareCatalogPolicyEnabled', 'Get-AppCatalogObjects')
    return (($names | ForEach-Object {
        "function $_ {`n$((Get-Command $_ -CommandType Function).ScriptBlock.ToString())`n}"
    }) -join "`n`n")
}

function Get-BundledSoftwarekatalogSource {
    param([Parameter(Mandatory)][string]$Path)
    $source = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $pattern = '(?ms)^# <SoftwarekatalogModules>\r?\n.*?^# </SoftwarekatalogModules>\r?\n'
    $match = [regex]::Match($source, $pattern)
    if (-not $match.Success) { return $source } # already bundled deployment
    $root = Split-Path $Path -Parent
    $modules = foreach ($name in @('ArtCraft.Catalog.ps1', 'ArtCraft.Provider.ps1')) {
        [IO.File]::ReadAllText((Join-Path (Join-Path $root 'modules') $name), [Text.Encoding]::UTF8).TrimEnd([char[]]"`r`n")
    }
    return $source.Substring(0, $match.Index) + ($modules -join "`n`n") + "`n" + $source.Substring($match.Index + $match.Length)
}

function New-UserRequestTool {
    $requestsLiteral = $RequestsDir.Replace("'", "''")
    $policyRootLiteral = $PolicyRoot.Replace("'", "''")
    $policyCatalogLiteral = $PolicyCatalogRoot.Replace("'", "''")
    $policyMaxEntriesLiteral = $PolicyMaxEntries
    $artCraftFunctions = Get-ArtCraftClientFunctionText

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

`$RequestsDir = '$requestsLiteral'
`$PolicyRoot = '$policyRootLiteral'
`$PolicyCatalogRoot = '$policyCatalogLiteral'
`$PolicyMaxEntries = $policyMaxEntriesLiteral

$artCraftFunctions

function Get-PolicyDword {
    param([Parameter(Mandatory=`$true)][string]`$Name, [int]`$Default = 0)

    try {
        if (-not (Test-Path -LiteralPath `$PolicyRoot)) { return `$Default }
        `$props = Get-ItemProperty -LiteralPath `$PolicyRoot -ErrorAction Stop
        `$property = `$props.PSObject.Properties[`$Name]
        if (-not `$property) { return `$Default }
        return [int]`$property.Value
    }
    catch {
        return `$Default
    }
}

function Test-SoftwareCatalogPolicyEnabled {
    (Get-PolicyDword -Name 'Enabled' -Default 0) -eq 1
}

function Get-PolicyStringValues {
    param([Parameter(Mandatory=`$true)][string]`$Path)

    if (-not (Test-Path -LiteralPath `$Path)) { return @() }

    try {
        `$item = Get-Item -LiteralPath `$Path -ErrorAction Stop
        `$names = @(`$item.GetValueNames()) |
            Where-Object { `$_ -and `$_ -notmatch '^\*' } |
            Sort-Object |
            Select-Object -First `$PolicyMaxEntries

        foreach (`$name in `$names) {
            `$value = [string]`$item.GetValue(`$name, '')
            if (-not [string]::IsNullOrWhiteSpace(`$value)) {
                [pscustomobject]@{ Name = [string]`$name; Value = `$value.Trim() }
            }
        }
    }
    catch {
        return @()
    }
}

function Get-PolicyCatalogObjects {
    if (-not (Test-SoftwareCatalogPolicyEnabled)) { return @() }

    foreach (`$row in Get-PolicyStringValues -Path `$PolicyCatalogRoot) {
        `$alias = ([string]`$row.Name).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace(`$alias)) { continue }

        `$parts = ([string]`$row.Value) -split '\|', 3
        if (@(`$parts).Count -lt 2) { continue }

        `$packageId = ([string]`$parts[0]).Trim()
        `$displayName = ([string]`$parts[1]).Trim()
        `$description = ''
        if (@(`$parts).Count -ge 3) { `$description = ([string]`$parts[2]).Trim() }
        if ([string]::IsNullOrWhiteSpace(`$packageId)) { continue }
        if ([string]::IsNullOrWhiteSpace(`$displayName)) { `$displayName = `$alias }

        [pscustomobject]@{
            Alias = `$alias
            DisplayName = `$displayName
            Description = `$description
            PackageId = `$packageId
        }
    }
}

function New-CatalogRequestFile {
    param(
        [Parameter(Mandatory=`$true)][ValidateSet('Install','Uninstall','RefreshStatus')][string]`$Command,
        [string]`$Alias
    )

    if (-not (Test-Path -LiteralPath `$RequestsDir)) {
        throw "Request directory '`$RequestsDir' does not exist. Run setup first."
    }

    `$id = [Guid]::NewGuid().ToString('N')
    `$payload = [ordered]@{
        Id = `$id
        Command = `$Command
        AppAlias = `$Alias
        CreatedAt = (Get-Date).ToString('o')
    }

    `$tempPath = Join-Path `$RequestsDir ("`$id.tmp")
    `$finalPath = Join-Path `$RequestsDir ("`$id.json")
    `$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath `$tempPath -Encoding UTF8
    Move-Item -LiteralPath `$tempPath -Destination `$finalPath -Force
}

if (`$Uninstall) {
    `$Action = 'Uninstall'
}

if (`$List) {
    Write-Host 'Freigegebene Anwendungen:'
    @(Get-AppCatalogObjects) | Where-Object Visible | Sort-Object DisplayName | ForEach-Object {
        Write-Host (" - {0} [{1}] : {2}" -f `$_.DisplayName, `$_.Alias, `$_.Description)
    }
    exit 0
}

if (-not `$AppAlias) {
    throw 'Sie müssen -AppAlias angeben oder -List verwenden.'
}

`$alias = `$AppAlias.Trim().ToLowerInvariant()
`$app = @(Get-AppCatalogObjects) | Where-Object { [string]::Equals([string]`$_.Alias, `$alias, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
if (-not `$app) {
    throw "Alias '`$alias' ist nicht freigegeben."
}

New-CatalogRequestFile -Command `$Action -Alias `$alias

if (`$Action -eq 'Uninstall') {
    Write-Host "Deinstallation für '`$alias' angefordert."
}
else {
    Write-Host "Installation für '`$alias' angefordert."
}
"@

    Write-TextFile -Path $RequestToolPath -Content $content -Encoding Utf8Bom
    Set-FileAclAdminsOnly -Path $RequestToolPath
}

function New-CatalogGui {
    $titleLiteral     = $CatalogDisplayName.Replace("'", "''")
    $logLiteral       = $LogFile.Replace("'", "''")
    $installedLiteral = $InstalledPackagesPath.Replace("'", "''")
    $queueStateLiteral = $QueueStatePath.Replace("'", "''")
    $requestsLiteral = $RequestsDir.Replace("'", "''")
    $policyRootLiteral = $PolicyRoot.Replace("'", "''")
    $policyCatalogLiteral = $PolicyCatalogRoot.Replace("'", "''")
    $policyRequiredLiteral = $PolicyRequiredRoot.Replace("'", "''")
    $policyMaxEntriesLiteral = $PolicyMaxEntries
    $artCraftFunctions = Get-ArtCraftClientFunctionText

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

`$CatalogTitle = '$titleLiteral'
`$LogFile = '$logLiteral'
`$InstalledPackagesPath = '$installedLiteral'
`$QueueStatePath = '$queueStateLiteral'
`$RequestsDir = '$requestsLiteral'
`$PolicyRoot = '$policyRootLiteral'
`$PolicyCatalogRoot = '$policyCatalogLiteral'
`$PolicyRequiredRoot = '$policyRequiredLiteral'
`$PolicyMaxEntries = $policyMaxEntriesLiteral
$artCraftFunctions
`$AllowUserInstalls = `$true
`$AllowUserUninstall = `$true
`$RequiredAliasSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
`$LastStateVersion = -1
`$LastQueue = @()
`$LastCurrent = `$null
`$LastInstalledIds = @()
`$PendingRequests = @{}

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

function Invoke-CatalogLocal {
    param(
        [Parameter(Mandatory=`$true)][string]`$Command,
        [string]`$Alias
    )

    `$commandName = `$Command.Trim().ToLowerInvariant()
    switch (`$commandName) {
        { `$_ -in @('getcatalog','getstate') } {
            `$queueState = Get-QueueStateSnapshot
            return [pscustomobject]@{
                Success = `$true
                Command = `$commandName
                Catalog = @(Get-AppCatalogObjects | Where-Object Visible | Sort-Object DisplayName)
                RequiredAliases = @(Expand-RequiredCatalogAliases -Aliases @(Get-RequiredAliases) -Catalog @(Get-AppCatalogObjects))
                Queue = @(`$queueState.Queue)
                Current = `$queueState.Current
                Version = `$queueState.Version
                InstalledPackageIds = @(Get-InstalledPackageIds)
                AllowUserInstalls = (Test-UserInstallsAllowed)
                AllowUserUninstall = (Test-UserUninstallAllowed)
                EnforceRequired = (Test-RequiredEnforcementEnabled)
                Message = 'Katalog geladen.'
            }
        }

        { `$_ -in @('install','uninstall','refreshstatus') } {
            if (`$commandName -eq 'install') { `$requestCommand = 'Install' }
            elseif (`$commandName -eq 'uninstall') { `$requestCommand = 'Uninstall' }
            else { `$requestCommand = 'RefreshStatus' }

            New-CatalogRequestFile -Command `$requestCommand -Alias `$Alias
            return [pscustomobject]@{
                Success = `$true
                Command = `$commandName
                AppAlias = `$Alias
                Queued = `$true
                Message = 'Anfrage gespeichert.'
            }
        }

        default {
            throw "Unsupported command '`$Command'."
        }
    }
}

function Get-PolicyDword {
    param([Parameter(Mandatory=`$true)][string]`$Name, [int]`$Default = 0)

    try {
        if (-not (Test-Path -LiteralPath `$PolicyRoot)) { return `$Default }
        `$props = Get-ItemProperty -LiteralPath `$PolicyRoot -ErrorAction Stop
        `$property = `$props.PSObject.Properties[`$Name]
        if (-not `$property) { return `$Default }
        return [int]`$property.Value
    }
    catch {
        return `$Default
    }
}

function Test-SoftwareCatalogPolicyEnabled { (Get-PolicyDword -Name 'Enabled' -Default 0) -eq 1 }
function Test-UserInstallsAllowed { (Get-PolicyDword -Name 'AllowUserInstalls' -Default 1) -eq 1 }
function Test-UserUninstallAllowed { (Get-PolicyDword -Name 'AllowUserUninstall' -Default 1) -eq 1 }
function Test-RequiredEnforcementEnabled { (Get-PolicyDword -Name 'EnforceRequired' -Default 1) -eq 1 }

function Get-PolicyStringValues {
    param([Parameter(Mandatory=`$true)][string]`$Path)

    if (-not (Test-Path -LiteralPath `$Path)) { return @() }

    try {
        `$item = Get-Item -LiteralPath `$Path -ErrorAction Stop
        `$names = @(`$item.GetValueNames()) |
            Where-Object { `$_ -and `$_ -notmatch '^\*' } |
            Sort-Object |
            Select-Object -First `$PolicyMaxEntries

        foreach (`$name in `$names) {
            `$value = [string]`$item.GetValue(`$name, '')
            if (-not [string]::IsNullOrWhiteSpace(`$value)) {
                [pscustomobject]@{ Name = [string]`$name; Value = `$value.Trim() }
            }
        }
    }
    catch {
        return @()
    }
}

function Get-PolicyCatalogObjects {
    if (-not (Test-SoftwareCatalogPolicyEnabled)) { return @() }

    foreach (`$row in Get-PolicyStringValues -Path `$PolicyCatalogRoot) {
        `$alias = ([string]`$row.Name).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace(`$alias)) { continue }

        `$parts = ([string]`$row.Value) -split '\|', 3
        if (@(`$parts).Count -lt 2) { continue }

        `$packageId = ([string]`$parts[0]).Trim()
        `$displayName = ([string]`$parts[1]).Trim()
        `$description = ''
        if (@(`$parts).Count -ge 3) { `$description = ([string]`$parts[2]).Trim() }
        if ([string]::IsNullOrWhiteSpace(`$packageId)) { continue }
        if ([string]::IsNullOrWhiteSpace(`$displayName)) { `$displayName = `$alias }

        [pscustomobject]@{
            Alias = `$alias
            DisplayName = `$displayName
            Description = `$description
            PackageId = `$packageId
        }
    }
}

function Get-RequiredAliases {
    if (-not (Test-SoftwareCatalogPolicyEnabled)) { return @() }

    foreach (`$row in Get-PolicyStringValues -Path `$PolicyRequiredRoot) {
        `$value = ([string]`$row.Value).Trim()
        if (`$value -eq '0' -or `$value -eq 'false') { continue }
        `$alias = ([string]`$row.Name).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace(`$alias)) { `$alias }
    }
}

function Get-QueueStateSnapshot {
    `$state = [pscustomobject][ordered]@{ Version = 0; UpdatedAt = `$null; Current = `$null; Queue = @() }
    if (-not (Test-Path -LiteralPath `$QueueStatePath)) { return `$state }

    try {
        `$raw = Get-Content -LiteralPath `$QueueStatePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace(`$raw)) { return `$state }
        `$loaded = `$raw | ConvertFrom-Json
        if (`$loaded.PSObject.Properties['Version']) { `$state.Version = [int64]`$loaded.Version }
        if (`$loaded.PSObject.Properties['UpdatedAt']) { `$state.UpdatedAt = `$loaded.UpdatedAt }
        if (`$loaded.PSObject.Properties['Current']) { `$state.Current = `$loaded.Current }
        if (`$loaded.PSObject.Properties['Queue'] -and `$loaded.Queue) { `$state.Queue = @(`$loaded.Queue) }
    }
    catch {
    }

    return `$state
}

function Get-InstalledPackageIds {
    if (-not (Test-Path -LiteralPath `$InstalledPackagesPath)) { return @() }

    try {
        `$raw = Get-Content -LiteralPath `$InstalledPackagesPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace(`$raw)) { return @() }
        `$snapshot = `$raw | ConvertFrom-Json
        return @(`$snapshot.InstalledPackageIds)
    }
    catch {
        return @()
    }
}

function New-CatalogRequestFile {
    param(
        [Parameter(Mandatory=`$true)][ValidateSet('Install','Uninstall','RefreshStatus')][string]`$Command,
        [string]`$Alias
    )

    if (-not (Test-Path -LiteralPath `$RequestsDir)) {
        throw "Anfrageverzeichnis '`$RequestsDir' fehlt. Bitte Setup erneut ausführen."
    }

    `$id = [Guid]::NewGuid().ToString('N')
    `$payload = [ordered]@{
        Id = `$id
        Command = `$Command
        AppAlias = `$Alias
        CreatedAt = (Get-Date).ToString('o')
    }

    `$tempPath = Join-Path `$RequestsDir ("`$id.tmp")
    `$finalPath = Join-Path `$RequestsDir ("`$id.json")
    `$payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath `$tempPath -Encoding UTF8
    Move-Item -LiteralPath `$tempPath -Destination `$finalPath -Force
}

function New-AppRequest {
    param(
        [Parameter(Mandatory=`$true)][string]`$Alias,
        [Parameter(Mandatory=`$true)][ValidateSet('Install','Uninstall')][string]`$Action
    )

    return Invoke-CatalogLocal -Command `$Action -Alias (`$Alias.Trim().ToLowerInvariant())
}

function Get-CatalogApps {
    `$response = Invoke-CatalogLocal -Command 'GetState'
    `$script:AllowUserInstalls = [bool]`$response.AllowUserInstalls
    `$script:AllowUserUninstall = [bool]`$response.AllowUserUninstall
    `$script:RequiredAliasSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach (`$alias in @(`$response.RequiredAliases)) {
        if (-not [string]::IsNullOrWhiteSpace([string]`$alias)) {
            [void]`$script:RequiredAliasSet.Add([string]`$alias)
        }
    }
    `$script:LastStateVersion = [int64]`$response.Version
    if (`$response.Queue) { `$script:LastQueue = @(`$response.Queue) } else { `$script:LastQueue = @() }
    `$script:LastCurrent = `$response.Current
    if (`$response.InstalledPackageIds) { `$script:LastInstalledIds = @(`$response.InstalledPackageIds) } else { `$script:LastInstalledIds = @() }
    return @(`$response.Catalog)
}

function Get-InstalledPackageState {
    `$state = [ordered]@{
        GeneratedAt = `$null
        PackageSet  = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        Details = @()
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
        if (`$snapshot.PSObject.Properties['Packages']) { `$state.Details = @(`$snapshot.Packages) }
        if (`$snapshot.GeneratedAt) {
            # PS7 JSON dates may already be DateTime. Keep Kind/offset instead
            # of stringifying to a timezone-less local representation.
            `$state.GeneratedAt = `$snapshot.GeneratedAt
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
        [Parameter(Mandatory=`$true)]`$InstalledSet,
        [Parameter(Mandatory=`$true)]`$QueueItems
    )

    foreach (`$queued in @(`$QueueItems)) {
        if (-not `$queued) { continue }
        if (`$queued.State -in @('Queued','Running') -and [string]::Equals([string]`$queued.Alias, [string]`$App.Alias, [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]`$script:PendingRequests.Remove([string]`$App.Alias)
            if (`$queued.State -eq 'Running') {
                if (`$queued.Action -eq 'Uninstall') { return 'Wird deinstalliert' }
                return 'Wird installiert'
            }

            if (`$queued.Action -eq 'Uninstall') { return 'Deinstallation in Warteschlange' }
            return 'In Warteschlange'
        }
    }

    `$pending = `$script:PendingRequests[[string]`$App.Alias]
    if (`$pending) {
        if (`$pending.CreatedAt -lt (Get-Date).AddMinutes(-5)) {
            [void]`$script:PendingRequests.Remove([string]`$App.Alias)
        }
        elseif (`$pending.Action -eq 'Uninstall') {
            return 'Deinstallation in Warteschlange'
        }
        else {
            return 'In Warteschlange'
        }
    }

    if (`$InstalledSet.Contains(`$App.PackageId)) {
        return 'Installiert'
    }

    if (`$script:RequiredAliasSet.Contains([string]`$App.Alias)) {
        return 'In Warteschlange'
    }

    return 'Installierbar'
}

function Test-RequestQueuedInState {
    param(
        [Parameter(Mandatory=`$true)][string]`$Alias,
        [Parameter(Mandatory=`$true)][string]`$Action
    )

    if (-not (Test-Path -LiteralPath `$QueueStatePath)) {
        return `$false
    }

    try {
        `$raw = Get-Content -LiteralPath `$QueueStatePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace(`$raw)) {
            return `$false
        }

        `$queueState = `$raw | ConvertFrom-Json
        foreach (`$item in @(`$queueState.Queue)) {
            if (-not `$item) { continue }
            if (`$item.CreatedAt) {
                try {
                    `$createdAt = [DateTime]::Parse([string]`$item.CreatedAt)
                    if (`$createdAt -lt (Get-Date).AddMinutes(-10)) { continue }
                }
                catch {
                }
            }
            if (`$item.State -notin @('Queued','Running','Succeeded')) { continue }
            if (-not [string]::Equals([string]`$item.Alias, `$Alias, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if (-not [string]::Equals([string]`$item.Action, `$Action, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            return `$true
        }
    }
    catch {
    }

    return `$false
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
`$headerPanel.Size = New-Object System.Drawing.Size(940, 52)
`$headerPanel.Anchor = 'Top, Left, Right'
`$headerPanel.BackColor = [System.Drawing.SystemColors]::Window
`$headerPanel.BorderStyle = 'FixedSingle'

`$headerAccent = New-Object System.Windows.Forms.Panel
`$headerAccent.Location = New-Object System.Drawing.Point(0, 0)
`$headerAccent.Size = New-Object System.Drawing.Size(6, 50)
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
`$groupApps.Location = New-Object System.Drawing.Point(12, 72)
`$groupApps.Size = New-Object System.Drawing.Size(940, 384)
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
`$list.Size = New-Object System.Drawing.Size(916, 338)
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
[void]`$list.Columns.Add('Version / Ziel', 150)
[void]`$list.Columns.Add('Quelle', 90)
`$list.ShowItemToolTips = `$true
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
`$infoPanel.Size = New-Object System.Drawing.Size(940, 54)
`$infoPanel.Anchor = 'Left, Right, Bottom'
`$infoPanel.BorderStyle = 'FixedSingle'
`$infoPanel.BackColor = [System.Drawing.SystemColors]::Window

`$snapshotLabel = New-Object System.Windows.Forms.Label
`$snapshotLabel.Location = New-Object System.Drawing.Point(10, 8)
`$snapshotLabel.Size = New-Object System.Drawing.Size(914, 18)
`$snapshotLabel.Text = 'Installationsdaten: kein Datenstand vorhanden'

`$installedLabel = New-Object System.Windows.Forms.Label
`$installedLabel.Location = New-Object System.Drawing.Point(10, 30)
`$installedLabel.Size = New-Object System.Drawing.Size(914, 18)
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

    `$isRequired = `$script:RequiredAliasSet.Contains([string]`$selectedItem.SubItems[3].Text)
    `$btnInstall.Enabled = (`$script:AllowUserInstalls -and `$state -eq 'Installierbar')
    `$btnUninstall.Enabled = (`$script:AllowUserUninstall -and -not `$isRequired -and `$state -eq 'Installiert')
}

function Update-ProgressArea {
    `$current = `$script:LastCurrent
    `$queuedCount = @(`$script:LastQueue | Where-Object { `$_ -and `$_.State -eq 'Queued' }).Count
    if (`$current) {
        `$label = [string]`$current.StageText
        if ([string]::IsNullOrWhiteSpace(`$label)) { `$label = 'Aktion läuft...' }
        `$status.Text = "{0} (Warteschlange: {1})" -f `$label, `$queuedCount
        `$progressBar.Visible = `$true
        if (`$current.IsIndeterminate -or `$null -eq `$current.ProgressPercent) {
            `$progressBar.Style = 'Marquee'
        }
        else {
            `$progressBar.Style = 'Continuous'
            `$value = [int]`$current.ProgressPercent
            if (`$value -lt 0) { `$value = 0 }
            if (`$value -gt 100) { `$value = 100 }
            `$progressBar.Value = `$value
        }
    }
    elseif (`$queuedCount -gt 0) {
        `$status.Text = "Warteschlange: {0}" -f `$queuedCount
        `$progressBar.Visible = `$true
        `$progressBar.Style = 'Continuous'
        `$progressBar.Value = 0
    }
    else {
        `$status.Text = 'Bereit.'
        `$progressBar.Visible = `$false
        `$progressBar.Style = 'Continuous'
        `$progressBar.Value = 0
    }
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
        `$installedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach (`$id in @(`$script:LastInstalledIds)) {
            if (-not [string]::IsNullOrWhiteSpace([string]`$id)) { [void]`$installedSet.Add([string]`$id) }
        }

        if (-not `$installedSet) {
            `$installedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        }

        `$installedNames = New-Object 'System.Collections.Generic.List[string]'

        foreach (`$app in (`$apps | Sort-Object DisplayName)) {
            `$state = Get-AppStatus -App `$app -InstalledSet `$installedSet -QueueItems `$script:LastQueue

            `$item = New-Object System.Windows.Forms.ListViewItem(`$app.DisplayName)
            [void]`$item.SubItems.Add(`$app.Description)
            [void]`$item.SubItems.Add(`$state)
            [void]`$item.SubItems.Add(`$app.Alias)
            [void]`$item.SubItems.Add(`$app.PackageId)
            `$detail = @(`$installedState.Details | Where-Object { `$_.PackageId -eq `$app.PackageId } | Select-Object -First 1)
            `$versionText = ''
            `$providerText = [string]`$app.Provider
            if (`$detail.Count) {
                `$d = `$detail[0]
                `$versionText = [string]`$d.Version
                `$providerText = [string]`$d.Provider
                if (`$d.LatestVersion -and `$d.LatestVersion -ne `$d.Version) { `$versionText += ' / ' + `$d.LatestVersion }
                `$checked = if (`$d.LastCheckedUtc) { [string]`$d.LastCheckedUtc } else { 'Versionsstand nicht aktuell geprüft' }
                `$item.ToolTipText = "ArtCraft-Prüfung: `$checked"
                if (`$d.PSObject.Properties['MetadataStale'] -and `$d.MetadataStale) { `$item.ToolTipText += "`nOffline: letzter geprüfter Versionsstand (veraltet)." }
                if (`$d.LastError) { `$item.ToolTipText += "`nFehler: `$(`$d.LastError)" }
                if (`$d.RebootRequired) { `$item.ToolTipText += "`nNeustart erforderlich." }
            }
            [void]`$item.SubItems.Add(`$versionText)
            [void]`$item.SubItems.Add(`$providerText)
            `$item.Tag = `$app

            if (`$state -eq 'Installiert') {
                `$item.ForeColor = [System.Drawing.Color]::DarkGreen
                [void]`$installedNames.Add(`$app.DisplayName)
            }
            elseif (`$state -like '*Warteschlange') {
                `$item.ForeColor = [System.Drawing.Color]::DarkGoldenrod
            }
            elseif (`$state -like 'Wird *') {
                `$item.ForeColor = [System.Drawing.Color]::RoyalBlue
            }

            [void]`$list.Items.Add(`$item)
        }

        foreach (`$col in `$list.Columns) {
            if (`$col.Text -eq 'Paket-ID') { `$col.Width = 0 }
        }

        `$list.Sort()

        if (`$installedState.GeneratedAt) {
            try {
                `$timestamp = ([DateTime]`$installedState.GeneratedAt).ToLocalTime()
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

        Update-ProgressArea
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
`$status.Location = New-Object System.Drawing.Point(12, 526)
`$status.Size = New-Object System.Drawing.Size(700, 20)
`$status.Anchor = 'Left, Right, Bottom'
`$status.ForeColor = [System.Drawing.Color]::DimGray
`$status.Text = 'Bereit.'

`$progressBar = New-Object System.Windows.Forms.ProgressBar
`$progressBar.Location = New-Object System.Drawing.Point(12, 548)
`$progressBar.Size = New-Object System.Drawing.Size(700, 12)
`$progressBar.Anchor = 'Left, Right, Bottom'
`$progressBar.Style = 'Continuous'
`$progressBar.Visible = `$false

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

function Get-CatalogFileStamp {
    param([Parameter(Mandatory=`$true)][string]`$Path)

    try {
        if (-not (Test-Path -LiteralPath `$Path -PathType Leaf)) {
            return 'missing'
        }

        `$file = Get-Item -LiteralPath `$Path -Force -ErrorAction Stop
        return '{0}:{1}:{2}' -f `$file.CreationTimeUtc.Ticks, `$file.LastWriteTimeUtc.Ticks, `$file.Length
    }
    catch {
        return 'unavailable'
    }
}

# Keep change detection on the WinForms UI thread. Direct PowerShell handlers on
# FileSystemWatcher events run on worker threads and can terminate the host when
# no PowerShell runspace is available on the callback thread.
`$stateRefreshTimer = New-Object System.Windows.Forms.Timer
`$stateRefreshTimer.Interval = 500
`$script:StateRefreshPending = `$false
`$script:RequestWorkerBusy = `$false
`$script:LastQueueStateStamp = Get-CatalogFileStamp -Path `$QueueStatePath
`$script:LastSnapshotStamp = Get-CatalogFileStamp -Path `$InstalledPackagesPath

function Start-AppRequestAsync {
    param(
        [Parameter(Mandatory=`$true)]`$Selected,
        [Parameter(Mandatory=`$true)][ValidateSet('Install','Uninstall')][string]`$Action
    )

    if (`$script:RequestWorkerBusy) {
        `$status.Text = 'Eine Anfrage wird bereits verarbeitet.'
        return
    }

    `$script:RequestWorkerBusy = `$true
    `$btnInstall.Enabled = `$false
    `$btnUninstall.Enabled = `$false
    `$btnRefresh.Enabled = `$false

    try {
        `$response = New-AppRequest -Alias ([string]`$Selected.Alias) -Action `$Action
        `$script:PendingRequests[[string]`$Selected.Alias] = [pscustomobject]@{ Action = `$Action; CreatedAt = (Get-Date) }
        if (`$Action -eq 'Uninstall') { `$verb = 'Deinstallation' } else { `$verb = 'Installation' }
        if (`$response.Message) { `$status.Text = [string]`$response.Message } else { `$status.Text = "`$verb angefordert: {0}" -f `$Selected.DisplayName }
        [System.Windows.Forms.MessageBox]::Show(
            ("`$verb angefordert:`r`n`r`n{0}`r`nAlias: {1}" -f `$Selected.DisplayName, `$Selected.Alias),
            `$CatalogTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        `$script:StateRefreshPending = `$true
    }
    catch {
        throw
    }
    finally {
        `$script:RequestWorkerBusy = `$false
        `$btnRefresh.Enabled = `$true
        Update-InstallButtonState
    }
}

function Start-RefreshStatusAsync {
    if (`$script:RequestWorkerBusy) {
        `$status.Text = 'Eine Anfrage wird bereits verarbeitet.'
        return
    }

    `$script:RequestWorkerBusy = `$true
    `$btnInstall.Enabled = `$false
    `$btnUninstall.Enabled = `$false
    `$btnRefresh.Enabled = `$false
    `$status.Text = 'Installationsdaten-Aktualisierung wird angefordert...'

    try {
        `$response = Invoke-CatalogLocal -Command 'RefreshStatus'
        if (`$response.Message) { `$status.Text = [string]`$response.Message } else { `$status.Text = 'Installationsdaten-Aktualisierung angefordert.' }
        `$script:StateRefreshPending = `$true
    }
    catch {
        throw
    }
    finally {
        `$script:RequestWorkerBusy = `$false
        `$btnRefresh.Enabled = `$true
        Update-InstallButtonState
    }
}

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

        `$status.Text = "Installation wird eingereiht: {0}" -f `$selected.DisplayName
        `$selectedItem.SubItems[2].Text = 'In Warteschlange'
        `$selectedItem.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        Update-InstallButtonState
        Start-AppRequestAsync -Selected `$selected -Action 'Install'
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

        `$status.Text = "Deinstallation wird eingereiht: {0}" -f `$selected.DisplayName
        `$selectedItem.SubItems[2].Text = 'Deinstallation in Warteschlange'
        `$selectedItem.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        Update-InstallButtonState
        Start-AppRequestAsync -Selected `$selected -Action 'Uninstall'
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
        Start-RefreshStatusAsync
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

`$stateRefreshTimer.Add_Tick({
    `$queueStateStamp = Get-CatalogFileStamp -Path `$QueueStatePath
    `$snapshotStamp = Get-CatalogFileStamp -Path `$InstalledPackagesPath
    if (`$queueStateStamp -ne `$script:LastQueueStateStamp -or `$snapshotStamp -ne `$script:LastSnapshotStamp) {
        `$script:LastQueueStateStamp = `$queueStateStamp
        `$script:LastSnapshotStamp = `$snapshotStamp
        `$script:StateRefreshPending = `$true
    }

    if (-not `$script:StateRefreshPending) { return }
    if (`$script:RequestWorkerBusy) { return }
    `$script:StateRefreshPending = `$false
    try { Load-AppList }
    catch {
        `$script:StateRefreshPending = `$true
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

`$form.Add_Shown({
    `$script:LastQueueStateStamp = Get-CatalogFileStamp -Path `$QueueStatePath
    `$script:LastSnapshotStamp = Get-CatalogFileStamp -Path `$InstalledPackagesPath
    `$stateRefreshTimer.Start()
})
`$form.Add_FormClosing({
    `$stateRefreshTimer.Stop()
    `$stateRefreshTimer.Dispose()
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
`$form.Controls.Add(`$progressBar)
`$form.Controls.Add(`$btnInstall)
`$form.Controls.Add(`$btnUninstall)
`$form.Controls.Add(`$btnRefresh)
`$form.Controls.Add(`$btnOpenLog)
`$form.Controls.Add(`$btnClose)

`$form.AcceptButton = `$btnInstall
`$form.CancelButton = `$btnClose

try {
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

function Unregister-ObsoleteDaemonTask {
    try {
        $existingDaemon = Get-ScheduledTask -TaskName $DaemonTaskName -ErrorAction SilentlyContinue
        if ($existingDaemon) {
            Write-Log "Removing obsolete scheduled task '$DaemonTaskName'."
            Stop-ScheduledTask -TaskName $DaemonTaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $DaemonTaskName -Confirm:$false
        }
    }
    catch {
        Write-Log "Could not remove daemon task '$DaemonTaskName': $($_.Exception.Message)" 'WARN'
    }
}

function Stop-SoftwarekatalogScheduledTasksForUpdate {
    foreach ($taskName in @($RequestTaskName, $QueueTaskName, $UpgradeTaskName, $LegacyQueueTaskName, $DaemonTaskName)) {
        if ([string]::IsNullOrWhiteSpace($taskName)) { continue }

        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) {
                Write-Log "Stopping scheduled task '$taskName' before update."
                Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                for ($attempt = 0; $attempt -lt 10; $attempt++) {
                    $currentTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                    if (-not $currentTask -or [string]$currentTask.State -ne "Running") { break }
                    Start-Sleep -Milliseconds 500
                }
            }
        }
        catch {
            Write-Log "Could not stop scheduled task '$taskName': $($_.Exception.Message)" 'WARN'
        }
    }
}

function Stop-ObsoleteDaemonProcesses {
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    }
    catch {
        Write-Log "Could not enumerate processes for Softwarekatalog worker cleanup: $($_.Exception.Message)" 'WARN'
        return
    }

    foreach ($process in $processes) {
        if (-not $process) { continue }
        if ([int]$process.ProcessId -eq $PID) { continue }
        if ([string]$process.Name -notin @('powershell.exe','pwsh.exe')) { continue }

        $commandLine = [string]$process.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) { continue }

        $matchesScriptPath = $commandLine.IndexOf($LocalScriptPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
        $matchesScriptName = ($commandLine.IndexOf('SelfServiceWinget.ps1', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and $commandLine.IndexOf($BaseDir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not ($matchesScriptPath -or $matchesScriptName)) { continue }

        try {
            Write-Log "Stopping existing Softwarekatalog process pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        }
        catch {
            Write-Log "Could not stop Softwarekatalog process pid=$($process.ProcessId): $($_.Exception.Message)" 'WARN'
        }
    }
}

function Register-OrUpdateTasks {
    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    Write-Log "Registering/updating scheduled task '$RequestTaskName'."
    $requestArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$LocalScriptPath`" -Mode ProcessRequests"
    $requestAction = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $requestArgs
    $requestStartupTrigger = New-ScheduledTaskTrigger -AtStartup
    $requestPollTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $requestSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    $requestTask = New-ScheduledTask `
        -Action $requestAction `
        -Trigger @($requestStartupTrigger, $requestPollTrigger) `
        -Principal $principal `
        -Settings $requestSettings

    Register-ScheduledTask -TaskName $RequestTaskName -InputObject $requestTask -Force | Out-Null

    Write-Log "Registering/updating scheduled task '$QueueTaskName'."
    $queueArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$LocalScriptPath`" -Mode ProcessQueue"
    $queueAction = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $queueArgs
    $queueSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 3)

    $queueTask = New-ScheduledTask `
        -Action $queueAction `
        -Principal $principal `
        -Settings $queueSettings

    Register-ScheduledTask -TaskName $QueueTaskName -InputObject $queueTask -Force | Out-Null

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
        Start-ScheduledTask -TaskName $RequestTaskName
    }
    catch {
        Write-Log "Could not start request task '$RequestTaskName': $($_.Exception.Message)" 'WARN'
    }
}

function Get-MachineMsiProfiles {
    # Verified vendor MSI identities, not a wildcard over unrelated EXE apps.
    @(
        [pscustomobject]@{ PackageId = 'ArtCraft.GridCraft'; UpgradeCode = '{5511327B-F305-41BE-92D0-EB84944E7C4D}'; Executable = 'ArtCraft\GridCraft\gridcraft.exe' }
        [pscustomobject]@{ PackageId = 'ArtCraft.PdfCraft'; UpgradeCode = '{EA00C367-7270-4C50-9D8B-A7A5C88AD27F}'; Executable = 'ArtCraft\PdfCraft\pdfcraft.exe' }
    )
}

function Get-MachineInstallerArguments {
    param([Parameter(Mandatory)][string]$PackageId)

    # --scope selects a manifest installer; it does not set MSI properties.
    # These vendors' dual-context WiX installers default to per-user even though
    # its winget manifest declares Scope: machine. Append, never --override.
    if (@(Get-MachineMsiProfiles | Where-Object { $_.PackageId -eq $PackageId }).Count -gt 0) {
        return @('--custom', 'ALLUSERS=1')
    }
}

function Invoke-WingetQuery {
    param([string]$WingetPath, [string[]]$Arguments)

    Set-WingetOutputEncoding
    $output = & $WingetPath @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    foreach ($line in ($output -split "`r?`n")) {
        $displayLine = ConvertTo-WingetOutputLine -Line $line
        if ($displayLine) { Write-Log "winget: $displayLine" }
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $output }
}

function Test-RunningAsLocalSystem {
    return [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
}

function Test-SystemProfileAppDataPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $pathValue = [Environment]::ExpandEnvironmentVariables($Path).Trim().Replace('/', '\')
    if ($pathValue -match '^"([^"]+)"') { $pathValue = $Matches[1] }
    $pathValue = ($pathValue -replace ',\s*-?\d+$', '').TrimEnd('\')
    # Be conservative about noncanonical paths; never accept a sibling prefix.
    if ($pathValue -match '(^|\\)\.\.?($|\\)') { return $false }
    foreach ($systemDir in @('System32', 'SysWOW64', 'Sysnative')) {
        $root = "$env:SystemRoot\$systemDir\config\systemprofile\AppData"
        if ($pathValue.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
            $pathValue.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-RegisteredApplications {
    param([switch]$IncludeUnnamed)
    # Explicit registry views avoid the caller's PowerShell bitness. Do not
    # enumerate ordinary users' hives or use Win32_Product (triggers repairs).
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        foreach ($scope in @('machine', 'user')) {
            $hive = if ($scope -eq 'machine') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::Users }
            $prefix = if ($scope -eq 'user') { 'S-1-5-18\' } else { '' }
            $base = $null
            $uninstall = $null
            try {
                $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
                $uninstall = $base.OpenSubKey("${prefix}Software\Microsoft\Windows\CurrentVersion\Uninstall")
                if (-not $uninstall) { continue }
                foreach ($name in $uninstall.GetSubKeyNames()) {
                    $key = $uninstall.OpenSubKey($name)
                    if (-not $key) { continue }
                    try {
                        $displayName = [string]$key.GetValue('DisplayName', '')
                        if (-not $displayName -and -not $IncludeUnnamed) { continue }
                        [pscustomobject]@{
                            ProductCode = $name
                            DisplayName = $displayName
                            InstallLocation = [string]$key.GetValue('InstallLocation', '')
                            DisplayIcon = [string]$key.GetValue('DisplayIcon', '')
                            WindowsInstaller = ([int]$key.GetValue('WindowsInstaller', 0) -eq 1)
                            Scope = $scope
                            RegistryView = $view
                        }
                    }
                    finally { $key.Dispose() }
                }
            }
            finally {
                if ($uninstall) { $uninstall.Dispose() }
                if ($base) { $base.Dispose() }
            }
        }
    }
}

function Test-MsiClassicLookupSafe {
    param([Parameter(Mandatory)]$Registration,
        [object[]]$Registrations = @(Get-RegisteredApplications -IncludeUnnamed))

    # SYSTEM per-user MSIs can have machine ARP entries while every extended
    # component/enumeration API reports UNKNOWN. Do not use LocalPackage/State
    # to disambiguate: both contexts can return the same shared SYSTEM data.
    # Only allow the classic current-user/machine lookup for one registered
    # scope, including hidden/unnamed ARP records. Never inspect other users.
    $matches = @($Registrations | Where-Object { $_.ProductCode -eq $Registration.ProductCode })
    if ($matches.Count -eq 0 -or @($matches | Where-Object { -not $_.WindowsInstaller }).Count -gt 0) { return $false }
    $scopes = @($matches | Select-Object -ExpandProperty Scope -Unique)
    return ($scopes.Count -eq 1 -and $scopes[0] -eq $Registration.Scope)
}

function Get-MsiRegistrationEvidence {
    param([Parameter(Mandatory)]$Registration)

    if (-not $Registration.WindowsInstaller -or $Registration.ProductCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { return }
    $installer = $null
    $database = $null
    $view = $null
    $lookupResults = @()
    $allowClassicLookup = $null
    try {
        if ($Registration.Scope -eq 'user' -and -not (Test-RunningAsLocalSystem)) { return }
        if (-not ('Softwarekatalog.NativeMsi' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace Softwarekatalog {
    public static class NativeMsi {
        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        public static extern uint MsiGetProductInfoEx(string product, string sid,
            uint context, string property, StringBuilder value, ref uint length);
        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        public static extern int MsiGetComponentPathEx(string product, string component,
            string sid, uint context, StringBuilder path, ref uint length);
        [DllImport("msi.dll", CharSet = CharSet.Unicode)]
        public static extern int MsiGetComponentPath(string product, string component,
            StringBuilder path, ref uint length);
        // PowerShell converts $null to String.Empty for .NET string parameters.
        // Keep the mandatory native NULL SID inside C#, not at the PS boundary.
        public static uint GetProductInfo(string product, uint context, string property,
            StringBuilder value, ref uint length) {
            return MsiGetProductInfoEx(product, null, context, property, value, ref length);
        }
        public static int GetComponentPath(string product, string component, uint context,
            StringBuilder path, ref uint length) {
            return MsiGetComponentPathEx(product, component, null, context, path, ref length);
        }
    }
}
'@
        }
        # Context-free ProductInfo/ComponentPath may return the user copy when
        # the SAME product GUID is also installed machine-wide. Resolve the
        # registration's exact context so a healthy machine copy is not removed.
        # A null SID means the current SYSTEM user; do not pass S-1-5-18 to MSI.
        $contexts = if ($Registration.Scope -eq 'machine') { @(4) } else { @(2, 1) }
        $msiContext = 0
        $cache = $null
        foreach ($context in $contexts) {
            $buffer = New-Object System.Text.StringBuilder 32768
            $length = [uint32]32768
            $result = [Softwarekatalog.NativeMsi]::GetProductInfo(
                $Registration.ProductCode, [uint32]$context, 'LocalPackage', $buffer, [ref]$length)
            $lookupResults += "context=$context Win32=$result"
            if ($result -eq 0) { $cache = $buffer.ToString(); $msiContext = $context; break }
        }
        if (-not $cache) { throw 'No cached MSI in the registered installation context.' }
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $database = $installer.OpenDatabase($cache, 0) # Read-only, never install/repair.
        $view = $database.OpenView('SELECT `Value` FROM `Property` WHERE `Property` = ''UpgradeCode''')
        [void]$view.Execute()
        $record = $view.Fetch()
        $upgradeCode = if ($record) { [string]$record.StringData(1) } else { '' }
        if ($record) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
        [void]$view.Close()
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
        $view = $database.OpenView('SELECT `ComponentId` FROM `Component`')
        [void]$view.Execute()
        $paths = @()
        $componentDiagnostics = @()
        $record = $view.Fetch()
        while ($null -ne $record) {
            try {
                $componentId = [string]$record.StringData(1)
                if ($componentId) {
                    $buffer = New-Object System.Text.StringBuilder 32768
                    $length = [uint32]32768
                    $state = [Softwarekatalog.NativeMsi]::GetComponentPath(
                        $Registration.ProductCode, $componentId, [uint32]$msiContext, $buffer, [ref]$length)
                    $pathLookup = 'context'
                    if ($state -eq -1 -and (Test-RunningAsLocalSystem)) {
                        if ($null -eq $allowClassicLookup) {
                            $allowClassicLookup = Test-MsiClassicLookupSafe -Registration $Registration
                            if (-not $allowClassicLookup) {
                                $script:MsiInspectionFailures += $Registration.ProductCode
                                Write-Log "Cannot safely resolve legacy MSI '$($Registration.ProductCode)': conflicting or missing registered scopes; classic lookup refused." 'WARN'
                            }
                        }
                        if ($allowClassicLookup) {
                            $pathLookup = 'classic-system-single-scope'
                            [void]$buffer.Clear()
                            $length = [uint32]32768
                            $state = [Softwarekatalog.NativeMsi]::MsiGetComponentPath(
                                $Registration.ProductCode, $componentId, $buffer, [ref]$length)
                        }
                    }
                    $pathValue = $buffer.ToString()
                    if ($componentDiagnostics.Count -lt 5) {
                        $componentDiagnostics += [pscustomobject]@{ ComponentId = $componentId; Context = $msiContext; Lookup = $pathLookup; State = $state; Path = $pathValue }
                    }
                    # Settings in AppData are normal; only executable payloads
                    # are evidence when ARP has no InstallLocation (e.g. WiX).
                    if ($state -eq 3 -and $pathValue -match '(?i)\.exe$') { $paths += $pathValue }
                }
            }
            finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
            $record = $view.Fetch()
        }
        return [pscustomobject]@{ UpgradeCode = $upgradeCode; ExecutablePaths = $paths; ComponentDiagnostics = $componentDiagnostics }
    }
    catch {
        $script:MsiInspectionFailures += $Registration.ProductCode
        Write-Log "Cannot inspect MSI '$($Registration.ProductCode)' '$($Registration.DisplayName)' scope='$($Registration.Scope)' lookup='$($lookupResults -join '; ')': $($_.Exception.Message)" 'WARN'
    }
    finally {
        if ($view) { [void]$view.Close(); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) }
        if ($database) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
        if ($installer) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
    }
}

function Get-SystemProfileApplications {
    param([object[]]$Registrations = @(Get-RegisteredApplications))

    foreach ($registration in $Registrations) {
        $paths = @($registration.InstallLocation)
        $evidence = $null
        if ([string]::IsNullOrWhiteSpace($registration.InstallLocation)) {
            # A cached .ico in AppData is not an application installation.
            if ($registration.DisplayIcon -match '(?i)\.exe"?(,\s*-?\d+)?$') { $paths += $registration.DisplayIcon }
            if ($registration.WindowsInstaller) {
                $evidence = Get-MsiRegistrationEvidence -Registration $registration
                if ($evidence) { $paths += @($evidence.ExecutablePaths) }
            }
        }
        if (@($paths | Where-Object { Test-SystemProfileAppDataPath -Path $_ }).Count -gt 0) {
            Write-Log "SYSTEM-profile installation detected: '$($registration.DisplayName)' product='$($registration.ProductCode)' scope='$($registration.Scope)' paths='$($paths -join '; ')'." 'WARN'
            [pscustomobject]@{ Registration = $registration; MsiEvidence = $evidence }
        }
    }
}

function Find-SystemProfileCatalogApp {
    param([string]$WingetPath, $Candidate, [object[]]$Catalog, [object[]]$Registrations)

    $registration = $Candidate.Registration
    $evidence = $Candidate.MsiEvidence
    if (-not $evidence -and $registration.WindowsInstaller) {
        $evidence = Get-MsiRegistrationEvidence -Registration $registration
    }
    # Stable vendor MSI identity also works when winget cannot correlate an
    # old user installation. Never infer identity from a folder/display name.
    if ($evidence) {
        $profile = Get-MachineMsiProfiles | Where-Object { $_.UpgradeCode -eq $evidence.UpgradeCode } | Select-Object -First 1
        if ($profile) { return $Catalog | Where-Object { $_.PackageId -eq $profile.PackageId } | Select-Object -First 1 }
    }

    # For other packages require an unambiguous ARP name in this scope AND an
    # exact winget source correlation. Ambiguous/unknown products are logged,
    # not guessed at. The uninstall is additionally restricted by product code.
    $sameName = @($Registrations | Where-Object {
        $_.Scope -eq $registration.Scope -and $_.DisplayName -eq $registration.DisplayName
    } | Select-Object -ExpandProperty ProductCode -Unique)
    if ($sameName.Count -ne 1) { return }
    $result = Invoke-WingetQuery -WingetPath $WingetPath -Arguments @(
        'list', '--name', $registration.DisplayName, '--exact', '--scope', $registration.Scope,
        '--source', $WingetSourceName, '--accept-source-agreements', '--disable-interactivity'
    )
    if ($result.ExitCode -ne 0) { return }
    $apps = @($Catalog | Where-Object {
        $result.Output -match ('(?m)(?<!\S)' + [regex]::Escape($_.PackageId) + '(?!\S)')
    } | Sort-Object -Property PackageId -Unique)
    if ($apps.Count -eq 1) { return $apps[0] }
}

function Test-WingetMachineInstallation {
    param([string]$WingetPath, [string]$PackageId)

    $result = Invoke-WingetQuery -WingetPath $WingetPath -Arguments @(
        'list', '--id', $PackageId, '--exact', '--scope', 'machine', '--source', $WingetSourceName,
        '--accept-source-agreements', '--disable-interactivity'
    )
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch ('(?m)(?<!\S)' + [regex]::Escape($PackageId) + '(?!\S)')) { return $false }
    $profile = Get-MachineMsiProfiles | Where-Object { $_.PackageId -eq $PackageId } | Select-Object -First 1
    if ($profile) {
        foreach ($root in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Select-Object -Unique) {
            if ($root -and (Test-Path -LiteralPath (Join-Path $root $profile.Executable))) { return $true }
        }
        return $false
    }
    return $true
}

function Uninstall-SystemProfileApplication {
    param([string]$WingetPath, [string]$PackageId, $Registration)

    $result = Invoke-WingetQuery -WingetPath $WingetPath -Arguments @(
        'uninstall', '--id', $PackageId, '--exact', '--product-code', $Registration.ProductCode,
        '--scope', $Registration.Scope, '--source', $WingetSourceName, '--silent',
        '--accept-source-agreements', '--disable-interactivity'
    )
    # Only fall back when winget lacks correlation/uninstall metadata, not on
    # arbitrary installer errors. Execute a validated product GUID, never an
    # arbitrary registry command line. This also works for SYSTEM's user MSI.
    if ($result.ExitCode -in @(-1978335212, -1978335185) -and $Registration.WindowsInstaller -and
        $Registration.ProductCode -match '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
        $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
        Write-Log "Using registered MSI uninstall for '$PackageId' product '$($Registration.ProductCode)'."
        $msiArguments = @('/x', $Registration.ProductCode, '/qn', '/norestart')
        if ($Registration.Scope -eq 'machine') { $msiArguments += 'ALLUSERS=1' }
        $process = Start-Process -FilePath $msiexec -ArgumentList $msiArguments -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw "MSI uninstall of '$PackageId' returned $($process.ExitCode); retry after any required restart." }
    }
    elseif ($result.ExitCode -ne 0) { throw "Uninstall of '$PackageId' returned $($result.ExitCode)." }

    $remaining = @(Get-RegisteredApplications | Where-Object {
        $_.ProductCode -eq $Registration.ProductCode -and $_.Scope -eq $Registration.Scope
    })
    if ($remaining.Count -gt 0) { throw "Registration '$($Registration.ProductCode)' still exists after uninstall; machine install deferred." }
}

function Write-ScopeRepairJournal {
    param([object[]]$Entries)

    $tempPath = "$ScopeRepairPath.tmp"
    ConvertTo-Json -InputObject @($Entries) -Depth 5 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $ScopeRepairPath -Force
}

function Add-ScopeRepairIntent {
    param([string]$PackageId)

    $entries = @()
    if (Test-Path -LiteralPath $ScopeRepairPath) {
        $parsedEntries = Get-Content -LiteralPath $ScopeRepairPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $entries = @($parsedEntries)
    }
    if (@($entries | Where-Object { $_.PackageId -eq $PackageId }).Count -eq 0) {
        $entries += [pscustomobject]@{ PackageId = $PackageId; StartedAt = (Get-Date).ToString('o') }
        Write-ScopeRepairJournal -Entries $entries
    }
}

function Invoke-SystemProfileRepairs {
    param([string]$WingetPath)

    $script:ScopeRepairFailures = @()
    $script:MsiInspectionFailures = @()
    if (-not (Test-SoftwareCatalogPolicyEnabled)) { return }
    if (-not (Test-RunningAsLocalSystem)) {
        throw 'SYSTEM-profile repair must run as LocalSystem.'
    }
    $catalog = @(Get-AppCatalogObjects | Where-Object { -not (Test-ArtCraftManagedPackage -PackageId $_.PackageId) })
    $journal = @()
    if (Test-Path -LiteralPath $ScopeRepairPath) {
        # A corrupt journal must not be silently discarded after an uninstall.
        # PS 5.1 emits JSON arrays as one pipeline object; PS 7 enumerates them.
        $parsedJournal = Get-Content -LiteralPath $ScopeRepairPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $journal = @($parsedJournal)
    }
    $registrations = @(Get-RegisteredApplications)
    $repairs = @{}
    $candidates = @(Get-SystemProfileApplications -Registrations $registrations)
    foreach ($candidate in $candidates) {
        $app = Find-SystemProfileCatalogApp -WingetPath $WingetPath -Candidate $candidate -Catalog $catalog -Registrations $registrations
        if (-not $app) {
            Write-Log "No unambiguous allowed catalog package for '$($candidate.Registration.DisplayName)'; leaving registration and files untouched." 'WARN'
            continue
        }
        if (-not $repairs.ContainsKey($app.PackageId)) { $repairs[$app.PackageId] = @() }
        $repairs[$app.PackageId] += $candidate.Registration
    }
    foreach ($entry in $journal) {
        if (@($catalog | Where-Object { $_.PackageId -eq $entry.PackageId }).Count -gt 0 -and -not $repairs.ContainsKey($entry.PackageId)) {
            $repairs[$entry.PackageId] = @()
        }
    }
    Write-Log "SYSTEM-profile inventory: registrations=$($registrations.Count) suspects=$($candidates.Count) repairPackages=$($repairs.Count) MSI-inspection-failures=$(@($script:MsiInspectionFailures | Select-Object -Unique).Count)."
    foreach ($packageId in @($repairs.Keys)) {
        try {
            $downloadDir = Join-Path $BaseDir ('Scope-Repair-Download-' + (ConvertTo-SafeQueueFileName -Id $packageId))
            # `show` can return success even with no applicable installer.
            # Resolve and download the machine installer before uninstalling;
            # this also catches source/network/hash failures non-destructively.
            $preflight = Invoke-WingetQuery -WingetPath $WingetPath -Arguments @(
                'download', '--id', $packageId, '--exact', '--scope', 'machine', '--source', $WingetSourceName,
                '--download-directory', $downloadDir, '--skip-dependencies',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
            )
            if ($preflight.ExitCode -ne 0) { throw "No machine installer available for '$packageId'; original installation retained." }
            if (@($journal | Where-Object { $_.PackageId -eq $packageId }).Count -eq 0) {
                $journal += [pscustomobject]@{ PackageId = $packageId; StartedAt = (Get-Date).ToString('o') }
            }
            # Write BEFORE removing anything. Retain this intent across failed
            # downloads, queue failures, process termination and device restarts.
            Write-ScopeRepairJournal -Entries $journal
            foreach ($registration in @($repairs[$packageId] | Sort-Object -Property Scope, ProductCode -Unique)) {
                Uninstall-SystemProfileApplication -WingetPath $WingetPath -PackageId $packageId -Registration $registration
            }
            if (-not (Test-WingetMachineInstallation -WingetPath $WingetPath -PackageId $packageId)) {
                $code = Invoke-WingetInstall -WingetPath $WingetPath -PackageId $packageId
                if ($code -ne 0) { throw "Machine reinstall of '$packageId' failed ($code); repair intent retained." }
            }
            $remaining = @(Get-SystemProfileApplications | Where-Object {
                $app = Find-SystemProfileCatalogApp -WingetPath $WingetPath -Candidate $_ -Catalog $catalog -Registrations @(Get-RegisteredApplications)
                $app -and $app.PackageId -eq $packageId
            })
            if ($remaining.Count -gt 0 -or -not (Test-WingetMachineInstallation -WingetPath $WingetPath -PackageId $packageId)) {
                throw "Machine installation of '$packageId' could not be verified; repair intent retained."
            }
            $journal = @($journal | Where-Object { $_.PackageId -ne $packageId })
            Write-ScopeRepairJournal -Entries $journal
            Write-Log "SYSTEM-profile repair completed for '$packageId'."
            if (Test-Path -LiteralPath $downloadDir) { Remove-Item -LiteralPath $downloadDir -Recurse -Force }
        }
        catch {
            $script:ScopeRepairFailures += $packageId
            Write-Log "SYSTEM-profile repair failed for '$packageId': $($_.Exception.Message)" 'ERROR'
        }
    }
}

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId,
        [string]$QueueItemId
    )

    $arguments = @(
        'install'
        '--id', $PackageId
        '--source', $WingetSourceName
        '--exact'
        '--scope', 'machine'
        '--silent'
        '--accept-package-agreements'
        '--accept-source-agreements'
        '--disable-interactivity'
    )
    $arguments += @(Get-MachineInstallerArguments -PackageId $PackageId)

    Write-Log "Executing: `"$WingetPath`" $($arguments -join ' ')"
    if ($QueueItemId) {
        Update-QueueItemProgress -Id $QueueItemId -Stage 'Install' -StageText 'Installation läuft...' -IsIndeterminate:$true
    }

    Set-WingetOutputEncoding
    & $WingetPath @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $displayLine = ConvertTo-WingetOutputLine -Line $line
        if ($displayLine) { Write-Log "winget: $displayLine" }

        if ($QueueItemId) {
            $percent = Get-ProgressPercentFromLine -Line $line
            if ($null -ne $percent) {
                Update-QueueItemProgress -Id $QueueItemId -Stage 'Download' -StageText ("Download läuft... {0}%" -f $percent) -ProgressPercent $percent -IsIndeterminate:$false
            }
        }
    }
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0 -and -not (Test-WingetMachineInstallation -WingetPath $WingetPath -PackageId $PackageId)) {
        $script:ScopeRepairFailures += $PackageId
        Add-ScopeRepairIntent -PackageId $PackageId
        throw "winget reported success for '$PackageId', but a machine installation could not be verified."
    }
    if ($exitCode -eq 0) {
        foreach ($candidate in @(Get-SystemProfileApplications)) {
            $app = Find-SystemProfileCatalogApp -WingetPath $WingetPath -Candidate $candidate -Catalog @(Get-AppCatalogObjects) -Registrations @(Get-RegisteredApplications)
            if ($app -and $app.PackageId -eq $PackageId) {
                $script:ScopeRepairFailures += $PackageId
                Add-ScopeRepairIntent -PackageId $PackageId
                throw "'$PackageId' installed into SYSTEM AppData despite --scope machine; refusing to report success."
            }
        }
    }
    return $exitCode
}

function Invoke-WingetUninstall {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId,
        [string]$QueueItemId
    )

    $arguments = @(
        'uninstall'
        '--id', $PackageId
        '--source', $WingetSourceName
        '--exact'
        '--scope', 'machine'
        '--silent'
        '--accept-source-agreements'
        '--disable-interactivity'
    )

    Write-Log "Executing: `"$WingetPath`" $($arguments -join ' ')"
    if ($QueueItemId) {
        Update-QueueItemProgress -Id $QueueItemId -Stage 'Uninstall' -StageText 'Deinstallation läuft...' -IsIndeterminate:$true
    }

    Set-WingetOutputEncoding
    & $WingetPath @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $displayLine = ConvertTo-WingetOutputLine -Line $line
        if ($displayLine) { Write-Log "winget: $displayLine" }

        if ($QueueItemId) {
            $percent = Get-ProgressPercentFromLine -Line $line
            if ($null -ne $percent) {
                Update-QueueItemProgress -Id $QueueItemId -Stage 'Uninstall' -StageText ("Deinstallation läuft... {0}%" -f $percent) -ProgressPercent $percent -IsIndeterminate:$false
            }
        }
    }
    $exitCode = $LASTEXITCODE

    return $exitCode
}

function Invoke-WingetUpgradeAll {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [string]$QueueItemId
    )

    if ($script:ScopeRepairFailures.Count -gt 0) {
        throw "Automatic upgrades deferred because SYSTEM-profile repairs failed: $($script:ScopeRepairFailures -join ', ')."
    }
    # Never follow provider filtering with --all: winget would rediscover the
    # custom-managed MSI and become a competing updater. No global pins/settings.
    $failure = 0
    $installedSet = Get-InstalledPackageIdSet
    foreach ($packageId in @($installedSet | Sort-Object)) {
        if (Test-ArtCraftManagedPackage -PackageId $packageId) { continue }
        if ($packageId -notmatch '^[A-Za-z0-9][A-Za-z0-9._+\-]{1,255}$') {
            Write-Log "Unsafe exported package identifier ignored: '$packageId'." 'WARN'
            continue
        }
        if ($QueueItemId) {
            Update-QueueItemProgress -Id $QueueItemId -Stage 'Upgrade' -StageText "Updates: $packageId" -IsIndeterminate:$true
        }
        $result = Invoke-WingetQuery -WingetPath $WingetPath -Arguments (@(
            'upgrade', '--id', $packageId, '--exact', '--source', $WingetSourceName,
            '--scope', 'machine', '--silent', '--accept-package-agreements',
            '--accept-source-agreements', '--disable-interactivity'
        ) + @(Get-MachineInstallerArguments -PackageId $packageId))
        if ($result.ExitCode -notin @(0, -1978335189, -1978335212)) { # current / no machine match
            Write-Log "$packageId machine upgrade failed ($($result.ExitCode))." 'ERROR'
            $failure = $result.ExitCode
        }
        if (@(Get-MachineMsiProfiles | Where-Object { $_.PackageId -eq $packageId }).Count -gt 0 -and
            -not (Test-WingetMachineInstallation -WingetPath $WingetPath -PackageId $packageId)) {
            throw "$packageId machine installation could not be verified after upgrade."
        }
    }
    return $failure
}

function Update-WingetPackagesSnapshot {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$QueueItemId
    )

    Ensure-Directory -Path $BaseDir

    $tempRoot = if ($env:TEMP) { $env:TEMP } elseif ($env:TMP) { $env:TMP } else { $BaseDir }
    $tempFile = Join-Path $tempRoot ("selfservice-winget-export-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    $snapshotTempFile = "$DestinationPath.tmp"

    $arguments = @(
        'export'
        '--output', $tempFile
        '--source', $WingetSourceName
        '--accept-source-agreements'
        '--disable-interactivity'
    )

    Write-Log 'Refreshing installed package snapshot.'
    if ($QueueItemId) {
        Update-QueueItemProgress -Id $QueueItemId -Stage 'Snapshot' -StageText 'Installationsdaten werden aktualisiert...' -IsIndeterminate:$true
    }
    Set-WingetOutputEncoding
    $output = & $WingetPath @arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    $unmatchedPackageCount = 0
    if ($output) {
        foreach ($line in ($output -split "`r?`n")) {
            $displayLine = ConvertTo-WingetOutputLine -Line $line
            if (-not $displayLine) { continue }

            if ($displayLine -match '^Installed package is not available from (?:any )?source:') {
                $unmatchedPackageCount++
                continue
            }

            Write-Log "winget export: $displayLine"
        }
    }
    if ($unmatchedPackageCount -gt 0) {
        Write-Log "winget export ignored $unmatchedPackageCount installed packages that are not represented in source '$WingetSourceName'."
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
        # A correlated SYSTEM-profile copy is not a usable machine install.
        # Do not let export turn a failed migration into "already installed".
        $packageIds = @($packageIds | Where-Object { $_ -notin $script:ScopeRepairFailures })

        $snapshot = [ordered]@{
            GeneratedAt          = (Get-Date).ToString('o')
            InstalledPackageIds  = @($packageIds)
        }

        $snapshot | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $snapshotTempFile -Encoding UTF8
        Move-Item -LiteralPath $snapshotTempFile -Destination $DestinationPath -Force
        Write-Log "WinGet inventory staging written to '$DestinationPath' (count=$(@($packageIds).Count))."
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

function Update-InstalledPackagesSnapshot {
    param([AllowEmptyString()][string]$WingetPath, [string]$QueueItemId)

    # Validate ownership/inventory before changing the published snapshot.
    $ownership = @(Get-ArtCraftOwnership)
    $inventory = if ((Test-ArtCraftEnabled) -or $ownership.Count -gt 0) { @(Get-ArtCraftInventory) } else { @() }
    $previous = @()
    if (Test-Path -LiteralPath $InstalledPackagesPath) {
        try {
            $raw = Get-Content -LiteralPath $InstalledPackagesPath -Raw -Encoding UTF8
            if (-not $raw.TrimStart().StartsWith('{')) { throw 'Snapshot root must be an object.' }
            $loaded = $raw | ConvertFrom-Json
            if (-not $loaded.PSObject.Properties['InstalledPackageIds']) { throw 'Snapshot ID list is missing.' }
            $previous = @($loaded.InstalledPackageIds)
        }
        catch {
            $quarantine = Join-Path $BaseDir ('Installed-Packages.corrupt-' + [Guid]::NewGuid().ToString('N') + '.json')
            Move-Item -LiteralPath $InstalledPackagesPath -Destination $quarantine -ErrorAction Stop
            Write-Log "Corrupt installed snapshot quarantined to '$quarantine': $($_.Exception.Message)" 'WARN'
        }
    }
    $wingetRefreshed = $false
    $staging = Join-Path $BaseDir ('winget-snapshot-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if ($WingetPath) {
            $wingetRefreshed = Update-WingetPackagesSnapshot -WingetPath $WingetPath -DestinationPath $staging -QueueItemId $QueueItemId
            if ($wingetRefreshed) {
                $loaded = Get-Content -LiteralPath $staging -Raw -Encoding UTF8 | ConvertFrom-Json
                $previous = @($loaded.InstalledPackageIds)
            }
        }
        $ids = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $previous) {
            if ($id -and -not (Test-ArtCraftManagedPackage -PackageId $id) -and $id -notin $script:ScopeRepairFailures) { [void]$ids.Add($id) }
        }
        foreach ($record in $inventory) { if ($record.Healthy) { [void]$ids.Add($record.PackageId) } }
        $packages = foreach ($definition in Get-ArtCraftDefinitions) {
            $records = @($inventory | Where-Object { $_.PackageId -eq $definition.PackageId })
            $owner = @($ownership | Where-Object { $_.PackageId -eq $definition.PackageId } | Select-Object -First 1)
            if ($records.Count -eq 0 -and $owner.Count -eq 0) { continue }
            $record = @($records | Sort-Object Healthy -Descending | Select-Object -First 1)
            [pscustomobject]@{
                PackageId = $definition.PackageId; Provider = 'ArtCraft'
                Version = if ($record.Count) { [string]$record[0].Version } else { '' }
                Architecture = if ($record.Count) { [string]$record[0].Architecture } else { '' }
                Scope = if ($record.Count) { [string](Get-QueueObjectValue $record[0] 'Scope' '') } else { '' }
                Healthy = ($record.Count -gt 0 -and $record[0].Healthy)
                LatestVersion = if ($owner.Count) { Get-QueueObjectValue $owner[0] 'LatestVersion' '' } else { '' }
                LastCheckedUtc = if ($owner.Count) { Get-QueueObjectValue $owner[0] 'LastCheckedUtc' '' } else { '' }
                LastError = if ($owner.Count) { Get-QueueObjectValue $owner[0] 'LastError' '' } else { '' }
                MetadataStale = if ($owner.Count) { [bool](Get-QueueObjectValue $owner[0] 'MetadataStale' $false) } else { $false }
                RebootRequired = if ($owner.Count) { [bool](Get-QueueObjectValue $owner[0] 'RebootRequired' $false) } else { $false }
            }
        }
        $snapshot = [ordered]@{ GeneratedAt = (Get-Date).ToString('o'); InstalledPackageIds = @($ids | Sort-Object)
            WingetRefreshed = $wingetRefreshed; Packages = @($packages) }
        $temp = "$InstalledPackagesPath.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            $snapshot | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
            if (Test-Path -LiteralPath $InstalledPackagesPath) {
                [IO.File]::Replace($temp, $InstalledPackagesPath, [System.Management.Automation.Language.NullString]::Value)
            }
            else { [IO.File]::Move($temp, $InstalledPackagesPath) }
        }
        finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        Write-Log "Installed package snapshot written to '$InstalledPackagesPath' (count=$($ids.Count), ArtCraft=$(@($inventory | Where-Object Healthy).Count), wingetRefreshed=$wingetRefreshed)."
        return $true
    }
    finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force } }
}

function Get-InstalledPackageIdSet {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path -LiteralPath $InstalledPackagesPath)) {
        return ,$set
    }

    try {
        $raw = Get-Content -LiteralPath $InstalledPackagesPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return ,$set
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

    return ,$set
}

function Invoke-RequiredSoftwarePolicy {
    param([string]$WingetPath)

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

    if ($WingetPath -or (Test-ArtCraftEnabled) -or @(Get-ArtCraftOwnership).Count -gt 0) {
        try {
            Invoke-WithWingetLock -TimeoutSeconds 2 -ScriptBlock {
                $null = Update-InstalledPackagesSnapshot -WingetPath $WingetPath
            } | Out-Null
        }
        catch {
            Write-Log "Could not refresh snapshot before required queueing: $($_.Exception.Message)" 'WARN'
        }
    }

    try {
        $queued = Ensure-RequiredSoftwareQueued -TimeoutSeconds 5
    }
    catch {
        Write-Log "Required software queueing failed: $($_.Exception.Message)" 'WARN'
        throw
    }

    if ($queued -gt 0) {
        [void](Start-QueueWorkerIfAvailable)
    }

    return [pscustomobject]@{ Installed = 0; Failed = 0; Skipped = 0; Queued = $queued }
}

function Reset-RunningQueueItems {
    Ensure-QueueDirectories
    $resetCount = 0

    foreach ($file in @(Get-QueueItemFiles -Directory $QueueRunningDir)) {
        $item = Read-QueueItemFile -Path $file.FullName -DefaultState Running
        if (-not $item) {
            Move-CorruptQueueFileToFailed -Path $file.FullName -Message 'Running queue item could not be read during reset.'
            continue
        }

        $item.State = 'Queued'
        $item.Stage = 'Queued'
        $item.StageText = 'Nach Neustart erneut eingereiht'
        $item.ProgressPercent = $null
        $item.IsIndeterminate = $false
        $item.StartedAt = $null
        $item.FinishedAt = $null
        $item.ExitCode = $null
        $item.Message = ''

        $destination = Get-QueueItemPath -Directory $QueuePendingDir -Id $item.Id
        try {
            Move-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
            [void](Write-QueueItemFile -Item $item -Path $destination -DefaultState Queued)
            $resetCount++
        }
        catch {
            Write-Log "Could not reset running queue item '$($file.FullName)': $($_.Exception.Message)" 'WARN'
        }
    }

    if ($resetCount -gt 0) {
        Write-Log "Reset running queue items count=$resetCount."
    }
    Publish-QueueStateSnapshot
    return $resetCount
}

function Get-NextQueuedItem {
    Ensure-QueueDirectories

    foreach ($file in @(Get-QueueItemFiles -Directory $QueuePendingDir | Sort-Object CreationTimeUtc, Name)) {
        $item = Read-QueueItemFile -Path $file.FullName -DefaultState Queued
        if (-not $item) {
            Move-CorruptQueueFileToFailed -Path $file.FullName -Message 'Pending queue item could not be read.'
            continue
        }

        $runningPath = Get-QueueItemPath -Directory $QueueRunningDir -Id $item.Id
        try {
            Move-Item -LiteralPath $file.FullName -Destination $runningPath -ErrorAction Stop
        }
        catch {
            continue
        }

        $item.State = 'Running'
        $item.Stage = 'Starting'
        $item.StageText = 'Vorbereitung...'
        $item.ProgressPercent = $null
        $item.IsIndeterminate = $true
        $item.StartedAt = (Get-Date).ToString('o')
        $item.FinishedAt = $null
        $item.ExitCode = $null
        $item.Message = ''
        $item = Write-QueueItemFile -Item $item -Path $runningPath -DefaultState Running
        Publish-QueueStateSnapshot
        return $item
    }

    Publish-QueueStateSnapshot
    return $null
}

function Complete-QueueItem {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Succeeded','Failed')][string]$State,
        [int]$ExitCode = 0,
        [string]$Message
    )

    Ensure-QueueDirectories
    $found = Find-QueueItemFile -Id $Id -Directories @($QueueRunningDir, $QueuePendingDir)
    if (-not $found -or -not $found.Item) {
        Write-Log "Could not complete queue item '$Id' because its queue file was not found." 'WARN'
        Publish-QueueStateSnapshot
        return
    }

    $item = $found.Item
    $item.State = $State
    $item.Stage = $State
    $item.StageText = $Message
    $item.ProgressPercent = if ($State -eq 'Succeeded') { 100 } else { $null }
    $item.IsIndeterminate = $false
    $item.FinishedAt = (Get-Date).ToString('o')
    $item.ExitCode = $ExitCode
    $item.Message = $Message

    if ($State -eq 'Succeeded') { $destinationDir = $QueueSucceededDir } else { $destinationDir = $QueueFailedDir }
    $destination = Get-QueueItemPath -Directory $destinationDir -Id $item.Id

    try {
        [void](Write-QueueItemFile -Item $item -Path $destination -DefaultState $State)
        Remove-Item -LiteralPath $found.Path -Force -ErrorAction SilentlyContinue
        Limit-QueueHistory
    }
    catch {
        Write-Log "Could not complete queue item '$Id': $($_.Exception.Message)" 'WARN'
    }

    Publish-QueueStateSnapshot
}

function Invoke-QueuedItem {
    param(
        [Parameter(Mandatory)]$Item,
        [AllowEmptyString()][string]$WingetPath
    )

    if ($Item.Action -eq 'UpgradeAll') {
        $exitCode = Invoke-ArtCraftUpdates
        if ($WingetPath) {
            $wingetCode = Invoke-WingetUpgradeAll -WingetPath $WingetPath -QueueItemId $Item.Id
            if ($wingetCode -ne 0) { $exitCode = $wingetCode }
        }
        $null = Update-InstalledPackagesSnapshot -WingetPath $WingetPath -QueueItemId $Item.Id
        if ($exitCode -in @(0, 3010)) {
            $message = if ($exitCode -eq 3010) { 'Updates abgeschlossen. Neustart erforderlich.' } else { 'Updates abgeschlossen.' }
            Complete-QueueItem -Id $Item.Id -State Succeeded -ExitCode $exitCode -Message $message
        }
        else {
            Complete-QueueItem -Id $Item.Id -State Failed -ExitCode $exitCode -Message "Updates fehlgeschlagen (Code $exitCode)."
        }
        return
    }

    $app = Get-AppCatalogObjectByAlias -Alias ([string]$Item.Alias)
    if (-not $app) {
        Complete-QueueItem -Id $Item.Id -State Failed -ExitCode 1 -Message 'Alias ist nicht mehr freigegeben.'
        return
    }

    $requiredSet = Get-RequiredAliasSet
    if ($Item.Action -eq 'Uninstall' -and $requiredSet.Contains([string]$Item.Alias)) {
        Complete-QueueItem -Id $Item.Id -State Failed -ExitCode 1 -Message 'Pflichtsoftware kann nicht deinstalliert werden.'
        return
    }

    if ($Item.Action -eq 'Install' -and [string]$app.PackageId -in $script:ScopeRepairFailures) {
        throw "SYSTEM-profile repair of '$($app.PackageId)' failed; see service.log."
    }

    $custom = Test-ArtCraftManagedPackage -PackageId $app.PackageId
    $installedSet = Get-InstalledPackageIdSet
    if (-not $custom -and $Item.Action -eq 'Install' -and $installedSet.Contains([string]$app.PackageId)) {
        Complete-QueueItem -Id $Item.Id -State Succeeded -ExitCode 0 -Message 'Bereits installiert.'
        return
    }

    if ($custom) {
        if ($Item.Action -eq 'Install') { $exitCode = Invoke-ArtCraftInstall -PackageId $app.PackageId -QueueItemId $Item.Id }
        else { $exitCode = Invoke-ArtCraftUninstall -PackageId $app.PackageId -QueueItemId $Item.Id }
    }
    elseif (-not $WingetPath) {
        throw 'WinGet ist für dieses Paket nicht verfügbar; ArtCraft bleibt unabhängig nutzbar.'
    }
    elseif ($Item.Action -eq 'Install') {
        $exitCode = Invoke-WingetInstall -WingetPath $WingetPath -PackageId ([string]$app.PackageId) -QueueItemId $Item.Id
    }
    else {
        $exitCode = Invoke-WingetUninstall -WingetPath $WingetPath -PackageId ([string]$app.PackageId) -QueueItemId $Item.Id
    }

    $null = Update-InstalledPackagesSnapshot -WingetPath $WingetPath -QueueItemId $Item.Id
    if ($exitCode -in @(0, 3010)) {
        $message = if ($exitCode -eq 3010) { 'Abgeschlossen. Neustart erforderlich.' } else { 'Abgeschlossen.' }
        Complete-QueueItem -Id $Item.Id -State Succeeded -ExitCode $exitCode -Message $message
    }
    else {
        Complete-QueueItem -Id $Item.Id -State Failed -ExitCode $exitCode -Message "Fehlgeschlagen (Code $exitCode)."
    }
}

function Invoke-ArtCraftLegacyRepairMigration {
    # A previous deployment may have removed a package under the old WinGet
    # repair journal already. Carry that intent into the direct provider too.
    if (-not (Test-Path -LiteralPath $ScopeRepairPath)) { return }
    $raw = Get-Content -LiteralPath $ScopeRepairPath -Raw -Encoding UTF8
    if (-not $raw.TrimStart().StartsWith('[')) { throw 'Invalid legacy scope repair journal root.' }
    $parsed = $raw | ConvertFrom-Json
    $journal = @($parsed)
    foreach ($entry in @($journal)) {
        if (-not (Test-ArtCraftManagedPackage -PackageId $entry.PackageId)) { continue }
        $code = Invoke-ArtCraftInstall -PackageId $entry.PackageId
        if ($code -notin @(0, 3010)) {
            Write-Log "Legacy WinGet repair intent retained for custom provider '$($entry.PackageId)' (code=$code)." 'ERROR'
            $script:ScopeRepairFailures += $entry.PackageId
            continue
        }
        $journal = @($journal | Where-Object { $_.PackageId -ne $entry.PackageId })
        Write-ScopeRepairJournal -Entries $journal
        Write-Log "Legacy WinGet repair intent migrated to ArtCraft provider: '$($entry.PackageId)'."
    }
}

function Invoke-ProcessQueueMode {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir
    Ensure-QueueDirectories

    $wingetPath = Ensure-WingetAvailable
    if (-not $wingetPath) {
        Write-Log 'WinGet unavailable; direct ArtCraft inventory/requests remain enabled.' 'WARN'
    }

    Invoke-WithWingetLock -ScriptBlock {
        [void](Reset-RunningQueueItems)
        # Run before the installed-state shortcut and before upgrade --all.
        # Also resumes durable reinstall intents after an interrupted repair.
        $providerCode = Initialize-ArtCraftProvider
        if ($providerCode -notin @(0, 3010)) { Write-Log "ArtCraft adoption/recovery reported code $providerCode; inspect provider state and service.log." 'ERROR' }
        if ($wingetPath) { Invoke-SystemProfileRepairs -WingetPath $wingetPath }
        Invoke-ArtCraftLegacyRepairMigration
        $null = Update-InstalledPackagesSnapshot -WingetPath $wingetPath
        $null = Ensure-RequiredSoftwareQueued

        while ($true) {
            $item = Get-NextQueuedItem
            if (-not $item) { break }

            Write-Log "Processing queued item id='$($item.Id)' action='$($item.Action)' alias='$($item.Alias)' source='$($item.Source)' requestedBy='$($item.RequestedBy)'"
            try {
                Invoke-QueuedItem -Item $item -WingetPath $wingetPath
            }
            catch {
                Write-Log "Queued item '$($item.Id)' failed: $($_.Exception.Message)" 'ERROR'
                Complete-QueueItem -Id $item.Id -State Failed -ExitCode 1 -Message $_.Exception.Message
            }
        }

        Publish-QueueStateSnapshot
    }
}

function Invoke-UpgradeAllMode {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir

    $item = New-QueueItem -Action UpgradeAll -DisplayName 'Softwareupdates (WinGet + ArtCraft)' -Source System -RequestedBy 'System' -RequestedBySid 'System'
    $result = Add-QueueItem -Item $item -TimeoutSeconds 5

    if ($result.Added) {
        Write-Log 'Queued 2-hour winget upgrade.'
    }
    else {
        Write-Log '2-hour winget upgrade is already queued or running.'
    }

    [void](Start-QueueWorkerIfAvailable)
}

function Invoke-ApplyPolicyMode {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir

    $wingetPath = Ensure-WingetAvailable
    $result = Invoke-RequiredSoftwarePolicy -WingetPath $wingetPath
    Write-Log "Required policy apply queued items=$($result.Queued)."
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

    $result = Add-SoftwareRequestToQueue -Action $RequestAction -Alias $alias -RequestedBy $RequestedBy -RequestedBySid $RequestedBySid -Source User -TimeoutSeconds 5

    Write-Log "Queued worker request action=$RequestAction alias='$alias' added=$($result.Added) RequestedBy='$RequestedBy' Sid='$RequestedBySid'"
    [void](Start-QueueWorkerIfAvailable)
}

function Get-RequestFileOwnerInfo {
    param([Parameter(Mandatory)][string]$Path)

    $ownerName = 'Unknown'
    $ownerSid = $null

    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if ($acl.Owner) {
            $ownerName = [string]$acl.Owner
            try {
                $account = New-Object System.Security.Principal.NTAccount($ownerName)
                $ownerSid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
            catch {
            }
        }
    }
    catch {
        Write-Log "Could not read request file owner '$Path': $($_.Exception.Message)" 'WARN'
    }

    [pscustomobject]@{
        Name = $ownerName
        Sid  = $ownerSid
    }
}

function Assert-RequestJsonDepth {
    param(
        [Parameter(Mandatory)][string]$Raw,
        [int]$MaxDepth = 8
    )

    $depth = 0
    $inString = $false
    $escaped = $false

    for ($i = 0; $i -lt $Raw.Length; $i++) {
        $code = [int][char]$Raw[$i]

        if ($inString) {
            if ($escaped) {
                $escaped = $false
                continue
            }

            if ($code -eq 92) {
                $escaped = $true
                continue
            }

            if ($code -eq 34) {
                $inString = $false
            }
            continue
        }

        if ($code -eq 34) {
            $inString = $true
            continue
        }

        if ($code -eq 123 -or $code -eq 91) {
            $depth++
            if ($depth -gt $MaxDepth) {
                throw "Request JSON nesting exceeds maximum depth $MaxDepth."
            }
            continue
        }

        if ($code -eq 125 -or $code -eq 93) {
            if ($depth -lt 1) {
                throw 'Request JSON has an unexpected closing bracket.'
            }
            $depth--
        }
    }

    if ($inString) {
        throw 'Request JSON string is unterminated.'
    }

    if ($depth -ne 0) {
        throw 'Request JSON is incomplete.'
    }
}

function Get-RequestScalarValue {
    param(
        [Parameter(Mandatory)]$Request,
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$DisplayName,
        [int]$MaxLength = 256
    )

    foreach ($name in $Names) {
        $property = $Request.PSObject.Properties[$name]
        if (-not $property) { continue }

        $value = $property.Value
        if ($null -eq $value) { continue }

        if ($value -is [System.Array] -or $value -is [System.Collections.IDictionary] -or $value -is [pscustomobject]) {
            throw "Request property '$name' must be a scalar value."
        }

        $text = ([string]$value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        if ($text.Length -gt $MaxLength) {
            throw "Request property '$name' is too long ($($text.Length) characters; max=$MaxLength)."
        }

        return $text
    }

    throw "Request is missing $DisplayName."
}

function Move-RequestFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DestinationDir,
        [string]$ErrorMessage
    )

    Ensure-Directory -Path $DestinationDir
    $leaf = Split-Path -Path $Path -Leaf
    $destination = Join-Path $DestinationDir $leaf
    if (Test-Path -LiteralPath $destination) {
        $destination = Join-Path $DestinationDir ("{0}-{1}.json" -f [IO.Path]::GetFileNameWithoutExtension($leaf), [Guid]::NewGuid().ToString('N'))
    }

    Microsoft.PowerShell.Management\Move-Item -LiteralPath $Path -Destination $destination -Force -ErrorAction Stop
    Set-FileAclAdminsOnly -Path $destination

    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $errorPath = $destination + '.error.txt'
        try {
            Microsoft.PowerShell.Management\Set-Content -LiteralPath $errorPath -Value $ErrorMessage -Encoding UTF8 -ErrorAction Stop
            Set-FileAclAdminsOnly -Path $errorPath
        }
        catch {
            Write-Log "Could not write request error file '$errorPath': $($_.Exception.Message)" 'WARN'
        }
    }
}

function Test-IsTransientRequestFailureMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }

    return (
        $Message -like "*$QueueStateMutexName*" -or
        $Message -like "*queue state lock*" -or
        $Message -like "*Aufruftiefe*" -or
        $Message -like "*call depth*" -or
        $Message -like "*recursion*"
    )
}

function Restore-QueueLockFailedRequests {
    Ensure-Directory -Path $RequestsDir
    Ensure-Directory -Path $FailedRequestsDir

    $errorFiles = @(Get-ChildItem -LiteralPath $FailedRequestsDir -Filter '*.json.error.txt' -File -ErrorAction SilentlyContinue)
    foreach ($errorFile in $errorFiles) {
        try {
            $message = Get-Content -LiteralPath $errorFile.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not (Test-IsTransientRequestFailureMessage -Message $message)) { continue }

            $requestName = $errorFile.Name.Substring(0, $errorFile.Name.Length - '.error.txt'.Length)
            $requestPath = Join-Path $FailedRequestsDir $requestName
            if (-not (Test-Path -LiteralPath $requestPath)) { continue }

            $destination = Join-Path $RequestsDir $requestName
            if (Test-Path -LiteralPath $destination) {
                $destination = Join-Path $RequestsDir ("{0}-{1}.json" -f [IO.Path]::GetFileNameWithoutExtension($requestName), [Guid]::NewGuid().ToString('N'))
            }

            Move-Item -LiteralPath $requestPath -Destination $destination -Force -ErrorAction Stop
            Remove-Item -LiteralPath $errorFile.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "Restored failed request '$requestName' for retry after transient queue failure."
        }
        catch {
            Write-Log "Could not restore failed request '$($errorFile.Name)': $($_.Exception.Message)" 'WARN'
        }
    }
}

function Invoke-ProcessRequestsMode {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir
    Ensure-Directory -Path $RequestsDir
    Ensure-Directory -Path $ProcessedRequestsDir
    Ensure-Directory -Path $FailedRequestsDir

    $shouldStartQueue = $false
    $files = @(Get-ChildItem -LiteralPath $RequestsDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc | Select-Object -First 200)

    foreach ($file in $files) {
        try {
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Request file is a reparse point.'
            }

            if ($file.Length -gt 32768) {
                throw "Request file is too large ($($file.Length) bytes)."
            }

            $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            if ([string]::IsNullOrWhiteSpace($raw)) {
                throw 'Request file is empty.'
            }

            Assert-RequestJsonDepth -Raw $raw -MaxDepth 8
            if (-not $raw.TrimStart().StartsWith('{')) { throw 'Request JSON must be an object.' }
            $request = $raw | ConvertFrom-Json
            if ($request -is [System.Array] -or $request -isnot [pscustomobject]) {
                throw 'Request JSON must be an object.'
            }

            $commandValue = Get-RequestScalarValue -Request $request -Names @('Command','Action') -DisplayName 'Command' -MaxLength 32
            $command = $commandValue.Trim().ToLowerInvariant()
            if ($command -in @('refreshstatus','getstatus')) {
                $owner = Get-RequestFileOwnerInfo -Path $file.FullName
                Write-Log "Accepted status refresh request file '$($file.Name)' owner='$($owner.Name)' sid='$($owner.Sid)'."
                Move-RequestFile -Path $file.FullName -DestinationDir $ProcessedRequestsDir
                $shouldStartQueue = $true
                continue
            }

            if ($command -eq 'install') {
                $action = 'Install'
                if (-not (Test-UserInstallsAllowed)) {
                    throw 'Benutzerinstallationen sind per Richtlinie deaktiviert.'
                }
            }
            elseif ($command -eq 'uninstall') {
                $action = 'Uninstall'
                if (-not (Test-UserUninstallAllowed)) {
                    throw 'Benutzerdeinstallationen sind per Richtlinie deaktiviert.'
                }
            }
            else {
                throw "Unsupported request command '$commandValue'."
            }

            $aliasValue = Get-RequestScalarValue -Request $request -Names @('AppAlias','Alias') -DisplayName 'AppAlias' -MaxLength 128
            $alias = $aliasValue.Trim().ToLowerInvariant()
            $owner = Get-RequestFileOwnerInfo -Path $file.FullName
            $result = Add-SoftwareRequestToQueue -Action $action -Alias $alias -RequestedBy $owner.Name -RequestedBySid $owner.Sid -Source User -TimeoutSeconds 5
            Write-Log "Accepted request file '$($file.Name)' action=$action alias='$alias' added=$($result.Added) owner='$($owner.Name)' sid='$($owner.Sid)'."
            Move-RequestFile -Path $file.FullName -DestinationDir $ProcessedRequestsDir
            $shouldStartQueue = $true
        }
        catch {
            $message = $_.Exception.Message
            Write-Log "Rejected request file '$($file.Name)': $message" 'WARN'
            try {
                Move-RequestFile -Path $file.FullName -DestinationDir $FailedRequestsDir -ErrorMessage $message
            }
            catch {
                Write-Log "Could not move failed request file '$($file.FullName)': $($_.Exception.Message)" 'WARN'
            }
        }
    }

    try {
        $requiredQueued = Ensure-RequiredSoftwareQueued -TimeoutSeconds 5
        if ($requiredQueued -gt 0) {
            Write-Log "Queued required software from request worker count=$requiredQueued."
            $shouldStartQueue = $true
        }
    }
    catch {
        Write-Log "Required software queueing deferred because of an error: $($_.Exception.Message)" 'WARN'
    }

    if ($shouldStartQueue) {
        [void](Start-QueueWorkerIfAvailable)
    }
}

function Install-Service {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir
    Ensure-Directory -Path $RequestsDir
    Ensure-Directory -Path $ProcessedRequestsDir
    Ensure-Directory -Path $FailedRequestsDir

    Write-Log "Softwarekatalog build commit: $(Get-SoftwarekatalogBuildCommit)."
    Stop-SoftwarekatalogScheduledTasksForUpdate
    Stop-ObsoleteDaemonProcesses
    Unregister-LegacyQueueTask
    Unregister-ObsoleteDaemonTask
    Restore-QueueLockFailedRequests
    Migrate-LegacyQueueState
    Ensure-QueueDirectories
    Clear-QueueLockOwnerInfo
    try { [void](Reset-RunningQueueItems) }
    catch { Write-Log "Could not reset running queue items during install/update: $($_.Exception.Message)" 'WARN' }
    Publish-QueueStateSnapshot

    Set-DirectoryAcl -Path $BaseDir -UsersCanModify:$false
    $artCraftRoot = Join-Path $BaseDir 'ArtCraft'
    Ensure-Directory -Path $artCraftRoot
    Set-DirectoryAcl -Path $artCraftRoot -UsersCanModify:$false
    Set-DirectoryAcl -Path $LogDir -UsersCanModify:$false
    Set-DirectoryAcl -Path $QueueRootDir -UsersCanModify:$false
    Set-DirectoryAcl -Path $QueuePendingDir -UsersCanModify:$false
    Set-DirectoryAcl -Path $QueueRunningDir -UsersCanModify:$false
    Set-DirectoryAcl -Path $QueueSucceededDir -UsersCanModify:$false
    Set-DirectoryAcl -Path $QueueFailedDir -UsersCanModify:$false
    Set-RequestDirectoryAcl -Path $RequestsDir
    Set-DirectoryAcl -Path $ProcessedRequestsDir -UsersCanModify:$false
    Set-DirectoryAcl -Path $FailedRequestsDir -UsersCanModify:$false

    if (-not $PSCommandPath) {
        throw 'PSCommandPath is empty; cannot determine the source script path.'
    }

    Write-TextFile -Path $LocalScriptPath -Content (Get-BundledSoftwarekatalogSource -Path $PSCommandPath) -Encoding Utf8Bom
    Set-FileAclAdminsOnly -Path $LocalScriptPath

    New-UserRequestTool
    New-CatalogGui
    New-CatalogLauncher
    New-Shortcut -ShortcutPath $DesktopShortcutPath
    New-Shortcut -ShortcutPath $StartMenuShortcutPath
    Register-OrUpdateTasks

    try {
        # Run one inventory/repair pass on deployment even with an empty queue.
        [void](Start-QueueWorkerIfAvailable)
    }
    catch {
        Write-Log "Could not inspect queued work during install/update: $($_.Exception.Message)" 'WARN'
    }

    Write-Log 'Install/update completed successfully.'
}

# ----------------------------
# Entry point
# ----------------------------
try {
    switch ($Mode) {
        'Install'    { Install-Service }
        'UpgradeAll' { Invoke-UpgradeAllMode }
        'ApplyPolicy' { Invoke-ApplyPolicyMode }
        'ProcessQueue' { Invoke-ProcessQueueMode }
        'ProcessRequest' { Invoke-ProcessRequestMode }
        'ProcessRequests' { Invoke-ProcessRequestsMode }
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
