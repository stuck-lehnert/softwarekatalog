# Dependency-free regression tests for Windows PowerShell 5.1 and PowerShell 7.
# Only top-level production functions are loaded; setup configuration/entry point
# and generated GUI/helper scripts are never executed. No administrator required.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'setup.ps1'
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path (Split-Path $sourcePath -Parent) 'modules/ArtCraft.Catalog.ps1'), [Text.Encoding]::UTF8)))
. ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path (Split-Path $sourcePath -Parent) 'modules/ArtCraft.Provider.ps1'), [Text.Encoding]::UTF8)))
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}

. (Join-Path $PSScriptRoot 'helpers/PortableFileSystem.ps1')

$script:passed = 0
$script:failures = @()
$script:tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('catalog-core-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:tempRoot | Out-Null

function Assert($Condition, [string]$Message = 'Assertion failed') {
    if (-not $Condition) { throw $Message }
}
function Assert-Equal($Actual, $Expected, [string]$Message = 'Values differ') {
    if ($Actual -cne $Expected) { throw "$Message. Expected=<$Expected>; actual=<$Actual>." }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body | Out-Null }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected exception matching '$Pattern'."
}
function Read-Json([string]$Path) {
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Get-JsonCount([string]$Directory) { @(Get-QueueItemFiles -Directory $Directory).Count }
function New-TestItem([string]$Alias = 'app', [string]$Action = 'Install') {
    New-QueueItem -Action $Action -Alias $Alias -PackageId ('Vendor.' + $Alias) -DisplayName $Alias -RequestedBy 'Test user' -RequestedBySid 'S-1-5-21-test'
}
function Write-TestRequest([string]$Name, [string]$Raw) {
    Ensure-Directory -Path $script:RequestsDir
    $path = Join-Path $script:RequestsDir $Name
    Set-Content -LiteralPath $path -Value $Raw -Encoding UTF8
    return $path
}

# Registry is the only policy boundary replaced. Production policy readers,
# parsers, defaults and allowlist/Required checks all run unmodified. Real
# directories make Test-Path meaningful without a fake Registry provider.
function New-TestRegistryKey($Values) {
    $key = [pscustomobject]@{ Values = $Values }
    $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value { @($this.Values.Keys) }
    $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value {
        param($Name, $Default)
        if ($this.Values.Contains($Name)) { return $this.Values[$Name] }
        return $Default
    }
    return $key
}
function Get-Item {
    [CmdletBinding()]
    param([string]$LiteralPath)
    if ($LiteralPath -eq $script:PolicyCatalogRoot) { return (New-TestRegistryKey $script:catalogValues) }
    if ($LiteralPath -eq $script:PolicyRequiredRoot) { return (New-TestRegistryKey $script:requiredValues) }
    Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
}
function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$LiteralPath)
    if ($LiteralPath -eq $script:PolicyRoot) { return [pscustomobject]$script:policyDwords }
    Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters
}
# The portable suite cannot set Windows ACLs, discover NT account ownership or
# start a scheduled task. These boundary doubles record calls and do not replace
# any request validation, queue operation, JSON serializer or filesystem move.
function Set-FileAclAdminsOnly {
    param([string]$Path)
    Assert (Test-Path -LiteralPath $Path) 'ACL operation must follow the real file move/write'
    $script:aclPaths += $Path
}
function Get-RequestFileOwnerInfo {
    param([string]$Path, [IO.FileStream]$Stream)
    Assert (Test-Path -LiteralPath $Path) 'Owner lookup must use an existing request'
    $script:ownerPaths += $Path
    [pscustomobject]@{ Name = 'DOMAIN\ActualOwner'; Sid = 'S-1-5-21-123-456-789-1001'; SafeForInstall = $true }
}
function Test-ServerOperatingSystem { return $false } # OS boundary; covered separately by server authorization tests.
function Start-QueueWorkerIfAvailable { $script:workerStarts++; return $true }

function Test([string]$Name, [scriptblock]$Body) {
    $script:BaseDir = Join-Path $script:tempRoot ([Guid]::NewGuid().ToString('N'))
    $script:QueueRootDir = Join-Path $script:BaseDir 'Queue'
    $script:QueuePendingDir = Join-Path $script:QueueRootDir 'Pending'
    $script:QueueRunningDir = Join-Path $script:QueueRootDir 'Running'
    $script:QueueSucceededDir = Join-Path $script:QueueRootDir 'Succeeded'
    $script:QueueFailedDir = Join-Path $script:QueueRootDir 'Failed'
    $script:QueueStatePath = Join-Path $script:BaseDir 'Queue-State.json'
    $script:QueueCompletedRetention = 100
    $script:QueueProgressThrottle = @{}
    $script:ScopeRepairFailures = @()
    $script:RequestsDir = Join-Path $script:BaseDir 'Requests'
    $script:ProcessedRequestsDir = Join-Path $script:BaseDir 'Processed'
    $script:FailedRequestsDir = Join-Path $script:BaseDir 'Failed'
    $script:InstalledPackagesPath = Join-Path $script:BaseDir 'Installed-Packages.json'
    $script:LogDir = Join-Path $script:BaseDir 'Logs'
    $script:LogFile = Join-Path $script:LogDir 'service.log'
    $script:PolicyRoot = Join-Path $script:BaseDir 'Policy'
    $script:PolicyCatalogRoot = Join-Path $script:PolicyRoot 'Catalog'
    $script:PolicyRequiredRoot = Join-Path $script:PolicyRoot 'Required'
    $script:PolicyMaxEntries = 500
    $script:QueueStateMutexName = 'CoreTests-Queue-State'
    $script:policyDwords = [ordered]@{ Enabled = 1; AllowUserInstalls = 1; AllowUserUninstall = 1; EnforceRequired = 1 }
    $script:catalogValues = [ordered]@{ app = 'Vendor.App|An application|Description'; other = 'Vendor.Other|Other application' }
    $script:requiredValues = [ordered]@{}
    $script:aclPaths = @()
    $script:ownerPaths = @()
    $script:workerStarts = 0
    foreach ($path in @($script:BaseDir, $script:LogDir, $script:PolicyCatalogRoot, $script:PolicyRequiredRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    try {
        & $Body | Out-Null
        $script:passed++
        Write-Output "PASS $Name"
    }
    catch {
        $script:failures += "$Name`: $($_.Exception.Message)"
        Write-Output "FAIL $Name`: $($_.Exception.Message)"
        Write-Output $_.ScriptStackTrace
    }
}

try {
    Test 'Policy DWORD defaults fail closed for Enabled and preserve independent user defaults' {
        $script:policyDwords = [ordered]@{}
        Assert (-not (Test-SoftwareCatalogPolicyEnabled))
        Assert (Test-UserInstallsAllowed)
        Assert (Test-UserUninstallAllowed)
        Assert (Test-RequiredEnforcementEnabled)
        $script:policyDwords.Enabled = 'invalid integer'
        Assert (-not (Test-SoftwareCatalogPolicyEnabled))
        $script:policyDwords.Enabled = 1
        $script:policyDwords.AllowUserInstalls = 0
        $script:policyDwords.AllowUserUninstall = 0
        $script:policyDwords.EnforceRequired = 0
        Assert (Test-SoftwareCatalogPolicyEnabled)
        Assert (-not (Test-UserInstallsAllowed))
        Assert (-not (Test-UserUninstallAllowed))
        Assert (-not (Test-RequiredEnforcementEnabled))
        Remove-Item -LiteralPath $script:PolicyRoot -Recurse -Force
        Assert-Equal (Get-PolicyDword -Name Enabled -Default 27) 27
    }
    Test 'Registry list filters default/deletion/blank values, sorts and caps before parsing' {
        $script:catalogValues = [ordered]@{ z = ' last '; '' = 'default'; '*delete' = 'discard'; b = ' second '; a = ' first '; c = '   ' }
        $rows = @(Get-PolicyStringValues -Path $script:PolicyCatalogRoot)
        Assert-Equal ($rows.Name -join ',') 'a,b,z'
        Assert-Equal ($rows.Value -join ',') 'first,second,last'
        $script:PolicyMaxEntries = 2
        $rows = @(Get-PolicyStringValues -Path $script:PolicyCatalogRoot)
        Assert-Equal ($rows.Name -join ',') 'a,b'
        Assert-Equal (@(Get-PolicyStringValues -Path (Join-Path $script:PolicyRoot 'Missing')).Count) 0
    }
    Test 'Catalog normalizes aliases, deduplicates, rejects malformed rows and preserves description pipes' {
        $script:catalogValues = [ordered]@{
            ' App ' = ' Vendor.App | Friendly label | description | more '
            app = 'Malicious.Replacement|Duplicate'
            fallback = 'Vendor.Fallback|   '
            malformed = 'No pipe'
            emptyid = ' |No package'
            '   ' = 'Vendor.Empty|Empty alias'
        }
        $apps = @(Get-AppCatalogObjects)
        Assert-Equal $apps.Count 2
        $app = Get-AppCatalogObjectByAlias 'APP'
        Assert-Equal $app.Alias 'app'
        Assert-Equal $app.PackageId 'Vendor.App'
        Assert-Equal $app.DisplayName 'Friendly label'
        Assert-Equal $app.Description 'description | more'
        Assert-Equal (Get-AppCatalogObjectByAlias fallback).DisplayName 'fallback'
        Assert-Equal (Get-PackageIdByAlias 'aPp') 'Vendor.App'
        Assert ($null -eq (Get-AppCatalogObjectByAlias 'app*')) 'Alias lookup is exact, not a wildcard'
        Assert ($null -eq (Get-PackageIdByAlias 'unknown'))
    }
    Test 'Disabled catalog exposes neither allowlist nor Required aliases and queues nothing' {
        $script:requiredValues.app = '1'
        $script:policyDwords.Enabled = 0
        Assert-Equal (@(Get-AppCatalogObjects).Count) 0
        Assert-Equal (@(Get-RequiredAliases).Count) 0
        Assert-Equal (Ensure-RequiredSoftwareQueued) 0
        Assert-Throws { Add-SoftwareRequestToQueue Install app } 'allowlist'
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
    }
    Test 'Required aliases normalize, deduplicate and recognize false/zero flags' {
        $script:requiredValues = [ordered]@{ ' APP ' = '1'; app = 'true'; other = 'FALSE'; zero = '0'; enabled = 'anything'; ' ' = '1' }
        Assert-Equal ((@(Get-RequiredAliases) | Sort-Object) -join ',') 'app,enabled'
        $set = Get-RequiredAliasSet
        Assert ($set.Contains('APP'))
        Assert (-not $set.Contains('other'))
    }
    Test 'Allowlist lookup normalizes user aliases and Required uninstall is rejected before any write' {
        $script:requiredValues.app = '1'
        Assert-Throws { Add-SoftwareRequestToQueue Uninstall ' APP ' } 'Pflichtsoftware'
        Assert-Throws { Add-SoftwareRequestToQueue Install 'Vendor.App' } 'allowlist'
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
        $result = Add-SoftwareRequestToQueue Install ' APP ' -RequestedBy alice -RequestedBySid sid
        Assert $result.Added
        Assert-Equal $result.Item.Alias 'app'
        Assert-Equal $result.Item.PackageId 'Vendor.App'
        Assert-Equal $result.Item.DisplayName 'An application'
        Assert $result.Item.Required
        Assert-Equal $result.Item.RequestedBy 'alice'
        Assert-Equal $result.Item.RequestedBySid 'sid'
    }
    Test 'Required queueing uses actual installed snapshot and remains idempotent' {
        $script:requiredValues = [ordered]@{ app = '1'; other = '1'; missing = '1' }
        Write-JsonFileAtomic -Path $script:InstalledPackagesPath -Value ([pscustomobject]@{ InstalledPackageIds = @(' vendor.APP ', 'VENDOR.APP', '') })
        $installed = Get-InstalledPackageIdSet
        Assert-Equal $installed.Count 1
        Assert ($installed.Contains('Vendor.App'))
        Assert-Equal (Ensure-RequiredSoftwareQueued) 1
        Assert-Equal (Ensure-RequiredSoftwareQueued) 0
        $items = @(Get-QueueItemsInDirectory $script:QueuePendingDir)
        Assert-Equal $items.Count 1
        Assert-Equal $items[0].Alias 'other'
        Assert-Equal $items[0].Source 'Required'
        Assert $items[0].Required
        Assert-Equal $items[0].RequestedBy 'Policy'
        $script:policyDwords.EnforceRequired = 0
        Remove-Item -LiteralPath (Get-QueueItemPath $script:QueuePendingDir $items[0].Id)
        Assert-Equal (Ensure-RequiredSoftwareQueued) 0
    }
    Test 'Installed snapshot reader tolerates absent, empty and corrupt JSON without inventing IDs' {
        Assert-Equal (Get-InstalledPackageIdSet).Count 0
        foreach ($raw in @('', '{broken', '{}', 'null', '[]')) {
            Set-Content -LiteralPath $script:InstalledPackagesPath -Value $raw -Encoding UTF8
            Assert-Equal (Get-InstalledPackageIdSet).Count 0 "Snapshot '$raw'"
        }
    }
    Test 'Queue input ValidateSet rejects unsupported actions/sources without files' {
        Assert-Throws { New-QueueItem -Action 'Execute' } 'Execute'
        Assert-Throws { Add-SoftwareRequestToQueue -Action Install -Alias app -Source System } 'System'
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
    }
    Test 'Queue record normalization supplies defaults and clamps unsafe progress values' {
        $record = ConvertTo-QueueItemRecord -Item ([pscustomobject]@{ State = 'invalid'; Required = 'false'; ProgressPercent = 101; IsIndeterminate = '0'; CreatedAt = 'invalid'; StartedAt = 'invalid' }) -DefaultState Running
        Assert ($record.Id -match '^[a-f0-9]{32}$')
        Assert-Equal $record.State 'Running'
        Assert (-not $record.Required)
        Assert (-not $record.IsIndeterminate)
        Assert-Equal $record.ProgressPercent 100
        Assert ([string]::IsNullOrWhiteSpace($record.StartedAt))
        Assert ([DateTime]::Parse($record.CreatedAt) -gt [DateTime]::MinValue)
        Assert-Equal (ConvertTo-QueueNullableInt -Value -5) 0
        Assert ($null -eq (ConvertTo-QueueNullableInt 'not a number'))
        Assert (ConvertTo-QueueBool 'JA')
        Assert (-not (ConvertTo-QueueBool 'nein'))
    }
    Test 'Queue item IDs cannot escape their directory through separators or shell characters' {
        Ensure-QueueDirectories
        foreach ($id in @('../outside-one', '..\outside-two', 'a/b\c:*?[]', '$(Write-Output nope)', '"quoted"')) {
            $item = New-TestItem
            $item.Id = $id
            $record = Write-QueueItemFile -Item $item -Directory $script:QueuePendingDir
            $path = Get-QueueItemPath $script:QueuePendingDir $id
            Assert (Test-Path -LiteralPath $path)
            Assert-Equal ([IO.Path]::GetDirectoryName($path)) $script:QueuePendingDir
            Assert-Equal (Read-QueueItemFile $path).Id $id
            Assert ((Split-Path -Leaf $path) -match '^[A-Za-z0-9._-]+\.json$')
        }
        # Include dot-prefixed names on Unix too; Windows does not hide them.
        Assert-Equal ([IO.Directory]::GetFiles($script:QueuePendingDir, '*.json').Length) 5
    }
    Test 'Atomic JSON writes replace valid snapshots and remove temporary files on success/failure' {
        $path = Join-Path $script:BaseDir 'nested/state.json'
        Write-JsonFileAtomic -Path $path -Value ([pscustomobject]@{ Version = 1; Text = 'literal $(not executable)' })
        Write-JsonFileAtomic -Path $path -Value ([pscustomobject]@{ Version = 2; Nested = [pscustomobject]@{ Value = 'new' } })
        Assert-Equal (Read-Json $path).Version 2
        Assert-Equal (Read-Json $path).Nested.Value 'new'
        Assert-Throws { Write-JsonFileAtomic -Path $path -Value ([pscustomobject]@{ Version = 3 }) -Depth -1 } 'Depth|range|greater than'
        Assert-Equal (Read-Json $path).Version 2
        Assert-Equal (@(Get-ChildItem -LiteralPath (Split-Path $path -Parent) -Filter '*.tmp').Count) 0
    }
    Test 'Add deduplicates pending and running action/alias case-insensitively but permits opposite actions' {
        $first = Add-QueueItem (New-TestItem app)
        $duplicate = Add-QueueItem (New-TestItem APP)
        Assert $first.Added
        Assert (-not $duplicate.Added)
        Assert-Equal $duplicate.Item.Id $first.Item.Id
        $running = Get-NextQueuedItem
        Assert-Equal $running.Id $first.Item.Id
        Assert (-not (Add-QueueItem (New-TestItem App)).Added)
        Assert (Add-QueueItem (New-TestItem app Uninstall)).Added
        Assert-Equal (Get-JsonCount $script:QueueRunningDir) 1
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 1
    }
    Test 'Completed history does not block a later request and UpgradeAll has only one active entry' {
        $item = (Add-QueueItem (New-TestItem)).Item
        Complete-QueueItem $item.Id -State Succeeded -Message done
        Assert (Add-QueueItem (New-TestItem)).Added
        $upgrade = Add-QueueItem (New-QueueItem -Action UpgradeAll -Source System)
        Assert $upgrade.Added
        Assert (-not (Add-QueueItem (New-QueueItem -Action UpgradeAll -Source System)).Added)
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 2
    }
    Test 'A queue ID collision never overwrites another pending package' {
        $first = New-TestItem app
        $first.Id = 'shared-id'
        [void](Add-QueueItem $first)
        $second = New-TestItem other
        $second.Id = 'shared-id'
        $added = Add-QueueItem $second
        Assert $added.Added
        Assert ($added.Item.Id -ne 'shared-id')
        Assert-Equal (Read-QueueItemFile (Get-QueueItemPath $script:QueuePendingDir 'shared-id')).Alias 'app'
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 2
    }
    Test 'FIFO claims files by arrival rather than attacker-controlled CreatedAt or filename' {
        $first = New-TestItem app
        $first.Id = 'z-first'
        $first.CreatedAt = '2099-01-01T00:00:00Z'
        [void](Add-QueueItem $first)
        Start-Sleep -Milliseconds 60
        $second = New-TestItem other
        $second.Id = 'a-second'
        $second.CreatedAt = '2000-01-01T00:00:00Z'
        [void](Add-QueueItem $second)
        $claimed = Get-NextQueuedItem
        Assert-Equal $claimed.Id 'z-first'
        Assert-Equal $claimed.State 'Running'
        Assert-Equal $claimed.Stage 'Starting'
        Assert $claimed.IsIndeterminate
        Assert ($null -ne $claimed.StartedAt)
        Assert (-not (Test-Path -LiteralPath (Get-QueueItemPath $script:QueuePendingDir $claimed.Id)))
        Assert-Equal (Get-NextQueuedItem).Id 'a-second'
        Assert ($null -eq (Get-NextQueuedItem))
    }
    Test 'Queue snapshots persist Current and real success/failure transitions without stale active files' {
        $first = (Add-QueueItem (New-TestItem app)).Item
        $second = (Add-QueueItem (New-TestItem other)).Item
        $running = Get-NextQueuedItem
        $snapshot = Read-Json $script:QueueStatePath
        Assert-Equal $snapshot.Current.Id $running.Id
        Assert-Equal @($snapshot.Queue).Count 2
        Complete-QueueItem $running.Id -State Succeeded -ExitCode 0 -Message 'done'
        $success = Read-QueueItemFile (Get-QueueItemPath $script:QueueSucceededDir $running.Id)
        Assert-Equal $success.State 'Succeeded'
        Assert-Equal $success.ProgressPercent 100
        Assert-Equal $success.Message 'done'
        Assert ($null -ne $success.FinishedAt)
        $running = Get-NextQueuedItem
        Complete-QueueItem $running.Id -State Failed -ExitCode 42 -Message 'installer failed'
        $failed = Read-QueueItemFile (Get-QueueItemPath $script:QueueFailedDir $running.Id)
        Assert-Equal $failed.State 'Failed'
        Assert-Equal $failed.ExitCode 42
        Assert ($null -eq $failed.ProgressPercent)
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
        Assert-Equal (Get-JsonCount $script:QueueRunningDir) 0
        $snapshot = Read-Json $script:QueueStatePath
        Assert ($null -eq $snapshot.Current)
        Assert-Equal @($snapshot.Queue).Count 2
        Complete-QueueItem 'missing-id' -State Failed -Message 'ignored'
        Assert-Equal @((Read-Json $script:QueueStatePath).Queue).Count 2
    }
    Test 'Find and complete recover a valid item stored under a noncanonical filename' {
        Ensure-QueueDirectories
        $item = New-TestItem
        $path = Join-Path $script:QueueRunningDir 'old-file-name.json'
        [void](Write-QueueItemFile $item -Path $path -DefaultState Running)
        Assert-Equal (Find-QueueItemFile $item.Id @($script:QueueRunningDir)).Path $path
        Complete-QueueItem $item.Id -State Failed -ExitCode 9 -Message 'recover'
        Assert (-not (Test-Path -LiteralPath $path))
        Assert-Equal (Read-QueueItemFile (Get-QueueItemPath $script:QueueFailedDir $item.Id)).ExitCode 9
    }
    Test 'Progress writes are persisted, unchanged updates throttled and changed updates published' {
        $item = (Add-QueueItem (New-TestItem)).Item
        [void](Get-NextQueuedItem)
        Update-QueueItemProgress $item.Id -Stage Downloading -StageText 'download' -ProgressPercent 25 -IsIndeterminate:$false
        $snapshot = Read-Json $script:QueueStatePath
        Assert-Equal $snapshot.Current.ProgressPercent 25
        Assert-Equal $snapshot.Current.Stage 'Downloading'
        Update-QueueItemProgress $item.Id -Stage Downloading -StageText 'download' -ProgressPercent 25 -IsIndeterminate:$false
        Assert-Equal (Read-Json $script:QueueStatePath).Version $snapshot.Version
        Update-QueueItemProgress $item.Id -Stage Installing -StageText 'install' -ProgressPercent 50 -IsIndeterminate:$false
        Assert-Equal (Read-QueueItemFile (Get-QueueItemPath $script:QueueRunningDir $item.Id)).ProgressPercent 50
        Assert-Equal (Read-Json $script:QueueStatePath).Current.Stage 'Installing'
    }
    Test 'Restart recovery requeues running files, clears volatile fields and is idempotent' {
        $item = (Add-QueueItem (New-TestItem)).Item
        $claimed = Get-NextQueuedItem
        Update-QueueItemProgress $item.Id -ProgressPercent 57 -Stage Installing
        Assert-Equal (Reset-RunningQueueItems) 1
        Assert-Equal (Reset-RunningQueueItems) 0
        Assert-Equal (Get-JsonCount $script:QueueRunningDir) 0
        $reset = Read-QueueItemFile (Get-QueueItemPath $script:QueuePendingDir $item.Id)
        Assert-Equal $reset.Id $item.Id
        Assert-Equal $reset.CreatedAt $claimed.CreatedAt
        Assert-Equal $reset.State 'Queued'
        Assert-Equal $reset.Stage 'Queued'
        Assert ([string]::IsNullOrWhiteSpace($reset.StartedAt))
        Assert ([string]::IsNullOrWhiteSpace($reset.FinishedAt))
        Assert ($null -eq $reset.ProgressPercent)
        Assert ($null -eq $reset.ExitCode)
        Assert (-not $reset.IsIndeterminate)
        Assert ($null -eq (Read-Json $script:QueueStatePath).Current)
    }
    foreach ($badQueue in @(
        @{ Name = 'malformed'; Raw = '{oops' },
        @{ Name = 'empty'; Raw = '' },
        @{ Name = 'null'; Raw = 'null' },
        @{ Name = 'scalar'; Raw = '42' },
        @{ Name = 'boolean'; Raw = 'true' },
        @{ Name = 'string'; Raw = '"not an object"' },
        @{ Name = 'empty-array'; Raw = '[]' },
        @{ Name = 'one-object-array'; Raw = '[{"Id":"untrusted","Action":"Install","Alias":"app"}]' },
        @{ Name = 'multiple-object-array'; Raw = '[{},{}]' }
    )) {
        Test "Corrupt pending JSON ($($badQueue.Name)) is quarantined with raw evidence before next valid item" {
            Ensure-QueueDirectories
            $path = Join-Path $script:QueuePendingDir 'a-corrupt.json'
            Set-Content -LiteralPath $path -Value $badQueue.Raw -Encoding UTF8
            Start-Sleep -Milliseconds 25
            $good = (Add-QueueItem (New-TestItem)).Item
            Assert-Equal (Get-NextQueuedItem).Id $good.Id
            Assert (-not (Test-Path -LiteralPath $path))
            $quarantined = @(Get-ChildItem -LiteralPath $script:QueueFailedDir -Filter 'corrupt-*.json' -File)
            Assert-Equal $quarantined.Count 1
            Assert-Equal ((Get-Content -LiteralPath $quarantined[0].FullName -Raw -Encoding UTF8).Trim()) $badQueue.Raw
            Assert (Test-Path -LiteralPath ($quarantined[0].FullName + '.error.txt'))
            Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
        }
    }
    Test 'Restart quarantines unreadable running items instead of silently retrying them' {
        Ensure-QueueDirectories
        $path = Join-Path $script:QueueRunningDir 'corrupt.json'
        Set-Content -LiteralPath $path -Value '{broken' -Encoding UTF8
        Assert-Equal (Reset-RunningQueueItems) 0
        Assert-Equal (Get-JsonCount $script:QueueRunningDir) 0
        Assert-Equal (Get-JsonCount $script:QueueFailedDir) 1
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
    }
    Test 'Snapshot is reconstructed from item files even when the published JSON is corrupt' {
        $item = (Add-QueueItem (New-TestItem)).Item
        Set-Content -LiteralPath $script:QueueStatePath -Value '{broken' -Encoding UTF8
        Assert (Test-QueueHasPendingWork)
        Assert-Equal @((Get-QueueStateSnapshot).Queue).Count 1
        Publish-QueueStateSnapshot
        Assert-Equal (Read-Json $script:QueueStatePath).Queue[0].Id $item.Id
        Assert-Equal (@(Get-ChildItem -LiteralPath $script:BaseDir -Recurse -Filter '*.tmp').Count) 0
    }
    Test 'History retention limits each on-disk history and publishes only newest combined entries' {
        Ensure-QueueDirectories
        $script:QueueCompletedRetention = 2
        foreach ($state in @('Succeeded', 'Failed')) {
            $directory = if ($state -eq 'Succeeded') { $script:QueueSucceededDir } else { $script:QueueFailedDir }
            foreach ($number in 1..4) {
                $item = New-TestItem
                $item.Id = "$state-$number"
                $item.State = $state
                $item.FinishedAt = ([DateTime]'2020-01-01T00:00:00Z').AddDays($number).ToString('o')
                $path = Get-QueueItemPath $directory $item.Id
                [void](Write-QueueItemFile $item -Path $path -DefaultState $state)
                [IO.File]::SetLastWriteTimeUtc($path, ([DateTime]'2020-01-01T00:00:00Z').AddDays($number))
            }
        }
        Limit-QueueHistory
        foreach ($directory in @($script:QueueSucceededDir, $script:QueueFailedDir)) {
            Assert-Equal (Get-JsonCount $directory) 2
            $prefix = Split-Path $directory -Leaf
            Assert-Equal ((@(Get-QueueItemsInDirectory $directory).Id | Sort-Object) -join ',') "$prefix-3,$prefix-4"
        }
        $snapshot = New-QueueStateSnapshot
        Assert-Equal @($snapshot.Queue).Count 2
        Assert-Equal (($snapshot.Queue.Id | Sort-Object) -join ',') 'Failed-4,Succeeded-4'
    }
    Test 'Legacy migration preserves raw backup, requeues only active items and cannot duplicate on repeat' {
        $queued = New-TestItem app
        $running = New-TestItem other
        $running.State = 'Running'
        $running.StartedAt = (Get-Date).ToString('o')
        $running.ProgressPercent = 70
        $completed = New-TestItem old
        $completed.State = 'Succeeded'
        $duplicate = New-TestItem APP
        Write-JsonFileAtomic $script:QueueStatePath ([pscustomobject]@{ Queue = @($queued, $running, $completed, $duplicate) })
        $original = Get-Content -LiteralPath $script:QueueStatePath -Raw -Encoding UTF8
        Migrate-LegacyQueueState
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 2
        Assert-Equal (Get-JsonCount $script:QueueRunningDir) 0
        $backups = @(Get-ChildItem -LiteralPath $script:BaseDir -Filter 'Queue-State.legacy-*.json')
        Assert-Equal $backups.Count 1
        Assert-Equal (Get-Content -LiteralPath $backups[0].FullName -Raw -Encoding UTF8) $original
        $requeued = Read-QueueItemFile (Get-QueueItemPath $script:QueuePendingDir $running.Id)
        Assert-Equal $requeued.State 'Queued'
        Assert ([string]::IsNullOrWhiteSpace($requeued.StartedAt))
        Assert ($null -eq $requeued.ProgressPercent)
        Migrate-LegacyQueueState
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 2
    }
    foreach ($legacyRaw in @('{broken', '', '[]', 'null', '42', '[{"Queue":[{"Action":"Install","Alias":"app","State":"Queued"}]}]')) {
        Test "Legacy migration retains invalid original '$legacyRaw' and starts an empty usable queue" {
            Set-Content -LiteralPath $script:QueueStatePath -Value $legacyRaw -Encoding UTF8
            Migrate-LegacyQueueState
            Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
            Assert-Equal @((Read-Json $script:QueueStatePath).Queue).Count 0
            $backups = @(Get-ChildItem -LiteralPath $script:BaseDir -Filter 'Queue-State.legacy-*.json')
            Assert-Equal $backups.Count 1
            Assert-Equal ((Get-Content -LiteralPath $backups[0].FullName -Raw -Encoding UTF8).Trim()) $legacyRaw
        }
    }
    Test 'JSON depth guard accepts depth eight, quoted brackets and escaped quote/backslash sequences' {
        $atLimit = ('[' * 7) + '{"literal":"[{]}"}' + (']' * 7)
        Assert-RequestJsonDepth -Raw $atLimit
        $escaped = [pscustomobject]@{ Command = 'Install'; AppAlias = 'app'; Text = 'quote " slash \ braces {{{[[[ quote \"' } | ConvertTo-Json -Compress
        Assert-RequestJsonDepth -Raw $escaped
        Assert-Throws { Assert-RequestJsonDepth -Raw ('[' + $atLimit + ']') } 'maximum depth 8'
        Assert-Throws { Assert-RequestJsonDepth -Raw '{"a":' } 'incomplete'
        Assert-Throws { Assert-RequestJsonDepth -Raw '}' } 'unexpected closing bracket'
        Assert-Throws { Assert-RequestJsonDepth -Raw '{"a":"unterminated}' } 'unterminated'
    }
    Test 'Scalar validation supports legacy field fallbacks and enforces lengths/types before conversion' {
        $request = [pscustomobject]@{ Command = ' '; Action = ' Install '; AppAlias = $null; Alias = ' app ' }
        Assert-Equal (Get-RequestScalarValue $request @('Command','Action') Command -MaxLength 32) 'Install'
        Assert-Equal (Get-RequestScalarValue $request @('AppAlias','Alias') Alias -MaxLength 128) 'app'
        Assert-Equal (Get-RequestScalarValue ([pscustomobject]@{ Value = ('a' * 128) }) @('Value') Alias -MaxLength 128).Length 128
        Assert-Throws { Get-RequestScalarValue ([pscustomobject]@{ Value = ('a' * 129) }) @('Value') Alias -MaxLength 128 } 'too long'
        foreach ($value in @(@('app'), @{ Alias = 'app' }, [pscustomobject]@{ Alias = 'app' })) {
            Assert-Throws { Get-RequestScalarValue ([pscustomobject]@{ Value = $value }) @('Value') Alias } 'must be a scalar'
        }
        Assert-Throws { Get-RequestScalarValue ([pscustomobject]@{}) @('Absent') Command } 'missing Command'
    }
    Test 'Request worker processes valid aliases/legacy fields, ignores spoofed identity and deduplicates on disk' {
        $firstPath = Write-TestRequest '[first].json' '{"Command":" INSTALL ","AppAlias":" APP ","PackageId":"Evil.Package","RequestedBy":"Administrator","RequestedBySid":"S-1-5-18"}'
        [void](Write-TestRequest 'second.json' '{"Action":"install","Alias":"app"}')
        Invoke-ProcessRequestsMode
        Assert-Equal (Get-JsonCount $script:RequestsDir) 0
        Assert-Equal (Get-JsonCount $script:ProcessedRequestsDir) 2
        Assert-Equal (Get-JsonCount $script:FailedRequestsDir) 0
        $items = @(Get-QueueItemsInDirectory $script:QueuePendingDir)
        Assert-Equal $items.Count 1
        Assert-Equal $items[0].PackageId 'Vendor.App'
        Assert-Equal $items[0].RequestedBy 'DOMAIN\ActualOwner'
        Assert-Equal $items[0].RequestedBySid 'S-1-5-21-123-456-789-1001'
        Assert-Equal $script:ownerPaths.Count 2
        Assert ($script:ownerPaths -contains $firstPath)
        Assert-Equal $script:aclPaths.Count 0
        Assert-Equal $script:workerStarts 1
    }
    foreach ($unsafeKind in @('Hardlink', 'Reparse')) {
        Test "Request worker rejects $unsafeKind before owner lookup or parsing and creates bounded diagnostics" {
            $originalInformation = ${function:Get-OpenRequestFileInformation}
            $script:unsafeRequestInfo = [pscustomobject]@{
                ReparsePoint = ($unsafeKind -eq 'Reparse')
                Directory = $false
                Links = if ($unsafeKind -eq 'Hardlink') { 2 } else { 1 }
            }
            Set-Item Function:script:Get-OpenRequestFileInformation -Value {
                param($Stream)
                return $script:unsafeRequestInfo
            }
            try {
                [void](Write-TestRequest 'unsafe.json' '{"Command":"Install","AppAlias":"app"}')
                Invoke-ProcessRequestsMode
                Assert-Equal $script:ownerPaths.Count 0
                Assert-Equal $script:aclPaths.Count 0
                Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
                $archive = Read-Json (Join-Path $script:FailedRequestsDir 'unsafe.json')
                Assert-Equal $archive.PayloadRetained $false
            }
            finally { Set-Item Function:script:Get-OpenRequestFileInformation -Value $originalInformation }
        }
    }
    Test 'Request byte-size limit is inclusive at exactly 32768 bytes without an encoding/BOM dependency' {
        $prefix = '{"Command":"Install","AppAlias":"app","Padding":"'
        $suffix = '"}'
        $raw = $prefix + ('x' * (32768 - $prefix.Length - $suffix.Length)) + $suffix
        $path = Write-TestRequest 'at-byte-limit.json' '{}'
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::UTF8.GetBytes($raw))
        Assert-Equal ([IO.FileInfo]$path).Length 32768
        Invoke-ProcessRequestsMode
        Assert-Equal (Get-JsonCount $script:ProcessedRequestsDir) 1
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 1
        Assert-Equal (Get-JsonCount $script:FailedRequestsDir) 0
    }
    Test 'A legitimate 128-character allowlisted alias is accepted at the request scalar boundary' {
        $alias = 'a' * 128
        $script:catalogValues = [ordered]@{}
        $script:catalogValues[$alias] = 'Vendor.LongAlias|Long alias'
        [void](Write-TestRequest 'long-allowed.json' ([pscustomobject]@{ Command = 'Install'; AppAlias = $alias } | ConvertTo-Json -Compress))
        Invoke-ProcessRequestsMode
        Assert-Equal (Get-JsonCount $script:ProcessedRequestsDir) 1
        $items = @(Get-QueueItemsInDirectory $script:QueuePendingDir)
        Assert-Equal $items.Count 1
        Assert-Equal $items[0].Alias $alias
        Assert-Equal $items[0].PackageId 'Vendor.LongAlias'
    }
    foreach ($command in @('refreshstatus', 'getstatus')) {
        Test "Status command '$command' archives request and wakes worker without an install alias" {
            [void](Write-TestRequest 'refresh.json' ('{"Command":"' + $command + '"}'))
            Invoke-ProcessRequestsMode
            Assert-Equal (Get-JsonCount $script:ProcessedRequestsDir) 1
            Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
            Assert-Equal $script:workerStarts 1
        }
    }
    $rejectedRequests = @(
        @{ Name = 'empty'; Raw = ''; Error = 'empty' },
        @{ Name = 'malformed'; Raw = '{broken'; Error = 'incomplete' },
        @{ Name = 'invalid-syntax'; Raw = '{"Command":Install}'; Error = 'JSON|Unexpected|invalid|parsing' },
        @{ Name = 'mismatched-brackets'; Raw = '{]'; Error = 'JSON|Unexpected|invalid|parsing' },
        @{ Name = 'null-root'; Raw = 'null'; Error = 'must be an object' },
        @{ Name = 'scalar-root'; Raw = '1'; Error = 'must be an object' },
        @{ Name = 'boolean-root'; Raw = 'true'; Error = 'must be an object' },
        @{ Name = 'string-root'; Raw = '"not an object"'; Error = 'must be an object' },
        @{ Name = 'empty-array'; Raw = '[]'; Error = 'must be an object' },
        @{ Name = 'single-object-array'; Raw = '[{"Command":"Install","AppAlias":"app"}]'; Error = 'must be an object' },
        @{ Name = 'multiple-object-array'; Raw = '[{"Command":"Install","AppAlias":"app"},{}]'; Error = 'must be an object' },
        @{ Name = 'missing-command'; Raw = '{"AppAlias":"app"}'; Error = 'missing Command' },
        @{ Name = 'missing-alias'; Raw = '{"Command":"Install"}'; Error = 'missing AppAlias' },
        @{ Name = 'array-command'; Raw = '{"Command":["Install"],"AppAlias":"app"}'; Error = 'scalar' },
        @{ Name = 'object-command'; Raw = '{"Command":{"Action":"Install"},"AppAlias":"app"}'; Error = 'scalar' },
        @{ Name = 'array-alias'; Raw = '{"Command":"Install","AppAlias":["app"]}'; Error = 'scalar' },
        @{ Name = 'object-alias'; Raw = '{"Command":"Install","AppAlias":{"Alias":"app"}}'; Error = 'scalar' },
        @{ Name = 'unknown-command'; Raw = '{"Command":"Execute","AppAlias":"app"}'; Error = 'Unsupported request command' },
        @{ Name = 'command-arguments'; Raw = '{"Command":"Install --all","AppAlias":"app"}'; Error = 'Unsupported request command' },
        @{ Name = 'unknown-alias'; Raw = '{"Command":"Install","AppAlias":"Vendor.App"}'; Error = 'allowlist' },
        @{ Name = 'wildcard-alias'; Raw = '{"Command":"Install","AppAlias":"app*"}'; Error = 'allowlist' },
        @{ Name = 'path-alias'; Raw = '{"Command":"Install","AppAlias":"../app"}'; Error = 'allowlist' },
        @{ Name = 'overlong-command'; Raw = ('{"Command":"' + ('x' * 33) + '","AppAlias":"app"}'); Error = 'too long' },
        @{ Name = 'overlong-alias'; Raw = ('{"Command":"Install","AppAlias":"' + ('a' * 129) + '"}'); Error = 'too long' },
        @{ Name = 'excessive-depth'; Raw = ('{"Command":"Install","AppAlias":"app","Extra":' + ('[' * 8) + '0' + (']' * 8) + '}'); Error = 'maximum depth 8' },
        @{ Name = 'oversized'; Raw = ('{"Command":"Install","AppAlias":"app","Padding":"' + ('x' * 32768) + '"}'); Error = 'too large' }
    )
    foreach ($rejected in $rejectedRequests) {
        Test "Request rejection ($($rejected.Name)) archives bounded evidence without changing the original ACL" {
            $path = Write-TestRequest ($rejected.Name + '.json') $rejected.Raw
            Invoke-ProcessRequestsMode
            Assert (-not (Test-Path -LiteralPath $path))
            Assert-Equal (Get-JsonCount $script:FailedRequestsDir) 1
            Assert-Equal (Get-JsonCount $script:ProcessedRequestsDir) 0
            Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
            $failedPath = Join-Path $script:FailedRequestsDir ($rejected.Name + '.json')
            $archived = (Get-Content -LiteralPath $failedPath -Raw -Encoding UTF8).Trim()
            if ($rejected.Name -eq 'oversized') {
                Assert-Equal ($archived | ConvertFrom-Json).PayloadRetained $false
                Assert ((Get-Item -LiteralPath $failedPath).Length -lt 1024)
            }
            else { Assert-Equal $archived $rejected.Raw }
            Assert ((Get-Content -LiteralPath ($failedPath + '.error.txt') -Raw -Encoding UTF8) -match $rejected.Error)
            Assert-Equal $script:aclPaths.Count 0
            Assert-Equal $script:workerStarts 0
        }
    }
    Test 'A shell-looking alias is data, never code, and cannot create its sentinel file' {
        # Keep the shell-looking alias within the request length limit so that
        # exact allowlist matching, not only the length check, is exercised.
        $payload = '$(New-Item injected-core-sentinel.txt)'
        $originalLocation = Get-Location
        try {
            Set-Location -LiteralPath $script:BaseDir
            [void](Write-TestRequest 'injection.json' ([pscustomobject]@{ Command = 'Install'; AppAlias = $payload } | ConvertTo-Json -Compress))
            Invoke-ProcessRequestsMode
            Assert (-not (Test-Path -LiteralPath 'injected-core-sentinel.txt'))
            Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
            Assert ((Get-Content -LiteralPath (Join-Path $script:FailedRequestsDir 'injection.json.error.txt') -Raw) -match 'allowlist')
        }
        finally { Set-Location -LiteralPath $originalLocation.Path }
    }
    foreach ($deniedAction in @('Install', 'Uninstall')) {
        Test "User $deniedAction requests are rejected when corresponding policy is disabled" {
            if ($deniedAction -eq 'Install') { $script:policyDwords.AllowUserInstalls = 0 }
            else { $script:policyDwords.AllowUserUninstall = 0 }
            [void](Write-TestRequest 'denied.json' ('{"Command":"' + $deniedAction + '","AppAlias":"app"}'))
            Invoke-ProcessRequestsMode
            Assert-Equal (Get-JsonCount $script:FailedRequestsDir) 1
            Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
            Assert-Equal $script:workerStarts 0
        }
    }
    Test 'Required uninstall request fails while required policy independently adds exactly one install' {
        $script:requiredValues.app = '1'
        [void](Write-TestRequest 'required.json' '{"Command":"Uninstall","AppAlias":"app"}')
        Invoke-ProcessRequestsMode
        Assert-Equal (Get-JsonCount $script:FailedRequestsDir) 1
        $items = @(Get-QueueItemsInDirectory $script:QueuePendingDir)
        Assert-Equal $items.Count 1
        Assert-Equal $items[0].Action 'Install'
        Assert-Equal $items[0].Source 'Required'
        Assert-Equal $script:workerStarts 1
    }
    Test 'Request archival collision preserves both documents and protects error sidecar too' {
        Ensure-Directory $script:FailedRequestsDir
        $existing = Join-Path $script:FailedRequestsDir 'same.json'
        Set-Content -LiteralPath $existing -Value 'existing evidence'
        $path = Write-TestRequest 'same.json' '{"Command":"Execute"}'
        $stream = Open-RequestFileRead $path
        try {
            Complete-RequestFile -Path $path -DestinationDir $script:FailedRequestsDir -Stream $stream -Raw '{"Command":"Execute"}' -ErrorMessage 'deliberate error'
        }
        finally { $stream.Dispose() }
        Assert-Equal (Get-JsonCount $script:FailedRequestsDir) 2
        Assert-Equal ((Get-Content -LiteralPath $existing -Raw).Trim()) 'existing evidence'
        $newFiles = @(Get-ChildItem -LiteralPath $script:FailedRequestsDir -Filter 'same-*.json')
        Assert-Equal $newFiles.Count 1
        Assert-Equal ((Get-Content -LiteralPath ($newFiles[0].FullName + '.error.txt') -Raw).Trim()) 'deliberate error'
        Assert-Equal $script:aclPaths.Count 0
    }
    Test 'Legacy failed archives are never replayed with their privileged archive owner' {
        Ensure-Directory $script:FailedRequestsDir
        [void](Write-TestRequest 'retry.json' '{"Command":"getstatus"}')
        foreach ($entry in @(
            @{ Name = 'retry'; Error = 'Timed out waiting for queue state lock' },
            @{ Name = 'depth'; Error = 'The script failed due to call depth overflow' },
            @{ Name = 'permanent'; Error = 'Alias is not in the allowlist' }
        )) {
            $path = Join-Path $script:FailedRequestsDir ($entry.Name + '.json')
            Set-Content -LiteralPath $path -Value '{"Command":"getstatus"}'
            Set-Content -LiteralPath ($path + '.error.txt') -Value $entry.Error
        }
        Set-Content -LiteralPath (Join-Path $script:FailedRequestsDir 'orphan.json.error.txt') -Value 'queue state lock'
        Restore-QueueLockFailedRequests
        Assert-Equal (Get-JsonCount $script:RequestsDir) 1
        Assert-Equal (Get-JsonCount $script:FailedRequestsDir) 3
        Assert (Test-Path -LiteralPath (Join-Path $script:FailedRequestsDir 'permanent.json.error.txt'))
        Assert (Test-Path -LiteralPath (Join-Path $script:FailedRequestsDir 'orphan.json.error.txt'))
        Assert (Test-Path -LiteralPath (Join-Path $script:FailedRequestsDir 'retry.json.error.txt'))
        Restore-QueueLockFailedRequests
        Assert-Equal (Get-JsonCount $script:RequestsDir) 1
        Assert-Equal $script:workerStarts 0
    }
    Test 'A queued item loses permission if its catalog alias is removed before execution' {
        $item = (Add-SoftwareRequestToQueue Install app).Item
        [void]$script:catalogValues.Remove('app')
        $running = Get-NextQueuedItem
        Invoke-QueuedItem $running -WingetPath 'must-not-run-winget'
        $failed = Read-QueueItemFile (Get-QueueItemPath $script:QueueFailedDir $item.Id)
        Assert-Equal $failed.State 'Failed'
        Assert-Equal $failed.ExitCode 1
        Assert-Equal (Get-JsonCount $script:QueueRunningDir) 0
    }
    Test 'A queued uninstall cannot bypass a newly enabled Required policy at execution time' {
        $item = (Add-SoftwareRequestToQueue Uninstall app).Item
        $script:requiredValues.app = '1'
        Invoke-QueuedItem (Get-NextQueuedItem) -WingetPath 'must-not-run-winget'
        $failed = Read-QueueItemFile (Get-QueueItemPath $script:QueueFailedDir $item.Id)
        Assert-Equal $failed.State 'Failed'
        Assert-Equal $failed.ExitCode 1
        Assert-Equal (Get-JsonCount $script:QueueRunningDir) 0
    }
    Test 'Already-installed queued package is completed from the real snapshot without invoking winget' {
        $item = (Add-SoftwareRequestToQueue Install app).Item
        Write-JsonFileAtomic $script:InstalledPackagesPath ([pscustomobject]@{ InstalledPackageIds = @('vendor.app') })
        Invoke-QueuedItem (Get-NextQueuedItem) -WingetPath 'must-not-run-winget'
        $completed = Read-QueueItemFile (Get-QueueItemPath $script:QueueSucceededDir $item.Id)
        Assert-Equal $completed.State 'Succeeded'
        Assert-Equal $completed.ExitCode 0
        Assert-Equal (Get-JsonCount $script:QueueRunningDir) 0
    }
    Test 'Worker request mode rechecks install/uninstall policy and normalizes its explicit alias' {
        $script:AppAlias = ' APP '
        $script:RequestAction = 'Install'
        $script:RequestedBy = 'worker-owner'
        $script:RequestedBySid = 'worker-sid'
        $script:policyDwords.AllowUserInstalls = 0
        Invoke-ProcessRequestMode
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 0
        Assert-Equal $script:workerStarts 0
        $script:policyDwords.AllowUserInstalls = 1
        Invoke-ProcessRequestMode
        Assert-Equal (Get-JsonCount $script:QueuePendingDir) 1
        Assert-Equal $script:workerStarts 1
        Assert-Equal (@(Get-QueueItemsInDirectory $script:QueuePendingDir)[0]).Alias 'app'
        $script:AppAlias = ''
        Assert-Throws { Invoke-ProcessRequestMode } 'AppAlias is required'
    }
}
finally {
    Remove-Item -LiteralPath $script:tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ("Core regression tests: {0} passed, {1} failed (PowerShell {2})." -f $script:passed, $script:failures.Count, $PSVersionTable.PSVersion)
if ($script:failures.Count) { throw "Core regression suite failed ($($script:failures.Count) failures); see FAIL lines above." }
