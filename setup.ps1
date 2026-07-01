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
$QueueStatePath         = Join-Path $BaseDir 'Queue-State.json'
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
$UpgradeTaskName        = 'Softwarekatalog - Winget Upgrade'
$WingetMutexName        = 'Global\Softwarekatalog-Winget'
$QueueStateMutexName    = 'Global\Softwarekatalog-QueueState'
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

function New-QueueStateObject {
    [pscustomobject][ordered]@{
        Version = 0
        UpdatedAt = (Get-Date).ToString('o')
        Current = $null
        Queue = @()
    }
}

function Read-QueueState {
    if (-not (Test-Path -LiteralPath $QueueStatePath)) {
        return New-QueueStateObject
    }

    try {
        $raw = Get-Content -LiteralPath $QueueStatePath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return New-QueueStateObject
        }

        $state = $raw | ConvertFrom-Json
        if (-not $state.PSObject.Properties['Version']) { $state | Add-Member -NotePropertyName Version -NotePropertyValue 0 }
        if (-not $state.PSObject.Properties['UpdatedAt']) { $state | Add-Member -NotePropertyName UpdatedAt -NotePropertyValue (Get-Date).ToString('o') }
        if (-not $state.PSObject.Properties['Current']) { $state | Add-Member -NotePropertyName Current -NotePropertyValue $null }
        if (-not $state.PSObject.Properties['Queue']) {
            $state | Add-Member -NotePropertyName Queue -NotePropertyValue @()
        }
        elseif (-not $state.Queue) {
            $state.Queue = @()
        }
        return $state
    }
    catch {
        Write-Log "Failed to read queue state: $($_.Exception.Message)" 'WARN'
        return New-QueueStateObject
    }
}

function Write-QueueState {
    param([Parameter(Mandatory)]$State)

    Ensure-Directory -Path $BaseDir
    $tempPath = Join-Path $BaseDir ("Queue-State-{0}.json.tmp" -f [Guid]::NewGuid().ToString('N'))
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $QueueStatePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WithQueueStateLock {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 30
    )

    $mutex = New-Object System.Threading.Mutex($false, $QueueStateMutexName)
    $hasLock = $false
    try {
        try {
            $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
            Write-Log "Recovered abandoned queue state lock '$QueueStateMutexName'." 'WARN'
        }

        if (-not $hasLock) {
            throw (New-Object System.TimeoutException -ArgumentList "Timed out waiting for queue state lock '$QueueStateMutexName'.")
        }

        & $ScriptBlock
    }
    finally {
        if ($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Update-QueueState {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 30
    )

    Invoke-WithQueueStateLock -ScriptBlock {
        $state = Read-QueueState
        & $ScriptBlock $state
        $state.Version = [int64]$state.Version + 1
        $state.UpdatedAt = (Get-Date).ToString('o')
        Write-QueueState -State $state
        return $state
    } -TimeoutSeconds $TimeoutSeconds
}

function Get-QueueStateSnapshot {
    param([int]$TimeoutSeconds = 30)

    Invoke-WithQueueStateLock -ScriptBlock { Read-QueueState } -TimeoutSeconds $TimeoutSeconds
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
    if (-not $match.Success) { return $null }
    $raw = $match.Groups[1].Value
    $value = [int]$raw
    if ($value -lt 0) { return 0 }
    if ($value -gt 100) { return 100 }
    return $value
}

function Update-QueueItemProgress {
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Stage = 'Running',
        [string]$StageText = 'Aktion läuft...',
        [Nullable[int]]$ProgressPercent,
        [bool]$IsIndeterminate = $true
    )

    $null = Update-QueueState -ScriptBlock {
        param($state)
        foreach ($item in @($state.Queue)) {
            if (-not $item) { continue }
            if ($item.Id -eq $Id) {
                $item.Stage = $Stage
                $item.StageText = $StageText
                $item.ProgressPercent = $ProgressPercent
                $item.IsIndeterminate = $IsIndeterminate
                $state.Current = [pscustomobject][ordered]@{
                    Id = $item.Id
                    Action = $item.Action
                    Alias = $item.Alias
                    DisplayName = $item.DisplayName
                    Stage = $Stage
                    StageText = $StageText
                    ProgressPercent = $ProgressPercent
                    IsIndeterminate = $IsIndeterminate
                }
                break
            }
        }
    }
}

function Get-RequiredAliasSet {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($alias in @(Get-RequiredAliases)) {
        if (-not [string]::IsNullOrWhiteSpace($alias)) {
            [void]$set.Add([string]$alias)
        }
    }
    return $set
}

function Add-QueueItem {
    param(
        [Parameter(Mandatory)]$Item,
        [int]$TimeoutSeconds = 30
    )

    $result = $null
    $null = Update-QueueState -ScriptBlock {
        param($state)
        $queue = @($state.Queue)

        foreach ($existing in $queue) {
            if (-not $existing) { continue }
            if ($existing.State -in @('Queued','Running') -and $existing.Action -eq $Item.Action -and [string]::Equals([string]$existing.Alias, [string]$Item.Alias, [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:QueueAddResult = [pscustomobject]@{ Added = $false; Item = $existing }
                return
            }
        }

        $state.Queue = @($queue + $Item)
        $script:QueueAddResult = [pscustomobject]@{ Added = $true; Item = $Item }
    } -TimeoutSeconds $TimeoutSeconds

    $result = $script:QueueAddResult
    $script:QueueAddResult = $null
    return $result
}

function Add-SoftwareRequestToQueue {
    param(
        [Parameter(Mandatory)][ValidateSet('Install','Uninstall')][string]$Action,
        [Parameter(Mandatory)][string]$Alias,
        [string]$RequestedBy,
        [string]$RequestedBySid,
        [ValidateSet('User','Required')][string]$Source = 'User'
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

    return Add-QueueItem -Item $item
}

function Ensure-RequiredSoftwareQueued {
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

        $result = Add-SoftwareRequestToQueue -Action Install -Alias $alias -RequestedBy 'Policy' -RequestedBySid 'Policy' -Source Required
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
    Start-SoftwarekatalogWorker -WorkerMode ProcessQueue
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
    $requestsLiteral = $RequestsDir.Replace("'", "''")
    $policyRootLiteral = $PolicyRoot.Replace("'", "''")
    $policyCatalogLiteral = $PolicyCatalogRoot.Replace("'", "''")
    $policyMaxEntriesLiteral = $PolicyMaxEntries

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

function Get-AppCatalogObjects {
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
    @(Get-AppCatalogObjects) | Sort-Object DisplayName | ForEach-Object {
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
                Catalog = @(Get-AppCatalogObjects | Sort-Object DisplayName)
                RequiredAliases = @(Get-RequiredAliases)
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

function Get-AppCatalogObjects {
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

`$script:StateWatcher = `$null
`$script:SnapshotWatcher = `$null
`$stateRefreshTimer = New-Object System.Windows.Forms.Timer
`$stateRefreshTimer.Interval = 500
`$script:StateRefreshPending = `$false
`$script:RequestWorkerBusy = `$false

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
    if (-not `$script:StateRefreshPending) { return }
    if (`$script:RequestWorkerBusy) { return }
    `$script:StateRefreshPending = `$false
    try { Load-AppList }
    catch { `$status.Text = "Fehler bei automatischer Aktualisierung: " + `$_.Exception.Message }
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
    try {
        `$stateDir = Split-Path -Path `$QueueStatePath -Parent
        `$stateFile = Split-Path -Path `$QueueStatePath -Leaf
        if (Test-Path -LiteralPath `$stateDir) {
            `$script:StateWatcher = New-Object System.IO.FileSystemWatcher(`$stateDir, `$stateFile)
            `$script:StateWatcher.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, FileName, Size'
            `$script:StateWatcher.Add_Changed({ `$script:StateRefreshPending = `$true })
            `$script:StateWatcher.Add_Created({ `$script:StateRefreshPending = `$true })
            `$script:StateWatcher.Add_Renamed({ `$script:StateRefreshPending = `$true })
            `$script:StateWatcher.EnableRaisingEvents = `$true
        }
    }
    catch {
        `$status.Text = "Statusueberwachung konnte nicht gestartet werden: " + `$_.Exception.Message
    }

    try {
        `$snapshotDir = Split-Path -Path `$InstalledPackagesPath -Parent
        `$snapshotFile = Split-Path -Path `$InstalledPackagesPath -Leaf
        if (Test-Path -LiteralPath `$snapshotDir) {
            `$script:SnapshotWatcher = New-Object System.IO.FileSystemWatcher(`$snapshotDir, `$snapshotFile)
            `$script:SnapshotWatcher.NotifyFilter = [System.IO.NotifyFilters]'LastWrite, FileName, Size'
            `$script:SnapshotWatcher.Add_Changed({ `$script:StateRefreshPending = `$true })
            `$script:SnapshotWatcher.Add_Created({ `$script:StateRefreshPending = `$true })
            `$script:SnapshotWatcher.Add_Renamed({ `$script:StateRefreshPending = `$true })
            `$script:SnapshotWatcher.EnableRaisingEvents = `$true
        }
    }
    catch {
        `$status.Text = "Snapshotueberwachung konnte nicht gestartet werden: " + `$_.Exception.Message
    }
    `$stateRefreshTimer.Start()
})
`$form.Add_FormClosing({
    `$stateRefreshTimer.Stop()
    `$stateRefreshTimer.Dispose()
    if (`$null -ne `$script:StateWatcher) { `$script:StateWatcher.Dispose() }
    if (`$null -ne `$script:SnapshotWatcher) { `$script:SnapshotWatcher.Dispose() }
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

function Stop-ObsoleteDaemonProcesses {
    $daemonMarkers = @(
        '-Mode Daemon',
        '-Mode "Daemon"',
        "-Mode 'Daemon'",
        'Mode=Daemon',
        'NamedPipe',
        'Named pipe',
        '\\.\pipe\Softwarekatalog'
    )

    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
    }
    catch {
        Write-Log "Could not enumerate processes for obsolete daemon cleanup: $($_.Exception.Message)" 'WARN'
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

        $hasDaemonMarker = $false
        foreach ($marker in $daemonMarkers) {
            if ($commandLine.IndexOf($marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $hasDaemonMarker = $true
                break
            }
        }
        if (-not $hasDaemonMarker) { continue }

        try {
            Write-Log "Stopping obsolete daemon process pid=$($process.ProcessId)."
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
        }
        catch {
            Write-Log "Could not stop obsolete daemon process pid=$($process.ProcessId): $($_.Exception.Message)" 'WARN'
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

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [Parameter(Mandatory)][string]$PackageId,
        [string]$QueueItemId
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
    if ($QueueItemId) {
        Update-QueueItemProgress -Id $QueueItemId -Stage 'Install' -StageText 'Installation läuft...' -IsIndeterminate:$true
    }

    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    & $WingetPath @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        [void]$outputLines.Add($line)
        if ($line.Trim()) {
            Write-Log "winget: $line"
            if ($QueueItemId) {
                $percent = Get-ProgressPercentFromLine -Line $line
                if ($null -ne $percent) {
                    Update-QueueItemProgress -Id $QueueItemId -Stage 'Download' -StageText ("Download läuft... {0}%" -f $percent) -ProgressPercent $percent -IsIndeterminate:$false
                }
            }
        }
    }
    $exitCode = $LASTEXITCODE

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

    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    & $WingetPath @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        [void]$outputLines.Add($line)
        if ($line.Trim()) {
            Write-Log "winget: $line"
            if ($QueueItemId) {
                $percent = Get-ProgressPercentFromLine -Line $line
                if ($null -ne $percent) {
                    Update-QueueItemProgress -Id $QueueItemId -Stage 'Uninstall' -StageText ("Deinstallation läuft... {0}%" -f $percent) -ProgressPercent $percent -IsIndeterminate:$false
                }
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
    if ($QueueItemId) {
        Update-QueueItemProgress -Id $QueueItemId -Stage 'Upgrade' -StageText 'Updates laufen...' -IsIndeterminate:$true
    }

    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    & $WingetPath @arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        [void]$outputLines.Add($line)
        if ($line.Trim()) {
            Write-Log "winget upgrade: $line"
            if ($QueueItemId) {
                $percent = Get-ProgressPercentFromLine -Line $line
                if ($null -ne $percent) {
                    Update-QueueItemProgress -Id $QueueItemId -Stage 'Upgrade' -StageText ("Updates laufen... {0}%" -f $percent) -ProgressPercent $percent -IsIndeterminate:$false
                }
            }
        }
    }
    $exitCode = $LASTEXITCODE

    return $exitCode
}

function Update-InstalledPackagesSnapshot {
    param(
        [Parameter(Mandatory)][string]$WingetPath,
        [string]$QueueItemId
    )

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
    if ($QueueItemId) {
        Update-QueueItemProgress -Id $QueueItemId -Stage 'Snapshot' -StageText 'Installationsdaten werden aktualisiert...' -IsIndeterminate:$true
    }
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

    if ($WingetPath) {
        try {
            Invoke-WithWingetLock -TimeoutSeconds 2 -ScriptBlock {
                $null = Update-InstalledPackagesSnapshot -WingetPath $WingetPath
            } | Out-Null
        }
        catch {
            Write-Log "Could not refresh snapshot before required queueing: $($_.Exception.Message)" 'WARN'
        }
    }

    $queued = Ensure-RequiredSoftwareQueued
    if ($queued -gt 0) {
        Start-QueueWorker
    }

    return [pscustomobject]@{ Installed = 0; Failed = 0; Skipped = 0; Queued = $queued }
}

function Reset-RunningQueueItems {
    $null = Update-QueueState -ScriptBlock {
        param($state)
        foreach ($item in @($state.Queue)) {
            if (-not $item) { continue }
            if ($item.State -eq 'Running') {
                $item.State = 'Queued'
                $item.Stage = 'Queued'
                $item.StageText = 'Nach Neustart erneut eingereiht'
                $item.ProgressPercent = $null
                $item.IsIndeterminate = $false
                $item.StartedAt = $null
            }
        }
        $state.Current = $null
    }
}

function Get-NextQueuedItem {
    $script:NextQueueItem = $null
    $null = Update-QueueState -ScriptBlock {
        param($state)
        foreach ($item in (@($state.Queue) | Sort-Object CreatedAt)) {
            if (-not $item) { continue }
            if ($item.State -eq 'Queued') {
                $item.State = 'Running'
                $item.Stage = 'Starting'
                $item.StageText = 'Vorbereitung...'
                $item.ProgressPercent = $null
                $item.IsIndeterminate = $true
                $item.StartedAt = (Get-Date).ToString('o')
                $state.Current = [pscustomobject][ordered]@{
                    Id = $item.Id
                    Action = $item.Action
                    Alias = $item.Alias
                    DisplayName = $item.DisplayName
                    Stage = $item.Stage
                    StageText = $item.StageText
                    ProgressPercent = $item.ProgressPercent
                    IsIndeterminate = $item.IsIndeterminate
                }
                $script:NextQueueItem = $item
                break
            }
        }
    }

    $item = $script:NextQueueItem
    $script:NextQueueItem = $null
    return $item
}

function Complete-QueueItem {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Succeeded','Failed')][string]$State,
        [int]$ExitCode = 0,
        [string]$Message
    )

    $null = Update-QueueState -ScriptBlock {
        param($queueState)
        foreach ($item in @($queueState.Queue)) {
            if (-not $item) { continue }
            if ($item.Id -eq $Id) {
                $item.State = $State
                $item.Stage = $State
                $item.StageText = $Message
                $item.ProgressPercent = if ($State -eq 'Succeeded') { 100 } else { $null }
                $item.IsIndeterminate = $false
                $item.FinishedAt = (Get-Date).ToString('o')
                $item.ExitCode = $ExitCode
                $item.Message = $Message
                break
            }
        }
        $queueState.Current = $null
    }
}

function Invoke-QueuedItem {
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][string]$WingetPath
    )

    if ($Item.Action -eq 'UpgradeAll') {
        $exitCode = Invoke-WingetUpgradeAll -WingetPath $WingetPath -QueueItemId $Item.Id
        $null = Update-InstalledPackagesSnapshot -WingetPath $WingetPath -QueueItemId $Item.Id
        if ($exitCode -eq 0) {
            Complete-QueueItem -Id $Item.Id -State Succeeded -ExitCode $exitCode -Message 'Updates abgeschlossen.'
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

    $installedSet = Get-InstalledPackageIdSet
    if ($Item.Action -eq 'Install' -and $installedSet.Contains([string]$app.PackageId)) {
        Complete-QueueItem -Id $Item.Id -State Succeeded -ExitCode 0 -Message 'Bereits installiert.'
        return
    }

    if ($Item.Action -eq 'Install') {
        $exitCode = Invoke-WingetInstall -WingetPath $WingetPath -PackageId ([string]$app.PackageId) -QueueItemId $Item.Id
    }
    else {
        $exitCode = Invoke-WingetUninstall -WingetPath $WingetPath -PackageId ([string]$app.PackageId) -QueueItemId $Item.Id
    }

    $null = Update-InstalledPackagesSnapshot -WingetPath $WingetPath -QueueItemId $Item.Id
    if ($exitCode -eq 0) {
        Complete-QueueItem -Id $Item.Id -State Succeeded -ExitCode $exitCode -Message 'Abgeschlossen.'
    }
    else {
        Complete-QueueItem -Id $Item.Id -State Failed -ExitCode $exitCode -Message "Fehlgeschlagen (Code $exitCode)."
    }
}

function Invoke-ProcessQueueMode {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir

    $wingetPath = Ensure-WingetAvailable
    if (-not $wingetPath) {
        Write-Log 'Aborting queue processing because winget is unavailable.' 'ERROR'
        return
    }

    Invoke-WithWingetLock -ScriptBlock {
        Reset-RunningQueueItems
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

        $null = Update-QueueState -ScriptBlock { param($state) $state.Current = $null }
    }
}

function Invoke-UpgradeAllMode {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir

    $item = New-QueueItem -Action UpgradeAll -DisplayName 'winget upgrade --all' -Source System -RequestedBy 'System' -RequestedBySid 'System'
    try {
        $result = Add-QueueItem -Item $item -TimeoutSeconds 5
    }
    catch [System.TimeoutException] {
        Write-Log "Skipped 2-hour winget upgrade queueing because the queue state lock is busy: $($_.Exception.Message)" 'WARN'
        return
    }

    if ($result.Added) {
        Write-Log 'Queued 2-hour winget upgrade.'
    }
    else {
        Write-Log '2-hour winget upgrade is already queued or running.'
    }

    if (Test-WingetLockAvailable) {
        Start-QueueWorker
    }
    else {
        Write-Log 'Queue worker not started because winget lock is already held; queued upgrade will be processed by the active worker.'
    }
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

    $result = Add-SoftwareRequestToQueue -Action $RequestAction -Alias $alias -RequestedBy $RequestedBy -RequestedBySid $RequestedBySid -Source User
    Write-Log "Queued worker request action=$RequestAction alias='$alias' added=$($result.Added) RequestedBy='$RequestedBy' Sid='$RequestedBySid'"
    Start-QueueWorker
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
            $result = Add-SoftwareRequestToQueue -Action $action -Alias $alias -RequestedBy $owner.Name -RequestedBySid $owner.Sid -Source User
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

    $requiredQueued = Ensure-RequiredSoftwareQueued
    if ($requiredQueued -gt 0) {
        Write-Log "Queued required software from request worker count=$requiredQueued."
        $shouldStartQueue = $true
    }

    foreach ($queuedItem in @((Get-QueueStateSnapshot).Queue)) {
        if ($queuedItem -and $queuedItem.State -eq 'Queued') {
            $shouldStartQueue = $true
            break
        }
    }

    if ($shouldStartQueue) {
        if (Test-WingetLockAvailable) {
            Start-QueueWorker
        }
        else {
            Write-Log 'Queue worker not started because winget lock is already held.'
        }
    }
}

function Install-Service {
    Ensure-Directory -Path $BaseDir
    Ensure-Directory -Path $LogDir
    Ensure-Directory -Path $RequestsDir
    Ensure-Directory -Path $ProcessedRequestsDir
    Ensure-Directory -Path $FailedRequestsDir

    Unregister-LegacyQueueTask
    Unregister-ObsoleteDaemonTask
    Stop-ObsoleteDaemonProcesses

    Set-DirectoryAcl -Path $BaseDir -UsersCanModify:$false
    Set-DirectoryAcl -Path $LogDir -UsersCanModify:$false
    Set-RequestDirectoryAcl -Path $RequestsDir
    Set-DirectoryAcl -Path $ProcessedRequestsDir -UsersCanModify:$false
    Set-DirectoryAcl -Path $FailedRequestsDir -UsersCanModify:$false

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
