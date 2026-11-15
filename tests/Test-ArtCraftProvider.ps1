# Portable, dependency-free adversarial tests. OS/network/Authenticode boundaries
# are doubled here; real SYSTEM MSI/trust/native ARM execution is a separate lane.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = Split-Path $PSScriptRoot -Parent
. (Join-Path $repository 'modules/ArtCraft.Catalog.ps1')
. (Join-Path $repository 'modules/ArtCraft.Provider.ps1')
. (Join-Path $PSScriptRoot 'helpers/PortableFileSystem.ps1')
# Import this existing pure path classifier only, never setup's entry point.
$tokens=$null; $parseErrors=$null
$setupAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repository 'setup.ps1'),[ref]$tokens,[ref]$parseErrors)
$pathClassifier=$setupAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-SystemProfileAppDataPath'},$false)
if (-not $pathClassifier) { throw 'Missing production SYSTEM AppData path classifier.' }
Invoke-Expression $pathClassifier.Extent.Text
$providerOriginal = @{}
Get-Command -CommandType Function | Where-Object { $_.Name -match 'ArtCraft' } | ForEach-Object { $providerOriginal[$_.Name]=$_.ScriptBlock }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('softkat-artcraft-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$oldProgramFiles=$env:ProgramFiles; $oldProgramW6432=$env:ProgramW6432
$oldProgramFilesX86=${env:ProgramFiles(x86)}
$script:passed=0; $script:failed=0
function Assert($Condition,[string]$Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Equal($Expected,$Actual) { if ($Expected -cne $Actual) { throw "Expected <$Expected>; actual <$Actual>." } }
function Throws([scriptblock]$Body,[string]$Pattern) {
    try { & $Body | Out-Null } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw "Expected exception matching $Pattern."
}
function Mock([string]$Name,[scriptblock]$Body) { Set-Item -LiteralPath ('Function:script:'+$Name) -Value $Body }
function Restore([string]$Name) { Mock $Name $providerOriginal[$Name] }
function Test([string]$Name,[scriptblock]$Body) {
    try { Reset; & $Body; $script:passed++; Write-Output "PASS $Name" }
    catch { $script:failed++; Write-Output "FAIL $Name`: $($_.Exception.Message) at $($_.ScriptStackTrace)"; if ($script:logs.Count) { Write-Output ('  Provider diagnostics: '+($script:logs -join ' | ')) } }
}
function New-Installed([string]$Version='1.0.0',[string]$Architecture='x64',[bool]$Healthy=$true) {
    [pscustomobject]@{ PackageId=$script:definition.PackageId; Alias=$script:definition.Alias; Version=$Version; Architecture=$Architecture;
        Healthy=$Healthy; Ambiguous=$false; Scope='machine'; ProductCode='{11111111-1111-1111-1111-111111111111}';
        InstallLocation=(Join-Path $env:ProgramFiles 'MaterialCraft'); ExecutablePath=''; SystemAppData=$false }
}
function Reset {
    foreach ($name in $providerOriginal.Keys) { Restore $name }
    $script:BaseDir=Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($BaseDir)
    $env:ProgramFiles=Join-Path $BaseDir 'Program Files'; $env:ProgramW6432=$env:ProgramFiles
    ${env:ProgramFiles(x86)}=Join-Path $BaseDir 'Program Files (x86)'
    [void][IO.Directory]::CreateDirectory($env:ProgramFiles)
    $script:enabled=$true; $script:system=$true; $script:native='x64'; $script:offline=$false
    $script:inventory=@(); $script:msiCalls=@(); $script:releaseCalls=0; $script:verifyCalls=0; $script:failAfterRemoval=$false
    $script:installCode=0; $script:removeCode=0; $script:installRegisters=$true; $script:logs=@(); $script:logLevels=@()
    $script:definition=Get-ArtCraftDefinition 'ArtCraft.MaterialCraft'
    $script:target=[pscustomobject]@{ Tag='v2.0.0'; Version='2.0.0'; Architecture='x64'; AssetName='materialcraft-2.0.0-windows-x64.msi'; Sha256=('a'*64); ProductCode='{22222222-2222-2222-2222-222222222222}' }
    Mock Get-PolicyDword { param($Name,$Default) if ($script:enabled) { 1 } else { 0 } }
    Mock Test-RunningAsLocalSystem { $script:system }
    Mock Ensure-Directory { param($Path) [void][IO.Directory]::CreateDirectory($Path) }
    Mock Set-DirectoryAcl { param($Path,$UsersCanModify) Assert (-not $UsersCanModify) 'Provider requested writable user storage.' }
    Mock Write-Log { param($Message,$Level) $script:logs+=@($Message); $script:logLevels+=@($Level) }
    Mock Get-NativeWindowsArchitecture { $script:native }
    Mock Get-ArtCraftInventory { $script:inventory }
    Mock Resolve-ArtCraftRelease {
        param($Definition)
        $script:releaseCalls++; if ($script:offline) { throw 'Offline metadata; preserve last checked state.' }
        $script:target.PSObject.Copy()
    }
    Mock Save-ArtCraftInstaller {
        param($Definition,$Target)
        $script:verifyCalls++; Assert-ArtCraftTarget $Definition $Target
        Get-ArtCraftTargetPath $Definition $Target
    }
    Mock Open-ArtCraftInstallerLease {
        param($Definition, $Target)
        $path = Save-ArtCraftInstaller -Definition $Definition -Target $Target
        [pscustomobject]@{ Path = $path; Stream = (New-Object IO.MemoryStream) }
    }
    Mock Invoke-ArtCraftMsi {
        param($Arguments)
        $record=@(Get-ArtCraftOwnership)[0]
        Assert ($record.Stage -in @('Removing','Installing','Uninstalling')) 'MSI ran before durable intent.'
        $script:msiCalls+=@($Arguments)
        if ($Arguments.StartsWith('/x ')) {
            if ($script:removeCode -in @(0,3010)) { $script:inventory=@() }
            if ($script:failAfterRemoval) { throw 'Injected crash after actual source removal.' }
            return $script:removeCode
        }
        Assert ($Arguments.Contains('ALLUSERS=1 MSIINSTALLPERUSER=""')) 'Dual-context user property leaked.'
        if ($script:installRegisters -and $script:installCode -in @(0,3010)) {
            $installed=New-Installed $record.Target.Version $record.Target.Architecture $true
            $installed.ProductCode=$record.Target.ProductCode; $installed.InstallLocation=$record.InstallLocation
            $script:inventory=@($installed)
        }
        $script:installCode
    }
}

try {
    Test 'Fixed catalog has exactly fourteen canonical identities and no wildcard routing' {
        Equal 14 @(Get-ArtCraftDefinitions).Count
        Assert (-not (Test-ArtCraftManagedPackage 'ArtCraft.Untrusted'))
        Assert (Test-ArtCraftManagedPackage 'artcraft.MaterialCraft')
        Equal 'ArtCraft.MaterialCraft' (Get-ArtCraftDefinition 'ARTCRAFT.materialcraft').PackageId
        Throws { Get-ArtCraftDefinition 'ArtCraft.MaterialCraft;cmd' } 'Unknown'
    }
    Test 'Healthy installed MSI is adopted durably without network or reinstall' {
        $script:inventory=@(New-Installed)
        Equal 0 (Initialize-ArtCraftProvider)
        Equal 0 $script:releaseCalls; Equal 0 $script:msiCalls.Count
        $owned=@(Get-ArtCraftOwnership); Equal 1 $owned.Count; Equal '1.0.0' $owned[0].Version
        Assert (($script:logs -join '|') -match 'adopted healthy machine MSI version=1\.0\.0.*without reinstall')
        Equal 'INFO' $script:logLevels[0]
        Equal 0 (Initialize-ArtCraftProvider)
        Equal 1 @($script:logs | Where-Object { $_ -match 'adopted healthy' }).Count
        $script:enabled=$false; Assert (Test-ArtCraftManagedPackage $definition.PackageId)
        Equal 0 (Invoke-ArtCraftUpdates); Equal 0 $script:releaseCalls
    }
    Test 'Disabled and unowned package remains outside the provider' {
        $script:enabled=$false; Assert (-not (Test-ArtCraftManagedPackage $definition.PackageId))
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId); Equal 0 $script:msiCalls.Count
    }
    Test 'Case-insensitive external identities remain managed after opt-out, with canonical durable records' {
        Equal 0 (Invoke-ArtCraftInstall 'artcraft.MATERIALCRAFT')
        Equal 'ArtCraft.MaterialCraft' @(Get-ArtCraftOwnership)[0].PackageId
        $script:enabled=$false
        Assert (Test-ArtCraftManagedPackage 'ARTCRAFT.materialcraft')
        Equal 0 (Invoke-ArtCraftUninstall 'artcraft.Materialcraft')
        Assert (Test-ArtCraftManagedPackage 'ArTcRaFt.MaTeRiAlCrAfT')
        $r=@(Get-ArtCraftOwnership)[0]; $r.PackageId='artcraft.materialcraft'
        Write-ArtCraftState ([pscustomobject]@{SchemaVersion=1;Records=@($r)})
        Throws { Get-ArtCraftOwnership } 'Invalid|duplicate'
    }
    Test 'SYSTEM is enforced before mutation or storage creation' {
        $script:system=$false; Equal 1 (Initialize-ArtCraftProvider)
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId); Equal 0 $script:msiCalls.Count
        Assert (-not (Test-Path (Join-Path $BaseDir 'ArtCraft')))
    }
    foreach ($raw in @('[]','42','null','[{"SchemaVersion":1,"Records":[]}]','{"SchemaVersion":2,"Records":[]}','{"SchemaVersion":true,"Records":[]}','{"SchemaVersion":"1","Records":[]}','{"SchemaVersion":1,"Records":{}}','{"SchemaVersion":1}')) {
        Test "Corrupt ownership fails closed: $raw" {
            Initialize-ArtCraftStorage
            [IO.File]::WriteAllText((Join-Path (Get-ArtCraftRoot) 'State.json'),$raw)
            $script:enabled=$false
            Throws { Get-ArtCraftOwnership } 'object|schema|property'
            Throws { Test-ArtCraftManagedPackage $definition.PackageId } 'object|schema|property'
            Equal 1 (Initialize-ArtCraftProvider); Equal 0 $script:msiCalls.Count
            Equal $raw ([IO.File]::ReadAllText((Join-Path (Get-ArtCraftRoot) 'State.json')))
        }
    }
    Test 'Duplicate ownership and malformed target reject without resetting state' {
        Initialize-ArtCraftStorage; $r=New-ArtCraftRecord $definition
        Write-ArtCraftState ([pscustomobject]@{SchemaVersion=1;Records=@($r,$r)})
        Throws { Get-ArtCraftOwnership } 'duplicate'
        $r.Stage='Prepared'; $r.Target=$target.PSObject.Copy(); $r.Target.AssetName='../evil.msi'
        Write-ArtCraftState ([pscustomobject]@{SchemaVersion=1;Records=@($r)})
        Throws { Get-ArtCraftOwnership } 'target'
    }
    Test 'Healthy older machine update never removes the old product first' {
        $script:inventory=@(New-Installed)
        Equal 0 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal 1 $script:msiCalls.Count; Assert ($script:msiCalls[0].StartsWith('/i '))
        Equal 'Owned' @(Get-ArtCraftOwnership)[0].Stage
        Equal '2.0.0' @(Get-ArtCraftOwnership)[0].Version
    }
    Test 'Equal/newer healthy installations are adopted but never downgraded or reinstalled' {
        foreach ($version in @('2.0.0','3.0.0')) {
            $script:inventory=@(New-Installed $version)
            Equal 0 (Invoke-ArtCraftInstall $definition.PackageId)
        }
        Equal 0 $script:msiCalls.Count; Equal 0 $script:verifyCalls
    }
    Test 'Offline resolution leaves healthy adoption intact and never removes an old product' {
        $script:inventory=@(New-Installed); $script:offline=$true
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal 'Owned' @(Get-ArtCraftOwnership)[0].Stage; Equal 0 $script:msiCalls.Count
        Assert (@(Get-ArtCraftOwnership)[0].LastError -match 'Offline')
    }
    Test 'Offline verified frozen cache upgrades older machine version but preserves stale metadata and check time' {
        Initialize-ArtCraftStorage
        $r=New-ArtCraftRecord $definition; $r.Target=$target; $r.LastCheckedUtc='2020-01-01T00:00:00.0000000Z'; $r.LatestVersion='2.0.0'
        Set-ArtCraftRecord $r
        [IO.File]::WriteAllText((Get-ArtCraftTargetPath $definition $target),'previously verified cache boundary')
        Mock Resolve-ArtCraftRelease { param($Definition) throw (New-ArtCraftNetworkException 'Offline/rate-limited metadata.') }
        $script:inventory=@(New-Installed '1.0.0')
        Equal 0 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal 1 $script:msiCalls.Count; Assert ($script:verifyCalls -ge 3)
        $r=@(Get-ArtCraftOwnership)[0]; Assert $r.MetadataStale; Assert ($r.LastError -match 'Offline')
        Assert ($script:logLevels -contains 'WARN')
        Assert (($script:logs -join '|') -match 'metadata unavailable/offline; last successful check retained')
        Assert (($script:logs -join '|') -notmatch 'https?://')
        Equal ([datetime]'2020-01-01T00:00:00Z').ToUniversalTime().Ticks ([datetime]$r.LastCheckedUtc).ToUniversalTime().Ticks; Equal '2.0.0' $r.Version
        $script:inventory=@(New-Installed '3.0.0')
        Equal 0 (Invoke-ArtCraftInstall $definition.PackageId); Equal 1 $script:msiCalls.Count
    }
    Test 'Offline fallback cannot download missing cache or bypass native identity/version rejection' {
        Initialize-ArtCraftStorage; $r=New-ArtCraftRecord $definition; $r.Target=$target; Set-ArtCraftRecord $r
        Mock Resolve-ArtCraftRelease { param($Definition) throw (New-ArtCraftNetworkException 'Offline.') }
        $script:inventory=@(New-Installed '1.0.0' 'arm64' $false)
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId); Equal 0 $script:verifyCalls; Equal 0 $script:msiCalls.Count
        [IO.File]::WriteAllText((Get-ArtCraftTargetPath $definition $target),'old cache')
        Mock Save-ArtCraftInstaller { throw 'Cached hash/signature identity rejected.' }
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId); Equal 0 $script:msiCalls.Count
        Mock Resolve-ArtCraftRelease { throw 'Malformed stable tag or missing native asset.' }
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId); Equal 0 $script:msiCalls.Count
    }
    Test 'SYSTEM-AppData migration verifies first then records intent before exact GUID removal' {
        $old=New-Installed '1.0.0' 'x64' $false; $old.Scope='user'; $old.SystemAppData=$true; $old.InstallLocation='SYSTEM-AppData'
        $script:inventory=@($old)
        Equal 0 (Invoke-ArtCraftInstall $definition.PackageId)
        Assert ($script:verifyCalls -ge 2); Equal 2 $script:msiCalls.Count
        Assert ($script:msiCalls[0].StartsWith('/x '+$old.ProductCode+' ')); Assert ($script:msiCalls[1].StartsWith('/i '))
        Assert (@(Get-ArtCraftOwnership)[0].InstallLocation.StartsWith($env:ProgramFiles))
        Assert (($script:logs -join '|') -match 'verified native target.*durable migration intent saved before mutation.*removing registered MSI.*removal verified.*verified healthy machine installation')
        Assert (($script:logs -join '|').Contains(('product='+$old.ProductCode+', scope=user')))
        Assert (($script:logs -join '|') -notmatch 'https?://')
    }
    Test 'Crash after destructive removal resumes the frozen target even after policy disabled' {
        $old=New-Installed '1.0.0' 'arm64' $false; $script:inventory=@($old); $script:failAfterRemoval=$true
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal 'Removing' @(Get-ArtCraftOwnership)[0].Stage; Equal 0 $script:inventory.Count
        $script:enabled=$false; $script:offline=$true; $script:failAfterRemoval=$false
        Equal 0 (Initialize-ArtCraftProvider); Equal 'Owned' @(Get-ArtCraftOwnership)[0].Stage
        Equal 1 $script:releaseCalls; Equal 2 $script:msiCalls.Count
        Assert (($script:logs -join '|') -match 'resuming durable stage=Removing.*verified healthy machine installation')
    }
    Test 'Invalid destination cache blocks destruction and retains the installed source' {
        $old=New-Installed '1.0.0' 'arm64' $false; $script:inventory=@($old)
        Mock Save-ArtCraftInstaller { throw 'Hash/signature/identity rejected.' }
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal 1 $script:inventory.Count; Equal 0 $script:msiCalls.Count
    }
    Test 'Changed/newer source during crash recovery is not removed or downgraded' {
        Initialize-ArtCraftStorage; $old=New-Installed '3.0.0' 'arm64' $false; $script:inventory=@($old)
        $r=New-ArtCraftRecord $definition; $r.Stage='Removing'; $r.Target=$target
        $r.Sources=@([pscustomobject]@{ProductCode=$old.ProductCode;Scope='machine'}); $r.InstallLocation=Join-Path $env:ProgramFiles 'MaterialCraft'
        Set-ArtCraftRecord $r; Equal 1 (Initialize-ArtCraftProvider)
        Equal 0 $script:msiCalls.Count; Equal 1 $script:inventory.Count
    }
    Test 'Prepared intent does not begin removal after policy disabled' {
        Initialize-ArtCraftStorage; $r=New-ArtCraftRecord $definition; $r.Stage='Prepared'; $r.Target=$target
        Set-ArtCraftRecord $r; $script:enabled=$false
        Equal 0 (Initialize-ArtCraftProvider); Equal 1 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal 0 $script:msiCalls.Count; Equal 'Prepared' @(Get-ArtCraftOwnership)[0].Stage
    }
    Test 'Corrupt unsafe recovery destination blocks source removal, not merely later installation' {
        Initialize-ArtCraftStorage; $old=New-Installed '1.0.0' 'arm64' $false; $script:inventory=@($old)
        $r=New-ArtCraftRecord $definition; $r.Stage='Removing'; $r.Target=$target
        $r.Sources=@([pscustomobject]@{ProductCode=$old.ProductCode;Scope='machine'}); $r.InstallLocation=Join-Path $BaseDir 'UserWritable'
        Set-ArtCraftRecord $r; Equal 1 (Initialize-ArtCraftProvider)
        Equal 0 $script:msiCalls.Count; Equal 1 $script:inventory.Count
    }
    Test 'Ambiguous duplicate scopes and ordinary user contexts never become destructive targets' {
        $old=New-Installed '1.0.0' 'arm64' $false; $old.Ambiguous=$true; $script:inventory=@($old)
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal 1 (Invoke-ArtCraftUninstall $definition.PackageId)
        $old.Ambiguous=$false; $old.Scope='user'; Equal 1 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal 1 (Invoke-ArtCraftUninstall $definition.PackageId); Equal 0 $script:msiCalls.Count
    }
    Test 'Wrong-architecture native migration refuses a version downgrade' {
        $script:inventory=@(New-Installed '3.0.0' 'arm64' $false)
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId); Equal 0 $script:msiCalls.Count
    }
    Test 'MSI 3010 persists reboot-required and is successful only after real postcheck' {
        $script:installCode=3010
        Equal 3010 (Invoke-ArtCraftInstall $definition.PackageId)
        Assert @(Get-ArtCraftOwnership)[0].RebootRequired
        Equal 'Owned' @(Get-ArtCraftOwnership)[0].Stage
    }
    Test 'MSI success without correct machine registration fails and preserves Installing recovery' {
        $script:installRegisters=$false
        Equal 1 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal 'Installing' @(Get-ArtCraftOwnership)[0].Stage
    }
    foreach ($code in @(1618,1641,1603)) {
        Test "MSI error $code does not become success" {
            $script:installCode=$code
            $expected=if ($code -eq 1618) {1618} else {1}
            Equal $expected (Invoke-ArtCraftInstall $definition.PackageId)
            Equal 'Installing' @(Get-ArtCraftOwnership)[0].Stage
        }
    }
    Test 'Uninstall uses registered GUID only and retains durable provider ownership' {
        $script:inventory=@(New-Installed)
        Equal 0 (Invoke-ArtCraftUninstall $definition.PackageId)
        Equal 1 $script:msiCalls.Count; Assert ($script:msiCalls[0].StartsWith('/x {11111111-1111-1111-1111-111111111111} '))
        Assert ($script:msiCalls[0].Contains(' ALLUSERS=1 '))
        $script:enabled=$false; Assert (Test-ArtCraftManagedPackage $definition.PackageId)
        Equal '' @(Get-ArtCraftOwnership)[0].Version
    }
    Test 'Updates touch installed families only and persist freshness rather than install all offers' {
        $script:inventory=@(New-Installed)
        Equal 0 (Invoke-ArtCraftUpdates); Equal 1 $script:releaseCalls; Equal 1 $script:msiCalls.Count
        Equal 0 (Invoke-ArtCraftUpdates); Equal 1 $script:releaseCalls
        $script:inventory=@(); Equal 0 (Invoke-ArtCraftUpdates); Equal 1 $script:releaseCalls
    }
    Test 'Expired UTC JSON freshness is not shifted into the future by a non-UTC local timezone' {
        Initialize-ArtCraftStorage
        $r=New-ArtCraftRecord $definition; $r.LastCheckedUtc=[datetime]::UtcNow.AddHours(-3).ToString('o'); Set-ArtCraftRecord $r
        $script:inventory=@(New-Installed)
        Equal 0 (Invoke-ArtCraftUpdates)
        Equal 1 $script:releaseCalls; Equal 1 $script:msiCalls.Count
    }
    Test 'Stable version parser rejects prerelease, injection, x86 and MSI overflow' {
        foreach ($version in @('v1.0.0','1.0','01.2.3','1.2.3-beta','1.2.3/evil','256.1.1','1.256.1','1.1.65536')) {
            Throws { ConvertTo-ArtCraftVersion $version } 'version|Version'
        }
        $bad=$target.PSObject.Copy(); $bad.Architecture='x86'; Throws { Assert-ArtCraftTarget $definition $bad } 'target'
    }
    Test 'Checksums require exactly one complete exact native asset row' {
        $line=('a'*64)+'  '+$target.AssetName
        Equal ('a'*64) (Get-ArtCraftChecksum $line $target.AssetName)
        Throws { Get-ArtCraftChecksum ($line+"`n"+$line) $target.AssetName } 'duplicate'
        Throws { Get-ArtCraftChecksum (('b'*64)+'  wrong.msi') $target.AssetName } 'Missing'
        Throws { Get-ArtCraftChecksum ('bad  '+$target.AssetName) $target.AssetName } 'Malformed'
        Throws { Get-ArtCraftChecksum (('a'*64)+'  ../'+$target.AssetName) $target.AssetName } 'Missing'
    }
    Test 'Latest and asset URI allowlists reject downgrade/off-repo/off-host/credentials/ports' {
        $good='https://github.com/storytold/materialcraft/releases/latest'
        Assert-ArtCraftHttpUri ([uri]$good) $definition -Latest
        Assert-ArtCraftHttpUri ([uri]'https://github.com/storytold/materialcraft/releases/tag/v2.0.0') $definition -Latest
        foreach ($uri in @($good.Replace('https:','http:'),$good.Replace('materialcraft','other'),$good.Replace('github.com','github.com.evil'),$good.Replace('github.com','user@github.com'),$good.Replace('github.com','github.com:444'),($good+'?x=1'),($good+'#x'))) {
            Throws { Assert-ArtCraftHttpUri ([uri]$uri) $definition -Latest } 'Unsafe|repository'
        }
        Assert-ArtCraftHttpUri ([uri]'https://release-assets.githubusercontent.com/github-production-release-asset/123?sig=1') $definition $target.Tag $target.AssetName
        Throws { Assert-ArtCraftHttpUri ([uri]'https://evil.example/file.msi') $definition $target.Tag $target.AssetName } 'host'
        Throws { Assert-ArtCraftHttpUri ([uri]'https://github.com/storytold/materialcraft/releases/download/v1.0.0/other.msi') $definition $target.Tag $target.AssetName } 'frozen'
    }
    Test 'Resolution freezes latest stable tag and demands native ARM64 asset, no emulation fallback' {
        Restore Resolve-ArtCraftRelease; $script:native='arm64'; $script:httpCalls=@()
        Mock Invoke-ArtCraftHttp {
            param($Uri,$Definition,$Tag,$AssetName,[switch]$Latest,$Destination,$MaxBytes)
            $script:httpCalls+=@([string]$Uri)
            if ($Latest) { return [pscustomobject]@{Uri=[uri]'https://github.com/storytold/materialcraft/releases/tag/v2.0.0';Text=$null} }
            [pscustomobject]@{Uri=[uri]$Uri;Text=(('a'*64)+'  materialcraft-2.0.0-windows-arm64.msi')}
        }
        $resolved=Resolve-ArtCraftRelease $definition
        Equal 'arm64' $resolved.Architecture; Equal 'materialcraft-2.0.0-windows-arm64.msi' $resolved.AssetName
        Equal 2 $script:httpCalls.Count; Assert ($script:httpCalls[1].Contains('/v2.0.0/SHA256SUMS.txt'))
        $script:native='x64'; Throws { Resolve-ArtCraftRelease $definition } 'Missing'
        $script:native='x86'; Throws { Resolve-ArtCraftRelease $definition } 'native'
    }
    Test 'Prerelease/nightly/off-repository latest tags are not accepted' {
        Restore Resolve-ArtCraftRelease
        foreach ($suffix in @('v2.0.0-beta','nightly','v2.0.0?draft=1','v2.0.0/evil')) {
            $script:badLatest='https://github.com/storytold/materialcraft/releases/tag/'+$suffix
            Mock Invoke-ArtCraftHttp { [pscustomobject]@{Uri=[uri]$script:badLatest;Text=''} }
            Throws { Resolve-ArtCraftRelease $definition } 'tag|release'
        }
    }
    Test 'Real HTTP control flow follows bounded HEAD redirects without sending to unapproved hosts' {
        Restore Invoke-ArtCraftHttp; Add-Type -AssemblyName System.Net.Http
        $script:sent=@(); $script:redirectTo='https://github.com/storytold/materialcraft/releases/tag/v2.0.0'
        Mock Send-ArtCraftHttpRequest {
            param($Client,$Request,$CancellationToken)
            $script:sent+=@($Request.Method.Method+' '+$Request.RequestUri.AbsoluteUri)
            if ($script:sent.Count -eq 1) {
                $response=New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]::Found)
                $response.Headers.Location=[uri]$script:redirectTo; return $response
            }
            New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]::OK)
        }
        $result=Invoke-ArtCraftHttp -Uri 'https://github.com/storytold/materialcraft/releases/latest' -Definition $definition -Latest
        Equal $script:redirectTo $result.Uri.AbsoluteUri; Equal 2 $script:sent.Count; Assert ($script:sent[0].StartsWith('HEAD '))
        $script:sent=@(); $script:redirectTo='https://evil.example/tag/v2.0.0'
        Throws { Invoke-ArtCraftHttp -Uri 'https://github.com/storytold/materialcraft/releases/latest' -Definition $definition -Latest } 'repository'
        Equal 1 $script:sent.Count
    }
    Test 'Real HTTP redirect loops are capped and missing redirect locations are rejected' {
        Restore Invoke-ArtCraftHttp; Add-Type -AssemblyName System.Net.Http; $script:sent=0
        Mock Send-ArtCraftHttpRequest {
            param($Client,$Request,$CancellationToken)
            $script:sent++; $response=New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]::Found)
            $response.Headers.Location=[uri]'https://github.com/storytold/materialcraft/releases/latest'; $response
        }
        Throws { Invoke-ArtCraftHttp -Uri 'https://github.com/storytold/materialcraft/releases/latest' -Definition $definition -Latest } 'redirect limit'
        Equal 6 $script:sent
        Mock Send-ArtCraftHttpRequest { param($Client,$Request,$CancellationToken) New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]::Found) }
        Throws { Invoke-ArtCraftHttp -Uri 'https://github.com/storytold/materialcraft/releases/latest' -Definition $definition -Latest } 'Location'
    }
    Test 'Real HTTP body reader enforces streaming limit even when Content-Length lies; 429 stays failure' {
        Restore Invoke-ArtCraftHttp; Add-Type -AssemblyName System.Net.Http
        Mock Send-ArtCraftHttpRequest {
            param($Client,$Request,$CancellationToken)
            $response=New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]::OK)
            $response.Content=New-Object Net.Http.StringContent('12345678901234567890')
            $response.Content.Headers.ContentLength=1; $response
        }
        $uri='https://github.com/storytold/materialcraft/releases/download/v2.0.0/SHA256SUMS.txt'
        Throws { Invoke-ArtCraftHttp -Uri $uri -Definition $definition -Tag 'v2.0.0' -AssetName 'SHA256SUMS.txt' -MaxBytes 8 } 'size/time'
        Mock Send-ArtCraftHttpRequest { param($Client,$Request,$CancellationToken) New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]429) }
        Throws { Invoke-ArtCraftHttp -Uri $uri -Definition $definition -Tag 'v2.0.0' -AssetName 'SHA256SUMS.txt' } '429'
    }
    Test 'Hash, exact signer DN, MSI family, version and native architecture are independently enforced' {
        Initialize-ArtCraftStorage
        $file=Join-Path (Get-ArtCraftRoot) 'Cache/sample.msi'; [IO.File]::WriteAllText($file,'deterministic synthetic bytes')
        $target.Sha256=(Get-FileHash $file -Algorithm SHA256).Hash
        $script:signatureStatus='Valid'; $script:signer=@(Get-ArtCraftAllowedSignerSubjects)[0]
        $script:msiMetadata=[pscustomobject]@{ProductCode=$target.ProductCode;UpgradeCode=$definition.UpgradeCode;Version=$target.Version;Architecture=$target.Architecture}
        Mock Get-AuthenticodeSignature {
            param($LiteralPath)
            [pscustomobject]@{Status=$script:signatureStatus;SignerCertificate=[pscustomobject]@{SubjectName=(New-Object Security.Cryptography.X509Certificates.X500DistinguishedName($script:signer))}}
        }
        Mock Get-ArtCraftMsiMetadata { $script:msiMetadata }
        Equal $target.ProductCode (Assert-ArtCraftInstaller $definition $target $file).ProductCode
        $target.Sha256='b'*64; Throws { Assert-ArtCraftInstaller $definition $target $file } 'SHA256'
        $target.Sha256=(Get-FileHash $file -Algorithm SHA256).Hash
        $script:signatureStatus='UnknownError'; Throws { Assert-ArtCraftInstaller $definition $target $file } 'signature'
        $script:signatureStatus='Valid'; $script:signer='CN=Learning Machines Inc, O=Untrusted Ltd, C=US'
        Throws { Assert-ArtCraftInstaller $definition $target $file } 'signer'
        $script:signer=@(Get-ArtCraftAllowedSignerSubjects)[0]
        foreach ($field in @('UpgradeCode','Version','Architecture','ProductCode')) {
            $saved=$script:msiMetadata.$field; $script:msiMetadata.$field='wrong'
            Throws { Assert-ArtCraftInstaller $definition $target $file } 'identity'
            $script:msiMetadata.$field=$saved
        }
    }
    Test 'Installer is reverified after locking and its lease spans dispatch including failure cleanup' {
        Restore Open-ArtCraftInstallerLease
        $originalReader = ${function:Open-TrustedFileRead}
        $script:heldInstaller = $null
        Mock Open-TrustedFileRead {
            param($Path)
            $script:heldInstaller = New-Object IO.MemoryStream
            return $script:heldInstaller
        }
        Mock Assert-ArtCraftInstallerContent {
            param($Definition, $Target, $Path)
            Assert $script:heldInstaller.CanRead 'Verification happened without a live content lease.'
            [pscustomobject]@{ ProductCode = $Target.ProductCode }
        }
        Mock Invoke-ArtCraftRecordCore {
            param($Record, $InstallerPath)
            Assert $script:heldInstaller.CanRead 'Destructive dispatch outlived the installer lease.'
            Assert ([bool]$InstallerPath) 'Dispatch did not receive the verified installer path.'
            return 0
        }
        $record = [pscustomobject]@{ PackageId = $definition.PackageId; Stage = 'Prepared'; Target = $target }
        try {
            Equal 0 (Invoke-ArtCraftRecord -Record $record)
            Assert (-not $script:heldInstaller.CanRead) 'Success leaked a content lease.'
            Mock Invoke-ArtCraftRecordCore {
                param($Record, $InstallerPath)
                Assert $script:heldInstaller.CanRead 'Failure dispatch ran without its lease.'
                throw 'Injected dispatch failure'
            }
            Throws { Invoke-ArtCraftRecord -Record $record } 'Injected dispatch failure'
            Assert (-not $script:heldInstaller.CanRead) 'Dispatch failure leaked a content lease.'
            Mock Assert-ArtCraftInstallerContent { throw 'Injected verification failure' }
            Throws { Open-ArtCraftInstallerLease -Definition $definition -Target $target } 'Injected verification failure'
            Assert (-not $script:heldInstaller.CanRead) 'Verification failure leaked a content lease.'
        }
        finally { Mock Open-TrustedFileRead $originalReader }
    }
    Test 'Atomic cache verifies partial file before publication and revalidates cached reuse' {
        Initialize-ArtCraftStorage; Restore Save-ArtCraftInstaller; $script:validated=@(); $script:downloads=0
        Mock Invoke-ArtCraftHttp { param($Uri,$Definition,$Tag,$AssetName,$Destination,$MaxBytes) $script:downloads++; [IO.File]::WriteAllText($Destination,'fixture'); [pscustomobject]@{Uri=[uri]$Uri;Text=$null} }
        Mock Assert-ArtCraftInstaller { param($Definition,$Target,$Path) $script:validated+=@($Path); [pscustomobject]@{ProductCode=$Target.ProductCode} }
        $path=Save-ArtCraftInstaller $definition $target
        Assert (Test-Path $path); Assert ($script:validated[0].EndsWith('.partial'))
        Equal $path (Save-ArtCraftInstaller $definition $target); Equal 1 $script:downloads; Equal $path $script:validated[1]
        Mock Assert-ArtCraftInstaller { throw 'Cache was modified.' }
        Throws { Save-ArtCraftInstaller $definition $target } 'modified'
        Equal 1 $script:downloads
    }
    Test 'Rejected downloaded MSI is not published and leaves no executable partial cache' {
        Initialize-ArtCraftStorage; Restore Save-ArtCraftInstaller
        Mock Invoke-ArtCraftHttp { param($Uri,$Definition,$Tag,$AssetName,$Destination,$MaxBytes) [IO.File]::WriteAllText($Destination,'bad') }
        Mock Assert-ArtCraftInstaller { throw 'Wrong signer.' }
        Throws { Save-ArtCraftInstaller $definition $target } 'signer'
        Equal 0 @(Get-ChildItem -LiteralPath (Join-Path (Get-ArtCraftRoot) 'Cache')).Count
    }
    Test 'Inventory uses validated MSI identity, targeted fallback and real scope, not display name alone' {
        Restore Get-ArtCraftInventory; $script:evidenceCalls=0
        $script:reg=[pscustomobject]@{ProductCode='{11111111-1111-1111-1111-111111111111}';DisplayName='MaterialCraft';WindowsInstaller=$true;Scope='machine';InstallLocation=(Join-Path $env:ProgramFiles 'MaterialCraft')}
        [void][IO.Directory]::CreateDirectory($script:reg.InstallLocation)
        [IO.File]::WriteAllText((Join-Path $script:reg.InstallLocation 'materialcraft.exe'),'exe')
        Mock Get-RegisteredApplications { param([switch]$IncludeUnnamed) $script:reg }
        Mock Get-ArtCraftRelatedProducts { param($Definition) if ($Definition.PackageId -ceq $script:definition.PackageId) { $script:reg.ProductCode } }
        Mock Test-MsiClassicLookupSafe { param($Registration,$Registrations) $true }
        Mock Get-ArtCraftRegistrationMetadata { param($Registration) [pscustomobject]@{ProductCode=$Registration.ProductCode;UpgradeCode=$script:definition.UpgradeCode;Version='1.0.0';Architecture='x64'} }
        Mock Get-MsiRegistrationEvidence { param($Registration) $script:evidenceCalls++; $null }
        $actual=@(Get-ArtCraftInventory); Equal 1 $actual.Count; Assert $actual[0].Healthy; Equal 0 $script:evidenceCalls
        Mock Get-ArtCraftRegistrationMetadata { param($Registration) [pscustomobject]@{ProductCode=$Registration.ProductCode;UpgradeCode='{99999999-9999-9999-9999-999999999999}';Version='1.0.0';Architecture='x64'} }
        Equal 0 @(Get-ArtCraftInventory).Count; Equal 0 $script:evidenceCalls
    }
    Test 'Historical Program Files x86 machine path is healthy only when MSI native architecture also matches' {
        $path=Join-Path ${env:ProgramFiles(x86)} 'MaterialCraft'
        [void][IO.Directory]::CreateDirectory($path); Assert (Test-ArtCraftMachinePath $path)
        Assert (-not (Test-ArtCraftMachinePath (Join-Path $BaseDir 'Program Files (x86)-evil')))
        $installed=New-Installed '1.0.0'; $installed.InstallLocation=$path; $script:inventory=@($installed)
        Equal 0 (Invoke-ArtCraftInstall $definition.PackageId)
        Equal $path @(Get-ArtCraftOwnership)[0].InstallLocation
    }
    Test 'SYSTEM AppData classifier honors actual SystemRoot, Sysnative and exact directory boundaries' {
        $prior=$env:SystemRoot; $env:SystemRoot='D:\OperatingSystem'
        try {
            foreach ($dir in @('System32','SysWOW64','Sysnative')) {
                Assert (Test-SystemProfileAppDataPath ("D:\OperatingSystem\$dir\config\systemprofile\AppData\Local\ArtCraft"))
                Assert (-not (Test-SystemProfileAppDataPath ("D:\OperatingSystem\$dir\config\systemprofile\AppData-evil\ArtCraft")))
            }
            Assert (-not (Test-SystemProfileAppDataPath 'C:\Windows\System32\config\systemprofile\AppData\Local'))
        } finally { $env:SystemRoot=$prior }
    }
    Test 'Missing real ARP context is surfaced as ambiguous rather than a guessed machine uninstall' {
        Restore Get-ArtCraftInventory
        Mock Get-RegisteredApplications { param([switch]$IncludeUnnamed) @() }
        Mock Get-ArtCraftRelatedProducts { param($Definition) if ($Definition.PackageId -ceq $script:definition.PackageId) { '{11111111-1111-1111-1111-111111111111}' } }
        $actual=@(Get-ArtCraftInventory); Equal 1 $actual.Count; Assert $actual[0].Ambiguous
        Equal 'unknown' $actual[0].Scope; Assert (-not $actual[0].Healthy)
    }
    Test 'MSI 1618 retry is bounded, keeps process handle, disposes processes and rejects null exit code' {
        Restore Invoke-ArtCraftMsi
        $prior=$env:SystemRoot; $env:SystemRoot=$BaseDir
        try {
            $script:starts=0; $script:sleeps=0; $script:disposals=0; $script:handleReads=0; $script:exitCodes=@(1618,1618,3010)
            Mock Start-Process {
                param($FilePath,$ArgumentList,[switch]$PassThru)
                $script:starts++; $process=[pscustomobject]@{Index=($script:starts-1)}
                $process | Add-Member ScriptProperty Handle { $script:handleReads++; [IntPtr]1 }
                $process | Add-Member ScriptProperty ExitCode { Assert ($script:handleReads -ge $script:starts) 'ExitCode read before process handle.'; $script:exitCodes[$this.Index] }
                $process | Add-Member ScriptMethod WaitForExit { param($Timeout) Assert ($Timeout -eq 3600000); $true }
                $process | Add-Member ScriptMethod Dispose { $script:disposals++ }
                $process
            }
            Mock Start-Sleep { param($Seconds) $script:sleeps++; Assert ($Seconds -in @(10,20)) }
            Equal 3010 (Invoke-ArtCraftMsi '/i verified.msi /qn /norestart'); Equal 3 $script:starts; Equal 2 $script:sleeps; Equal 3 $script:disposals
            $script:starts=0; $script:exitCodes=@(1618,1618,1618); Equal 1618 (Invoke-ArtCraftMsi '/i verified.msi /qn /norestart'); Equal 3 $script:starts
            $script:starts=0; $script:exitCodes=@($null); Throws { Invoke-ArtCraftMsi '/i verified.msi /qn /norestart' } 'unavailable'
        }
        finally { $env:SystemRoot=$prior; Remove-Item Function:script:Start-Process,Function:script:Start-Sleep -ErrorAction SilentlyContinue }
    }
    Test 'Native MSI bridge compiles without executing Windows APIs; HTTP and MSI retry bounds are explicit' {
        Initialize-ArtCraftNativeMsi
        Assert ('Softwarekatalog.ArtCraftMsi' -as [type])
        $http=$providerOriginal['Invoke-ArtCraftHttp'].ToString(); Assert ($http.Contains('$redirect -le 5') -and $http.Contains('30000') -and $http.Contains('$total -gt $MaxBytes'))
        $msi=$providerOriginal['Invoke-ArtCraftMsi'].ToString(); Assert ($msi.Contains('$attempt -lt 3') -and $msi.Contains('WaitForExit(3600000)'))
    }
}
finally {
    $env:ProgramFiles=$oldProgramFiles; $env:ProgramW6432=$oldProgramW6432
    ${env:ProgramFiles(x86)}=$oldProgramFilesX86
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output ("ArtCraft provider: {0} passed, {1} failed." -f $script:passed,$script:failed)
if ($script:failed) { throw "$($script:failed) ArtCraft provider tests failed." }
