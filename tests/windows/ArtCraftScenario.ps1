[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][ValidateSet('ArtCraft','ArtCraftInterrupt','ArtCraftResume','ArtCraftCleanup')][string]$Phase)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem -or
    -not (Test-Path -LiteralPath (Join-Path $Root '.disposable-ci-fixture'))) { throw 'Disposable real SYSTEM fixture required.' }
$script:artCraftFixtureRoot = [IO.Path]::GetFullPath($Root)
$config = Get-Content -LiteralPath (Join-Path $Root 'artcraft-fixture-config.json') -Raw | ConvertFrom-Json
$script:artCraftFixtureConfig = $config
$wingetConfig = Get-Content -LiteralPath (Join-Path $Root 'fixture-config.json') -Raw | ConvertFrom-Json
$source = [IO.File]::ReadAllText((Join-Path $env:ProgramData '__Softwarekatalog\SelfServiceWinget.ps1'))
$entry = $source.IndexOf('# Entry point')
if ($entry -lt 0) { throw 'Production entry point marker missing.' }
. ([scriptblock]::Create($source.Substring(0, $entry)))
$script:cases = @()
$failed = $false
$script:msiCalls = New-Object 'System.Collections.Generic.List[string]'
$script:originalArtCraftMsi = ${function:Invoke-ArtCraftMsi}
$script:fixtureWinget = Join-Path $Root 'winget-fixture.exe'
$script:faultProductCode = ''
$script:faultInjected = $false
$script:httpCalls = 0

# Keep the existing real-registry reader, narrowed to this run's GUIDs so the
# generic scope-repair worker cannot touch unrelated hosted-runner software.
$script:readRegisteredApplications = ${function:Get-RegisteredApplications}
$script:fixtureProductCodes = @($wingetConfig.ProductCode) + @($config.Packages | ForEach-Object { $_.OldProductCode; $_.ProductCode })
function Get-RegisteredApplications {
    param([switch]$IncludeUnnamed)
    & $script:readRegisteredApplications -IncludeUnnamed:$IncludeUnnamed | Where-Object { $_.ProductCode -in $script:fixtureProductCodes }
}
function Ensure-WingetAvailable { $script:fixtureWinget }
function Start-QueueWorkerIfAvailable { $true }
# This is a test-local publisher allowlist, NOT a trust bypass. The actual MSI
# is signed, Windows must return Valid, and hash/family/architecture are checked.
function Get-ArtCraftAllowedSignerSubjects { $script:artCraftFixtureConfig.CertificateSubject }
function Invoke-ArtCraftHttp {
    param([uri]$Uri, $Definition, [string]$Tag, [string]$AssetName, [switch]$Latest,
        [string]$Destination, [long]$MaxBytes = 1048576)
    $script:httpCalls++
    $packages = @($script:artCraftFixtureConfig.Packages | Where-Object { $_.PackageId -ceq $Definition.PackageId })
    if ($packages.Count -ne 1 -or $Uri.Scheme -cne 'https' -or $Uri.Host -cne 'github.com' -or
        -not $Uri.AbsolutePath.StartsWith(('/' + $Definition.Repository + '/releases/'), [StringComparison]::Ordinal)) {
        throw 'Fixture transport refuses unrelated repository/URI.'
    }
    $package = $packages[0]
    if ($Latest) { return [pscustomobject]@{ Uri = [uri]('https://github.com/' + $Definition.Repository + '/releases/tag/' + $package.Tag); Text = $null } }
    if ($Tag -cne $package.Tag) { throw 'Fixture transport refuses an unfrozen/mismatched tag.' }
    if ($AssetName -ceq 'SHA256SUMS.txt' -and -not $Destination) {
        return [pscustomobject]@{ Uri = $Uri; Text = ($package.Sha256 + '  ' + $package.AssetName + "`n") }
    }
    if ($AssetName -cne $package.AssetName -or -not $Destination -or (Get-Item -LiteralPath $package.Msi).Length -gt $MaxBytes) {
        throw 'Fixture transport refuses unrelated/oversize asset.'
    }
    # Preserve CreateNew semantics of production transport; never overwrite an
    # already existing protected download destination.
    [IO.File]::Copy($package.Msi, $Destination, $false)
    [pscustomobject]@{ Uri = $Uri; Text = $null }
}
function Invoke-ArtCraftMsi {
    param([Parameter(Mandatory)][string]$Arguments)
    $script:msiCalls.Add($Arguments)
    # Production Invoke-ArtCraftInstall has a local $root=ProgramFiles. Use an
    # explicit script-scoped fixture path: PowerShell's dynamic scope would
    # otherwise put this log AND the kill marker in that caller's ProgramFiles.
    Add-Content -LiteralPath (Join-Path $script:artCraftFixtureRoot 'artcraft-msi-invocations.jsonl') -Value ($Arguments | ConvertTo-Json -Compress)
    $code = & $script:originalArtCraftMsi -Arguments $Arguments
    # The only fault injection is AFTER a real, successful native MSI removal.
    # Kill the worker process, not merely a helper or catchable scriptblock.
    if ($script:faultProductCode -and -not $script:faultInjected -and $code -in @(0,3010) -and
        $Arguments.StartsWith(('/x ' + $script:faultProductCode + ' '), [StringComparison]::OrdinalIgnoreCase)) {
        $script:faultInjected = $true
        New-ItemProperty -Path $PolicyRoot -Name EnableArtCraft -PropertyType DWord -Value 0 -Force | Out-Null
        [pscustomobject]@{ ProcessId = $PID; ProductCode = $script:faultProductCode; ExitCode = $code; TimeUtc = [datetime]::UtcNow.ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:artCraftFixtureRoot 'artcraft-interruption.json') -Encoding UTF8
        [Diagnostics.Process]::GetCurrentProcess().Kill()
        throw 'The bounded real-process termination injector did not terminate the worker.'
    }
    $code
}
function Check($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Case([string]$Name, [scriptblock]$Body) {
    try { & $Body | Out-Host; $script:cases += [pscustomobject]@{ Name = $Name; Success = $true; Error = '' }; Write-Output "PASS $Name" }
    catch { $script:cases += [pscustomobject]@{ Name = $Name; Success = $false; Error = ($_.ToString() + "`n" + $_.ScriptStackTrace) }; throw }
}
function Run-FixtureMsi([string]$Arguments) {
    # Initial seeding/cleanup is outside the instrumented provider boundary.
    $code = & $script:originalArtCraftMsi -Arguments $Arguments
    if ($code -notin @(0,3010,1605)) { throw "Real fixture MSI operation failed: $code; $Arguments" }
    $code
}
function Get-Package([string]$Alias) { $config.Packages | Where-Object Alias -eq $Alias }
function Assert-Healthy($Package) {
    $inventory = @(Get-ArtCraftInventory | Where-Object PackageId -eq $Package.PackageId)
    Check ($inventory.Count -eq 1 -and $inventory[0].Healthy -and $inventory[0].Scope -eq 'machine') "No single healthy machine registration: $($Package.Alias)"
    Check ($inventory[0].Version -eq $Package.Version -and $inventory[0].Architecture -eq $config.Architecture -and $inventory[0].ProductCode -eq $Package.ProductCode) 'Version/native architecture/MSI identity mismatch.'
    Check (Test-Path -LiteralPath $Package.Executable) 'Verified native executable is missing.'
    $output = & $Package.Executable 2>&1 | Out-String
    Check ($LASTEXITCODE -eq 0 -and $output -match "process=$($config.Architecture); os=$($config.Architecture); native=True") 'Installed executable did not prove native SYSTEM execution.'
}
Start-Transcript -Path (Join-Path $Root "$Phase.transcript.txt") | Out-Null
try {
    if ($Phase -eq 'ArtCraft') {
        $grid = Get-Package gridcraft
        $pdf = Get-Package pdfcraft
        Case 'Reject any pre-existing ArtCraft family before seeding real MSI products' {
            # Unlike the scoped worker reader, this initial proof includes the
            # actual complete machine/SYSTEM registry and native family evidence.
            foreach ($definition in @(Get-ArtCraftDefinitions | Where-Object { $_.Alias -in @('gridcraft','pdfcraft','wordcraft') })) {
                Check (@(Get-ArtCraftRelatedProducts $definition).Count -eq 0) "Refusing pre-existing native MSI family: $($definition.Alias)"
                Check (@(& $script:readRegisteredApplications -IncludeUnnamed | Where-Object { $_.DisplayName -match ('^' + [regex]::Escape($definition.DisplayName) + '(?:\s|$)') }).Count -eq 0) 'Refusing pre-existing ArtCraft registration.'
            }
        }
        Case 'Healthy old adapter-managed machine MSI is adopted durably without uninstall/reinstall or HTTP' {
            & $grid.LegacyWingetAdapter install --id $grid.PackageId --exact --source winget --scope machine --silent
            Check ($LASTEXITCODE -eq 0) 'Real old WinGet adapter machine installation failed.'
            Check (Update-WingetPackagesSnapshot -WingetPath $grid.LegacyWingetAdapter -DestinationPath $InstalledPackagesPath) 'Could not publish actual old-provider export before adoption.'
            Check ((Get-InstalledPackageIdSet).Contains($grid.PackageId)) 'Old-provider inventory did not identify the actual machine MSI.'
            New-ItemProperty -Path $PolicyCatalogRoot -Name oldgrid -PropertyType String -Value "$($grid.PackageId)|Old GridCraft|Old WinGet-managed offer" -Force | Out-Null
            Check ((Get-AppCatalogObjectByAlias -Alias oldgrid).Provider -eq 'WinGet') 'Pre-opt-in legacy catalog offer was not WinGet-managed.'
            New-ItemProperty -Path $PolicyRoot -Name EnableArtCraft -PropertyType DWord -Value 1 -Force | Out-Null
            $before = (Get-Item -LiteralPath $grid.Executable).LastWriteTimeUtc
            Check ((Invoke-WithWingetLock { Initialize-ArtCraftProvider }) -in @(0,3010)) 'Offline adoption failed.'
            $owner = @(Get-ArtCraftOwnership | Where-Object PackageId -eq $grid.PackageId)
            Check ($owner.Count -eq 1 -and $owner[0].Stage -eq 'Owned' -and $owner[0].Version -eq '1.0.0') 'Healthy old product was not durably adopted.'
            Check ($script:msiCalls.Count -eq 0 -and $script:httpCalls -eq 0) 'Provider switch unnecessarily invoked MSI/network.'
            Check ((Get-Item -LiteralPath $grid.Executable).LastWriteTimeUtc -eq $before) 'Provider adoption modified installed payload.'
            Check (@(Get-ArtCraftInventory | Where-Object ProductCode -eq $grid.OldProductCode).Count -eq 1) 'Adoption changed the healthy MSI ProductCode.'
        }
        Case 'Custom native MSI upgrade preserves healthy machine path and does not explicitly remove old product' {
            Check ((Invoke-WithWingetLock { Invoke-ArtCraftInstall -PackageId $grid.PackageId }) -in @(0,3010)) 'Custom MSI upgrade failed.'
            Assert-Healthy $grid
            Check (@($script:msiCalls | Where-Object { $_ -like '/x *' }).Count -eq 0) 'Healthy old WinGet-managed installation was explicitly removed.'
            Check (@($script:msiCalls | Where-Object { $_ -like '/i *' }).Count -eq 1) 'Expected one normal MSI upgrade, not reinstall.'
        }
        Case 'Production worker repairs proven SYSTEM-AppData installation using verified signed native MSI' {
            $null = Run-FixtureMsi ('/i "{0}" ALLUSERS=2 MSIINSTALLPERUSER=1 INSTALLFOLDER="{1}" /qn /norestart' -f $pdf.OldMsi, $pdf.LegacyDir)
            $legacy = @(Get-ArtCraftInventory | Where-Object PackageId -eq $pdf.PackageId)
            Check ($legacy.Count -eq 1 -and $legacy[0].SystemAppData -and -not $legacy[0].Healthy) 'Could not prove actual SYSTEM-AppData legacy installation.'
            Invoke-ProcessQueueMode
            Assert-Healthy $pdf
            Check (-not (Test-Path -LiteralPath (Join-Path $pdf.LegacyDir 'pdfcraft.exe'))) 'Legacy SYSTEM-AppData executable remains.'
            Check (@(Get-ArtCraftInventory | Where-Object ProductCode -eq $pdf.OldProductCode).Count -eq 0) 'Old legacy MSI remains registered.'
        }
        Case 'Required gridcraft installs through shared queue with no individual Catalog GPO value' {
            Remove-ItemProperty -Path $PolicyCatalogRoot -Name oldgrid
            Check ((Invoke-WithWingetLock { Invoke-ArtCraftUninstall -PackageId $grid.PackageId }) -in @(0,3010)) 'Could not remove fixture for Required test.'
            $null = Update-InstalledPackagesSnapshot -WingetPath ''
            New-Item -Path $PolicyRequiredRoot -Force | Out-Null
            New-ItemProperty -Path $PolicyRequiredRoot -Name gridcraft -PropertyType String -Value 1 -Force | Out-Null
            New-ItemProperty -Path $PolicyRoot -Name EnforceRequired -PropertyType DWord -Value 1 -Force | Out-Null
            Check (@((Get-ItemProperty -Path $PolicyCatalogRoot).PSObject.Properties | Where-Object { [string]$_.Value -like '*ArtCraft.GridCraft*' }).Count -eq 0) 'Required test unexpectedly has a per-app ArtCraft Catalog value.'
            Invoke-ProcessQueueMode
            Assert-Healthy $grid
            $blocked = $false
            try { Add-SoftwareRequestToQueue -Action Uninstall -Alias gridcraft -RequestedBy CI -RequestedBySid CI | Out-Null } catch { $blocked = $true }
            Check $blocked 'Required built-in gridcraft accepted uninstall.'
        }
        Case 'Provider-independent snapshot survives unavailable WinGet and ownership survives checkbox-off' {
            $null = Update-InstalledPackagesSnapshot -WingetPath ''
            $snapshot = Get-Content -LiteralPath $InstalledPackagesPath -Raw | ConvertFrom-Json
            foreach ($package in @($grid,$pdf)) {
                Check ($package.PackageId -in $snapshot.InstalledPackageIds) 'Custom installed ID missing without WinGet.'
                Check (@($snapshot.Packages | Where-Object { $_.PackageId -eq $package.PackageId -and $_.Provider -eq 'ArtCraft' -and $_.Healthy }).Count -eq 1) 'Custom snapshot record missing.'
            }
            New-ItemProperty -Path $PolicyRoot -Name EnableArtCraft -PropertyType DWord -Value 0 -Force | Out-Null
            $before = $script:msiCalls.Count
            $httpBefore = $script:httpCalls
            Check ((Invoke-WithWingetLock { Invoke-ArtCraftUpdates }) -in @(0,3010)) 'Disabled provider update pass failed.'
            Check ($before -eq $script:msiCalls.Count -and $httpBefore -eq $script:httpCalls) 'Checkbox-off still performed MSI/network update.'
            foreach ($package in @($grid,$pdf)) { Check (Test-ArtCraftManagedPackage $package.PackageId) 'Checkbox-off lost durable ownership.' }
            $null = Update-InstalledPackagesSnapshot -WingetPath ''
            $disabledSnapshot = Get-Content -LiteralPath $InstalledPackagesPath -Raw | ConvertFrom-Json
            foreach ($package in @($grid,$pdf)) { Check ($package.PackageId -in $disabledSnapshot.InstalledPackageIds) 'Checkbox-off/WinGet absence lost installed custom snapshot.' }
            $null = Invoke-WithWingetLock { Invoke-WingetUpgradeAll -WingetPath $script:fixtureWinget }
            $wingetCalls = @(Get-Content -LiteralPath (Join-Path $Root 'winget-invocations.jsonl') | ForEach-Object { ,(ConvertFrom-Json $_) })
            Check (@($wingetCalls | Where-Object { $_ -contains '--all' -or ($_ -join ' ') -match 'ArtCraft\.' }).Count -eq 0) 'WinGet attempted to update custom-owned MSI or used upgrade --all.'
            $oldProviderCalls = @(Get-Content -LiteralPath (Join-Path (Split-Path $grid.LegacyWingetAdapter -Parent) 'winget-invocations.jsonl'))
            Check ($oldProviderCalls.Count -eq 2 -and $oldProviderCalls[0] -match '"install"' -and $oldProviderCalls[1] -match '"export"') 'Migrated product went back to its old WinGet adapter after initial install/inventory.'
        }
    }
    elseif ($Phase -eq 'ArtCraftInterrupt') {
        $word = Get-Package wordcraft
        $null = Run-FixtureMsi ('/i "{0}" ALLUSERS=2 MSIINSTALLPERUSER=1 INSTALLFOLDER="{1}" /qn /norestart' -f $word.OldMsi, $word.LegacyDir)
        New-ItemProperty -Path $PolicyRoot -Name EnableArtCraft -PropertyType DWord -Value 1 -Force | Out-Null
        $script:faultProductCode = $word.OldProductCode
        $null = Invoke-WithWingetLock { Invoke-ArtCraftInstall -PackageId $word.PackageId }
        throw 'Expected bounded after-removal process termination did not occur.'
    }
    elseif ($Phase -eq 'ArtCraftResume') {
        $word = Get-Package wordcraft
        Case 'Real process termination left a durable frozen Removing intent and verified MSI cache' {
            Check (-not (Test-ArtCraftEnabled)) 'Checkbox was not disabled at the real interruption boundary.'
            $intent = @(Get-ArtCraftOwnership | Where-Object PackageId -eq $word.PackageId)
            Check ($intent.Count -eq 1 -and $intent[0].Stage -eq 'Removing') 'Interrupted removal intent was not durable.'
            Check ($intent[0].Target.ProductCode -eq $word.ProductCode -and $intent[0].Target.Sha256 -eq $word.Sha256) 'Interrupted intent lost frozen MSI identity/hash.'
            Check (-not (Test-Path -LiteralPath (Join-Path $word.LegacyDir 'wordcraft.exe')) -and -not (Test-Path -LiteralPath $word.Executable)) 'Fault was not between real removal and install.'
            Check ((Get-AuthenticodeSignature -LiteralPath (Get-ArtCraftTargetPath (Get-ArtCraftDefinition $word.PackageId) $intent[0].Target)).Status -eq 'Valid') 'Verified signed MSI cache did not survive process termination.'
        }
        Case 'New native SYSTEM worker resumes removal intent safely even with checkbox off' {
            # No Latest/HTTP call is necessary: exactly the frozen verified cache
            # is consumed. Mutation and MSI verification remain production code.
            Invoke-ProcessQueueMode
            Assert-Healthy $word
            Check (@(Get-ArtCraftOwnership | Where-Object { $_.PackageId -eq $word.PackageId -and $_.Stage -eq 'Owned' }).Count -eq 1) 'Recovery did not complete ownership.'
            Check ($script:httpCalls -eq 0) 'Frozen recovery needlessly resolved a mutable network release.'
            Check (@($script:msiCalls | Where-Object { $_ -like '/x *' }).Count -eq 0) 'Recovery repeated already completed removal.'
            Check (@($script:msiCalls | Where-Object { $_ -like '/i *' }).Count -eq 1) 'Recovery did not perform exactly one installation.'
            Check ((Get-InstalledPackageIdSet).Contains($word.PackageId)) 'Recovered custom MSI is missing from the provider-independent snapshot.'
        }
    }
    else {
        foreach ($package in @($config.Packages)) {
            foreach ($product in @($package.OldProductCode, $package.ProductCode)) {
                foreach ($registration in @(Get-RegisteredApplications | Where-Object ProductCode -eq $product | Sort-Object Scope -Unique)) {
                    $null = Run-FixtureMsi ('/x ' + $product + $(if ($registration.Scope -eq 'machine') { ' ALLUSERS=1' } else { '' }) + ' /qn /norestart')
                }
            }
        }
    }
}
catch { $failed = $true; Write-Output ($_ | Out-String) }
finally {
    [pscustomobject]@{ Success = (-not $failed); Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name; Cases = @($script:cases) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Root "$Phase.result.json") -Encoding UTF8
    Stop-Transcript | Out-Null
}
if ($failed) { exit 1 }
