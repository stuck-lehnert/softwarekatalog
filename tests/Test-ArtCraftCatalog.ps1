# Portable integration of the real catalog, dispatch, snapshot and old-journal
# bridge. Only registry/installer/HTTP boundaries are replaced; real files remain.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
foreach ($name in @('ArtCraft.Catalog.ps1','ArtCraft.Provider.ps1')) {
    . ([scriptblock]::Create([IO.File]::ReadAllText((Join-Path (Join-Path $repo 'modules') $name), [Text.Encoding]::UTF8)))
}
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'setup.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($node in $ast.EndBlock.Statements) {
    if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($node.Extent.Text)) }
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('artcraft-catalog-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$passed=0
function Assert($Condition,[string]$Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Write-Log { param($Message,$Level); $script:log+=@([string]$Message) }
function Get-PolicyDword { param($Name,$Default=0); if ($script:policy.ContainsKey($Name)) { $script:policy[$Name] } else { $Default } }
function Get-PolicyStringValues { param($Path); if ($Path -eq $PolicyCatalogRoot) { $script:rows }; if ($Path -eq $PolicyRequiredRoot) { $script:required } }
function Get-ArtCraftOwnership { $script:owners }
function Get-ArtCraftInventory { $script:inventory }
function Complete-QueueItem { param($Id,$State,$ExitCode,$Message); $script:completion=[pscustomobject]@{State=$State;ExitCode=$ExitCode;Message=$Message} }
function Update-QueueItemProgress { param($Id,$Stage,$StageText,$IsIndeterminate) }
function Invoke-ArtCraftInstall { param($PackageId,$QueueItemId); $script:customCalls+=@('install '+$PackageId); $script:customCode }
function Invoke-ArtCraftUninstall { param($PackageId,$QueueItemId); $script:customCalls+=@('uninstall '+$PackageId); $script:customCode }
function Invoke-WingetInstall { param($WingetPath,$PackageId,$QueueItemId); throw 'Competing WinGet install invoked' }
function Invoke-WingetUninstall { param($WingetPath,$PackageId,$QueueItemId); throw 'Competing WinGet uninstall invoked' }
function Set-WingetOutputEncoding {}
function Invoke-WingetQuery { param($WingetPath,$Arguments); $script:wingetCalls+=@($Arguments -join ' '); [pscustomobject]@{ExitCode=0;Output=''} }
function Test([string]$Name,[scriptblock]$Body) {
    $script:BaseDir=Join-Path $root ([guid]::NewGuid().ToString('N')); Ensure-Directory $script:BaseDir
    $script:InstalledPackagesPath=Join-Path $script:BaseDir 'Installed-Packages.json'
    $script:ScopeRepairPath=Join-Path $script:BaseDir 'Scope-Repairs.json'
    $script:ScopeRepairFailures=@(); $script:WingetSourceName='winget'
    $script:PolicyRoot='policy'; $script:PolicyCatalogRoot='catalog'; $script:PolicyRequiredRoot='required'; $script:PolicyMaxEntries=500
    $script:policy=@{Enabled=1;EnableArtCraft=1}; $script:rows=@(); $script:required=@()
    $script:owners=@(); $script:inventory=@(); $script:log=@(); $script:customCalls=@(); $script:wingetCalls=@(); $script:completion=$null; $script:customCode=0
    try { & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { throw "FAIL ${Name}: $_ at $($_.ScriptStackTrace)" }
}
try {
    Test 'All 14 exact user catalog rows match the accepted source descriptions and MSI profiles' {
        $table=[IO.File]::ReadAllText((Join-Path $repo 'docs/artcraft-provider-plan.md'),[Text.Encoding]::UTF8)
        $definitions=@(Get-ArtCraftDefinitions); Assert ($definitions.Count -eq 14)
        Assert (@($definitions.PackageId | Select-Object -Unique).Count -eq 14)
        foreach ($d in $definitions) {
            Assert ($table.Contains("| $($d.Alias) | $($d.PackageId) | $($d.DisplayName) | $($d.Description) |"))
            Assert ($d.Repository -ceq ('storytold/'+$d.Alias))
            Assert ($d.Description -notmatch '^\|' -and $d.UpgradeCode -match '^\{[0-9A-F-]{36}\}$')
        }
        Assert (@($definitions | Where-Object InstallerScope -eq perMachine).Count -eq 2)
    }
    Test 'Opt-in offers builtins with no individual catalog policy rows' { Assert (@(Get-AppCatalogObjects).Count -eq 14) }
    Test 'Absent checkbox does not expand existing catalogs' { $script:policy.Remove('EnableArtCraft'); Assert (@(Get-AppCatalogObjects).Count -eq 0) }
    Test 'Global disable wins even with ArtCraft checkbox enabled' { $script:policy.Enabled=0; Assert (@(Get-AppCatalogObjects).Count -eq 0) }
    Test 'Legacy aliases resolve to custom provider without duplicate visible offers' {
        $script:rows=@([pscustomobject]@{Name='grid';Value='ArtCraft.GridCraft|Old name||Old description'})
        $apps=@(Get-AppCatalogObjects); Assert ($apps.Count -eq 15)
        Assert (@($apps | Where-Object Visible).Count -eq 14)
        $legacy=Get-AppCatalogObjectByAlias grid
        Assert ($legacy.Provider -eq 'ArtCraft' -and $legacy.DisplayName -eq 'GridCraft' -and -not $legacy.Visible)
    }
    Test 'Reserved aliases cannot substitute another package or download source' {
        $script:rows=@([pscustomobject]@{Name='gridcraft';Value='Attacker.Other|Bad|Bad'})
        Assert ((Get-AppCatalogObjectByAlias gridcraft).PackageId -eq 'ArtCraft.GridCraft')
        Assert ($script:log -match 'conflicts')
    }
    Test 'Required canonical and compatibility aliases protect the same package' {
        $script:rows=@([pscustomobject]@{Name='grid';Value='ArtCraft.GridCraft|Old|Old'})
        $script:required=@([pscustomobject]@{Name='grid';Value='1'})
        $set=Get-RequiredAliasSet; Assert ($set.Contains('gridcraft') -and $set.Contains('grid'))
        $item=[pscustomobject]@{Id='test';Alias='gridcraft';Action='Uninstall'}
        Invoke-QueuedItem $item ''
        Assert ($script:completion.State -eq 'Failed' -and $script:customCalls.Count -eq 0)
    }
    Test 'ArtCraft dispatch works without WinGet and does not use stale installed shortcut' {
        Set-Content $script:InstalledPackagesPath '{"InstalledPackageIds":["ArtCraft.GridCraft"]}'
        Invoke-QueuedItem ([pscustomobject]@{Id='test';Alias='gridcraft';Action='Install'}) ''
        Assert ($script:customCalls -contains 'install ArtCraft.GridCraft')
        Assert ($script:completion.State -eq 'Succeeded')
    }
    Test 'MSI 3010 succeeds with an explicit restart message' {
        $script:customCode=3010
        Invoke-QueuedItem ([pscustomobject]@{Id='test';Alias='gridcraft';Action='Install'}) ''
        Assert ($script:completion.State -eq 'Succeeded' -and $script:completion.ExitCode -eq 3010)
        Assert ($script:completion.Message -match 'Neustart')
    }
    Test 'Custom inventory merges atomically and excludes unhealthy or stale WinGet ArtCraft records' {
        Set-Content $script:InstalledPackagesPath '{"InstalledPackageIds":["ArtCraft.GridCraft","ArtCraft.PdfCraft","Vendor.Keep"]}'
        $script:inventory=@([pscustomobject]@{PackageId='ArtCraft.GridCraft';Version='1.0.0';Architecture='arm64';Scope='machine';Healthy=$true},
            [pscustomobject]@{PackageId='ArtCraft.PdfCraft';Version='0.1.0';Architecture='x64';Scope='user';Healthy=$false})
        $script:owners=@([pscustomobject]@{PackageId='ArtCraft.GridCraft';MetadataStale=$true;LastError='Offline';LastCheckedUtc='2026-11-12T00:00:00Z'})
        Assert (Update-InstalledPackagesSnapshot '')
        $s=Get-Content $script:InstalledPackagesPath -Raw | ConvertFrom-Json
        Assert ($s.InstalledPackageIds -contains 'Vendor.Keep' -and $s.InstalledPackageIds -contains 'ArtCraft.GridCraft')
        Assert ($s.InstalledPackageIds -notcontains 'ArtCraft.PdfCraft' -and -not $s.WingetRefreshed)
        Assert (@($s.Packages).Count -eq 2)
        $grid=@($s.Packages | Where-Object PackageId -eq 'ArtCraft.GridCraft')[0]
        Assert ($grid.Scope -eq 'machine') 'Snapshot lost the actual MSI registration scope'
        Assert ($grid.MetadataStale -and $grid.LastError -eq 'Offline') 'Snapshot lost stale-metadata diagnostics'
        # PS7 deserializes ISO dates as DateTime; the ARM runner is non-UTC.
        # Compare the actual instant, not its local wall-clock representation.
        Assert (([datetime]$grid.LastCheckedUtc).ToUniversalTime().Ticks -eq ([datetime]'2026-11-12T00:00:00Z').ToUniversalTime().Ticks) 'Snapshot changed the last successful check instant'
    }
    Test 'Malformed previous inventory is preserved in quarantine and rebuilt' {
        Set-Content $script:InstalledPackagesPath '[broken'
        Assert (Update-InstalledPackagesSnapshot '')
        Assert (@(Get-ChildItem $script:BaseDir -Filter 'Installed-Packages.corrupt-*.json').Count -eq 1)
        $s=Get-Content $script:InstalledPackagesPath -Raw | ConvertFrom-Json
        Assert (@($s.InstalledPackageIds).Count -eq 0)
    }
    Test 'WinGet only upgrades other packages; custom identities never reach it' {
        Set-Content $script:InstalledPackagesPath '{"InstalledPackageIds":["ArtCraft.GridCraft","Vendor.Other"]}'
        Assert ((Invoke-WingetUpgradeAll fake) -eq 0)
        Assert ($script:wingetCalls.Count -eq 1 -and $script:wingetCalls[0] -match '--id Vendor.Other ')
        Assert ($script:wingetCalls[0] -notmatch '--all|ArtCraft')
    }
    Test 'Ownership after checkbox-off still excludes an adopted package from WinGet' {
        $script:policy.EnableArtCraft=0; $script:owners=@([pscustomobject]@{PackageId='ArtCraft.GridCraft'})
        Set-Content $script:InstalledPackagesPath '{"InstalledPackageIds":["ArtCraft.GridCraft","Vendor.Other"]}'
        Assert ((Invoke-WingetUpgradeAll fake) -eq 0)
        Assert ($script:wingetCalls.Count -eq 1 -and $script:wingetCalls[0] -notmatch 'ArtCraft')
    }
    Test 'Old WinGet repair intent bridges even after the old product is already removed' {
        Set-Content $script:ScopeRepairPath '[{"PackageId":"ArtCraft.GridCraft","StartedAt":"2026-11-13"}]'
        Invoke-ArtCraftLegacyRepairMigration
        Assert ($script:customCalls -contains 'install ArtCraft.GridCraft')
        $parsed=Get-Content $script:ScopeRepairPath -Raw | ConvertFrom-Json; Assert (@($parsed).Count -eq 0)
    }
    Test 'A failed direct reinstall retains the old durable WinGet repair intent' {
        $script:customCode=1
        Set-Content $script:ScopeRepairPath '[{"PackageId":"ArtCraft.GridCraft","StartedAt":"2026-11-13"}]'
        Invoke-ArtCraftLegacyRepairMigration
        $parsed=Get-Content $script:ScopeRepairPath -Raw | ConvertFrom-Json
        Assert (@($parsed).Count -eq 1 -and $script:ScopeRepairFailures -contains 'ArtCraft.GridCraft')
    }
    Test 'Generated clients receive the same definition and merge function bodies' {
        $text=Get-ArtCraftClientFunctionText
        $expected=@(Get-ArtCraftDefinitions) | ConvertTo-Json -Depth 5
        $actual=& { . ([scriptblock]::Create($text)); @(Get-ArtCraftDefinitions) | ConvertTo-Json -Depth 5 }
        Assert ($actual -ceq $expected)
        Assert ($text.Contains('function Merge-ArtCraftCatalog') -and $text.Contains('function Get-AppCatalogObjects'))
    }
    Test 'Bundled source has no runtime dependency on module files' {
        $bundle=Get-BundledSoftwarekatalogSource (Join-Path $repo 'setup.ps1')
        Assert (-not [regex]::IsMatch($bundle,'(?m)^# <SoftwarekatalogModules>'))
        Assert ($bundle.Contains('function Invoke-ArtCraftInstall') -and $bundle.Contains('function Get-ArtCraftDefinitions'))
        $parsed=[Management.Automation.Language.Parser]::ParseInput($bundle,[ref]$tokens,[ref]$errors)
        Assert ($errors.Count -eq 0)
    }
    Write-Output "$passed tests passed."
}
finally { Remove-Item -LiteralPath $root -Recurse -Force }
