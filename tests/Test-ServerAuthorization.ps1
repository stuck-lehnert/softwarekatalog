# Portable authorization contracts. Real NTFS/identity/Authz/elevation evidence
# is additionally required by the native Windows integration lanes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'setup.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
$realServerDetection = ${function:Test-ServerOperatingSystem}
$realAdministratorDetection = ${function:Test-AdministratorSid}
$clientAuthorizationText = Get-ClientAuthorizationFunctionText
$root = Join-Path ([IO.Path]::GetTempPath()) ('softkat-authorization-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$passed = 0; $failures = @()

function Assert($Condition, [string]$Message = 'Assertion failed') { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
    try { & $Body | Out-Null }
    catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw "Expected exception matching '$Pattern'."
}
function Test([string]$Name, [scriptblock]$Body) {
    $script:BaseDir = Join-Path $root ([guid]::NewGuid().ToString('N'))
    $script:RequestsDir = Join-Path $BaseDir 'Requests'
    $script:ProcessedRequestsDir = Join-Path $BaseDir 'Processed'
    $script:FailedRequestsDir = Join-Path $BaseDir 'Failed'
    $script:LogDir = Join-Path $BaseDir 'Logs'
    foreach ($path in @($RequestsDir, (Get-AdminRequestsDirectory))) { Ensure-Directory $path }
    $script:server = $true; $script:serverFailure = $false
    $script:QueueStateMutexName = 'authorization-test-mutex'
    $script:allowInstalls = $true; $script:required = $false
    $script:accountAdmin = $false; $script:elevated = $false
    $script:ownerSid = 'S-1-5-21-1-2-3-1001'; $script:ownerSafe = $true
    $script:adminSid = 'S-1-5-21-1-2-3-1002'; $script:membership = $true
    $script:added = @(); $script:completed = @(); $script:dispatches = 0
    $script:directoryChecks = 0; $script:directoryFailure = $false; $script:queueFailure = $false
    $script:installed = $true; $script:ScopeRepairFailures = @()
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failures += $Name; Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
# Boundary doubles only: production guards, request parser, file reads/moves,
# queue schema and generated authorization functions are executed unchanged.
function Get-ItemProperty {
    param([string]$LiteralPath, $ErrorAction)
    Assert ($LiteralPath -eq 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\ProductOptions')
    if ($script:registryFailure) { throw 'registry unavailable' }
    [pscustomobject]@{ ProductType = $script:productType }
}
function Test-ServerOperatingSystem { if ($script:serverFailure) { throw 'OS unavailable' }; return $script:server }
function Test-UserInstallsAllowed { return $script:allowInstalls }
function Test-UserUninstallAllowed { return $true }
function Get-CurrentUserAccount { [pscustomobject]@{ Administrator = $script:accountAdmin; ElevatedAdministrator = $script:elevated } }
function Initialize-AuthorizationNativeApi { throw 'membership lookup unavailable' }
function Test-AdministratorSid { param([string]$Sid); return ($script:membership -and $Sid -eq $script:adminSid) }
function Get-AppCatalogObjectByAlias { param([string]$Alias); if ($Alias -eq 'app') { [pscustomobject]@{ PackageId = 'Vendor.App'; DisplayName = 'App' } } }
function Get-RequiredAliasSet {
    $set = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($script:required) { [void]$set.Add('app') }; return ,$set
}
function Add-QueueItem {
    param($Item, $TimeoutSeconds)
    if ($script:queueFailure) { throw 'queue state lock unavailable' }
    $script:added += $Item; [pscustomobject]@{ Added = $true; Item = $Item }
}
function Complete-QueueItem { param($Id, $State, $ExitCode, $Message); $script:completed += $State }
function Test-ArtCraftManagedPackage { param($PackageId); return $false }
function Get-InstalledPackageIdSet {
    $set = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($script:installed) { [void]$set.Add('Vendor.App') }; return ,$set
}
function Invoke-WingetInstall { param($WingetPath, $PackageId, $QueueItemId); $script:dispatches++; return 0 }
function Invoke-WingetUninstall { param($WingetPath, $PackageId, $QueueItemId); $script:dispatches++; return 0 }
function Invoke-ArtCraftUpdates { return 0 }
function Invoke-WingetUpgradeAll { param($WingetPath, $QueueItemId); $script:dispatches++; return 0 }
function Update-InstalledPackagesSnapshot { param($WingetPath, $QueueItemId) }
function Ensure-RequiredSoftwareQueued { param($TimeoutSeconds); return 0 }
function Start-QueueWorkerIfAvailable { return $true }
function Write-Log { param($Message, $Level) }
. (Join-Path $PSScriptRoot 'helpers/PortableFileSystem.ps1')

function Set-FileAclAdminsOnly { param($Path) } # Real ACLs are tested natively.
function Assert-AdminRequestsDirectory {
    $script:directoryChecks++
    if ($script:directoryFailure) { throw 'unsafe private directory' }
}
function Get-RequestFileOwnerInfo {
    param($Path, [IO.FileStream]$Stream)
    Assert ($null -ne $Stream -and $Stream.CanRead) 'Owner and bytes must be inspected under the same open handle'
    [pscustomobject]@{ Name = 'ActualOwner'; Sid = $script:ownerSid; SafeForInstall = $script:ownerSafe }
}
function Write-Request([string]$Json, [switch]$Admin) {
    $directory = if ($Admin) { Get-AdminRequestsDirectory } else { $RequestsDir }
    $path = Join-Path $directory ([guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($path, $Json)
    return $path
}
function New-TestQueueItem {
    $item = New-QueueItem -Action Install -Alias app -PackageId Vendor.App -DisplayName App -Source User -RequestedBySid $script:ownerSid
    $item.UserInstallAuthorizationVersion = 1
    return $item
}
try {
    Test 'Server detection uses exact protected ProductType including domain controllers' {
        $script:registryFailure = $false
        foreach ($value in @('ServerNT','LanmanNT','WinNT')) {
            $script:productType = $value
            Assert ((& $realServerDetection) -eq ($value -ne 'WinNT'))
        }
    }
    Test 'Unknown product and failed registry reads fail closed' {
        $script:registryFailure = $false; $script:productType = 'Unknown'
        Assert-Throws { & $realServerDetection } 'Produkttyp'
        $script:registryFailure = $true
        Assert-Throws { & $realServerDetection } 'registry unavailable'
    }
    Test 'Missing, invalid and unresolved administrator identities are never accepted' {
        Assert (-not (& $realAdministratorDetection ''))
        Assert (-not (& $realAdministratorDetection 'not-a-sid'))
        Assert (-not (& $realAdministratorDetection $script:adminSid))
        Assert (& $realAdministratorDetection 'S-1-5-18')
        Assert (& $realAdministratorDetection 'S-1-5-32-544')
    }
    Test 'Server UI denies standard users and explains elevation for filtered administrators' {
        Assert (-not (Get-CurrentUserInstallAuthorization).Allowed)
        $script:accountAdmin = $true
        Assert ((Get-CurrentUserInstallAuthorization).Reason -match 'als Administrator')
        $script:elevated = $true
        Assert (Get-CurrentUserInstallAuthorization).Allowed
    }
    Test 'Install policy remains an upper bound for administrators and clients' {
        $script:allowInstalls = $false; $script:accountAdmin = $true; $script:elevated = $true
        Assert (-not (Get-CurrentUserInstallAuthorization).Allowed)
        Assert-Throws { Assert-UserInstallAuthorized $adminSid } 'Richtlinie'
        $script:server = $false
        Assert (-not (Get-CurrentUserInstallAuthorization).Allowed)
    }
    Test 'Client self service does not require administrator identity or elevation' {
        $script:server = $false
        Assert (Get-CurrentUserInstallAuthorization).Allowed
        [void](Add-SoftwareRequestToQueue Install app -RequestedBySid $ownerSid)
        Assert ($added.Count -eq 1 -and $added[0].UserInstallAuthorizationVersion -eq 0)
    }
    Test 'Unavailable server detection disables UI and backend installation' {
        $script:serverFailure = $true
        Assert (-not (Get-CurrentUserInstallAuthorization).Allowed)
        Assert-Throws { Add-SoftwareRequestToQueue Install app -RequestedBySid $adminSid } 'OS unavailable'
        Assert ($added.Count -eq 0)
    }
    Test 'Server enqueue rejects ordinary users before deduplication' {
        Assert-Throws { Add-SoftwareRequestToQueue Install app -RequestedBySid $ownerSid } 'Administrator'
        Assert ($added.Count -eq 0)
    }
    Test 'Authorized server queue records preserve the new provenance version through serialization' {
        $result = Add-SoftwareRequestToQueue Install app -RequestedBySid $adminSid
        $roundTrip = $result.Item | ConvertTo-Json | ConvertFrom-Json
        $record = ConvertTo-QueueItemRecord -Item $roundTrip
        Assert ($record.UserInstallAuthorizationVersion -eq 1 -and $record.RequestedBySid -eq $adminSid)
    }
    Test 'Required source needs a currently required alias' {
        Assert-Throws { Add-SoftwareRequestToQueue Install app -Source Required } 'Pflichtauftrag'
        $script:required = $true; $script:allowInstalls = $false
        [void](Add-SoftwareRequestToQueue Install app -Source Required)
        Assert ($added.Count -eq 1)
    }
    Test 'Old server requests without provenance are rejected even for current administrators' {
        $script:ownerSid = $adminSid
        $item = New-TestQueueItem; $item.UserInstallAuthorizationVersion = 0
        Assert-Throws { Invoke-QueuedItem $item winget } 'Alter Installationsauftrag'
        Assert ($completed.Count -eq 0 -and $dispatches -eq 0)
    }
    Test 'Server queue rechecks current membership before already-installed and installer shortcuts' {
        $script:ownerSid = $adminSid; $item = New-TestQueueItem
        $script:membership = $false
        Assert-Throws { Invoke-QueuedItem $item winget } 'Administrator'
        $script:installed = $false
        Assert-Throws { Invoke-QueuedItem $item winget } 'Administrator'
        Assert ($completed.Count -eq 0 -and $dispatches -eq 0)
    }
    Test 'Stale Required source cannot bypass current authorization after policy removal' {
        $item = New-TestQueueItem; $item.Source = 'Required'; $item.Required = $true
        Assert-Throws { Invoke-QueuedItem $item winget } 'Administrator'
    }
    Test 'Current Required installs and automatic SYSTEM updates remain unaffected' {
        $script:required = $true; $script:allowInstalls = $false
        $item = New-TestQueueItem; $item.Source = 'Required'
        Invoke-QueuedItem $item winget
        $item.Action = 'UpgradeAll'; Invoke-QueuedItem $item winget
        Assert ($completed.Count -eq 2 -and $dispatches -eq 1)
    }
    Test 'Ordinary uninstalls remain allowed while required uninstalls stay protected' {
        $item = New-TestQueueItem; $item.Action = 'Uninstall'
        Invoke-QueuedItem $item winget
        Assert ($dispatches -eq 1)
        $script:required = $true; Invoke-QueuedItem $item winget
        Assert ($dispatches -eq 1 -and $completed[-1] -eq 'Failed')
    }
    Test 'Legacy server CLI never accepts supplied SYSTEM or administrator identity claims' {
        $script:AppAlias = 'app'; $script:RequestAction = 'Install'
        $script:RequestedBy = 'SYSTEM'; $script:RequestedBySid = 'S-1-5-18'
        Assert-Throws { Invoke-ProcessRequestMode } 'Dateianfrage'
        Assert ($added.Count -eq 0)
    }
    Test 'Server public drop rejects even an administrator-owned safe file' {
        $script:ownerSid = $adminSid
        [void](Write-Request '{"Command":"Install","AppAlias":"app"}')
        Invoke-ProcessRequestsMode
        Assert ($added.Count -eq 0 -and @(Get-ChildItem $FailedRequestsDir -Filter '*.json').Count -eq 1)
        Assert ((Get-Content (Join-Path $FailedRequestsDir '*.error.txt') -Raw) -match 'normalen Eingang')
    }
    Test 'Private drop accepts actual administrator owner and ignores JSON identity claims' {
        $script:ownerSid = $adminSid
        [void](Write-Request '{"Command":"Install","AppAlias":"app","RequestedBy":"SYSTEM","RequestedBySid":"S-1-5-18","PackageId":"Evil.Package"}' -Admin)
        Invoke-ProcessRequestsMode
        Assert ($added.Count -eq 1 -and $added[0].RequestedBySid -eq $adminSid -and $added[0].PackageId -eq 'Vendor.App')
        Assert ($directoryChecks -eq 1)
    }
    Test 'Unsafe private drop and unsafe request DACL fail closed' {
        $script:directoryFailure = $true
        Assert-Throws { Invoke-ProcessRequestsMode } 'unsafe private directory'
        $script:directoryFailure = $false; $script:ownerSid = $adminSid; $script:ownerSafe = $false
        [void](Write-Request '{"Command":"Install","AppAlias":"app"}' -Admin)
        Invoke-ProcessRequestsMode
        Assert ($added.Count -eq 0)
    }
    Test 'A private request retains its authenticated inbox across a transient queue lock failure' {
        $script:QueueStateMutexName = 'authorization-test-mutex'
        $script:ownerSid = $adminSid; $script:queueFailure = $true
        $path = Write-Request '{"Command":"Install","AppAlias":"app"}' -Admin
        Invoke-ProcessRequestsMode
        Assert (Test-Path -LiteralPath $path)
        $script:queueFailure = $false; Invoke-ProcessRequestsMode
        Assert (-not (Test-Path -LiteralPath $path))
        Assert ($added.Count -eq 1)
    }
    Test 'Public request flood does not starve private administrator requests' {
        $script:ownerSid = $adminSid
        foreach ($i in 1..201) { [void](Write-Request '{"Command":"Install","AppAlias":"app"}') }
        [void](Write-Request '{"Command":"Install","AppAlias":"app"}' -Admin)
        Invoke-ProcessRequestsMode
        Assert ($added.Count -eq 1)
    }
    Test 'Protected queue metadata is rejected on server and client regardless of claimed identity' {
        foreach ($isServer in @($true, $false)) {
            $script:server = $isServer
            foreach ($field in @('Source','Required','UserInstallAuthorizationVersion')) {
                $request = @{ Command = 'Install'; AppAlias = 'app'; RequestedBySid = 'S-1-5-18' }; $request[$field] = 1
                [void](Write-Request ($request | ConvertTo-Json -Compress))
            }
            Invoke-ProcessRequestsMode
        }
        Assert ($added.Count -eq 0 -and @(Get-ChildItem $FailedRequestsDir -Filter '*.json').Count -eq 6)
    }
    Test 'Client public requests preserve standard user self-service' {
        $script:server = $false
        [void](Write-Request '{"Command":"Install","AppAlias":"app"}')
        Invoke-ProcessRequestsMode
        Assert ($added.Count -eq 1 -and $added[0].RequestedBySid -eq $ownerSid -and $directoryChecks -eq 0)
    }
    Test 'Generated helper and GUI receive one identical shared authorization implementation' {
        $generated = [Management.Automation.Language.Parser]::ParseInput($clientAuthorizationText, [ref]$tokens, [ref]$parseErrors)
        Assert ($parseErrors.Count -eq 0)
        foreach ($name in @('Test-ServerOperatingSystem','Get-CurrentUserAccount','Get-CurrentUserInstallAuthorization','Get-AdminRequestsDirectory','New-CatalogRequestFile')) {
            $definitions = @($generated.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name })
            Assert ($definitions.Count -eq 1) "Generated definition missing/duplicated: $name"
            $original = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name }
            $generatedBody = $definitions[0].Body.Extent.Text
            $originalBody = $original.Body.Extent.Text
            Assert ($generatedBody.Substring(1, $generatedBody.Length - 2).Trim() -ceq $originalBody.Substring(1, $originalBody.Length - 2).Trim()) "Generated code differs: $name"
        }
        $script:server = $true; $script:accountAdmin = $false
        Assert-Throws { New-CatalogRequestFile Install app } 'Administrator'
        Assert (@(Get-ChildItem $RequestsDir -File).Count -eq 0)
    }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }
if ($failures.Count) { throw "$($failures.Count) authorization tests failed: $($failures -join ', ')" }
Write-Output "$passed tests passed."
