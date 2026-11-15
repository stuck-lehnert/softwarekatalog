[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root,
    [ValidateSet('Lifecycle','Requests','AdministratorRequests','Cleanup','ArtCraft','ArtCraftInterrupt','ArtCraftResume','ArtCraftCleanup')][string]$Phase,
    [string]$ExpectedUserSid)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'This scenario must really run as SYSTEM.' }
if (-not (Test-Path -LiteralPath (Join-Path $Root '.disposable-ci-fixture'))) { throw 'Missing disposable fixture marker.' }
if ($Phase -like 'ArtCraft*') {
    & (Join-Path $PSScriptRoot 'ArtCraftScenario.ps1') -Root $Root -Phase $Phase
    return
}
$config = Get-Content -LiteralPath (Join-Path $Root 'fixture-config.json') -Raw | ConvertFrom-Json
$installedScript = Join-Path $env:ProgramData '__Softwarekatalog\SelfServiceWinget.ps1'
$source = [IO.File]::ReadAllText($installedScript)
$entry = $source.IndexOf('# Entry point')
if ($entry -lt 0) { throw 'Production entry point marker missing.' }
# Use the deployed payload's unmodified configuration and production functions,
# without invoking its entry point a second time.
. ([scriptblock]::Create($source.Substring(0, $entry)))
$script:fixtureWinget = Join-Path $Root 'winget-fixture.exe'
# Scope inventory to this run's GUID, but use the unchanged real registry reader
# in both views/scopes (including unnamed entries). Hosted runners contain a
# large Visual Studio/MSI estate unrelated to the fixture. Never traverse all
# of those cached component tables for every test worker pass.
$script:readRegisteredApplications = ${function:Get-RegisteredApplications}
function Get-RegisteredApplications {
    param([switch]$IncludeUnnamed)
    & $script:readRegisteredApplications -IncludeUnnamed:$IncludeUnnamed |
        Where-Object { $_.ProductCode -eq $config.ProductCode }
}
# CLI/discovery and asynchronous worker startup are controlled. Inventory is
# restricted to real registrations of the fixture; no registry/MSI data is faked.
# ACLs, policy, request validation, disk queue, snapshots and locks are real.
function Ensure-WingetAvailable { return $script:fixtureWinget }
function Start-QueueWorkerIfAvailable { return $true }
$script:cases = @()
$failed = $false
function Check($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body | Out-Host
        $script:cases += [pscustomobject]@{ Name = $Name; Success = $true; Error = '' }
        Write-Output "PASS $Name"
    } catch {
        $recentLog = if (Test-Path -LiteralPath $LogFile) { (Get-Content -LiteralPath $LogFile -Tail 15) -join "`n" } else { '' }
        $script:cases += [pscustomobject]@{ Name = $Name; Success = $false; Error = ($_.ToString() + "`n" + $_.ScriptStackTrace + "`nProduction log:`n" + $recentLog) }
        throw
    }
}
function Run-Msi([string]$Arguments) {
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $Arguments -PassThru
    $handle = $p.Handle
    if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'MSI fixture operation timed out.' }
    return $p.ExitCode
}
function Get-CiWingetMutationCount {
    $path = Join-Path $Root 'winget-invocations.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    @(Get-Content -LiteralPath $path | Where-Object { $_ -match '"(?:install|uninstall|upgrade)"' }).Count
}
Start-Transcript -Path (Join-Path $Root "$Phase.transcript.txt") | Out-Null
try {
    if ($Phase -eq 'Lifecycle') {
        Case 'Native request archives and early storage/state/cache trust reject filesystem attacks' {
            & (Join-Path $PSScriptRoot 'Test-FileSystemSecurityNative.ps1') -Root $BaseDir
        }
        Case 'Native Microsoft WinGet provenance, architecture and immutable selection lease' {
            & (Join-Path $PSScriptRoot 'Test-WinGetTrustNative.ps1') -Root $BaseDir -NativeArchitecture (Get-NativeWindowsArchitecture)
        }
        Case 'Actual SYSTEM identity and real MSI installation with per-user defaults into SYSTEM AppData' {
            $arguments = '/i "{0}" ALLUSERS=2 MSIINSTALLPERUSER=1 INSTALLFOLDER="{1}" /qn /norestart /l*v "{2}"' -f $config.Msi, $config.LegacyDir, (Join-Path $Root 'legacy-install.log')
            Check ((Run-Msi $arguments) -eq 0) 'Could not seed the legacy SYSTEM-profile MSI.'
            Check (Test-Path -LiteralPath (Join-Path $config.LegacyDir 'fixture.exe')) 'Legacy executable is missing.'
        }
        Case 'Read-only native MSI cache and executable evidence under SYSTEM' {
            # SYSTEM's per-user MSI defaults can register in machine ARP even
            # though the payload is in SYSTEM AppData. Inspect the actual scope
            # rather than assuming that install path and registration coincide.
            $registration = @(Get-RegisteredApplications | Where-Object { $_.ProductCode -eq $config.ProductCode })
            if ($registration.Count -eq 0) {
                $contexts = @()
                foreach ($scope in @('user', 'machine')) {
                    $probe = [pscustomobject]@{ ProductCode = $config.ProductCode; Scope = $scope; WindowsInstaller = $true; DisplayName = $config.Name }
                    $native = Get-MsiRegistrationEvidence -Registration $probe
                    $contexts += "$scope native=$($null -ne $native)"
                }
                $arp = @(Get-RegisteredApplications | Where-Object { $_.ProductCode -eq $config.ProductCode } | ForEach-Object { "$($_.Scope):$($_.InstallLocation)" }) -join '; '
                throw "No SYSTEM MSI registration. $($contexts -join '; '); ARP=$arp"
            }
            $evidence = Get-MsiRegistrationEvidence -Registration $registration[0]
            Check ($null -ne $evidence) 'Native MSI lookup failed (NULL SID regression).'
            $types = @($evidence | ForEach-Object { $_.GetType().FullName }) -join ', '
            Check (@($evidence).Count -eq 1 -and $evidence -is [pscustomobject]) "MSI evidence must be one record without COM return values (got $types)."
            Check ($evidence.UpgradeCode -eq $config.UpgradeCode) 'Wrong cached MSI identity.'
            $detail = $evidence | ConvertTo-Json -Depth 5 -Compress
            if (@($evidence.ExecutablePaths | Where-Object { Test-SystemProfileAppDataPath $_ }).Count -eq 0) {
                Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class FixtureMsiProbe {
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    static extern int MsiGetComponentPath(string product, string component, StringBuilder path, ref uint length);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    static extern uint MsiEnumProductsEx(string product, string sid, uint context, uint index, StringBuilder foundProduct, out uint foundContext, StringBuilder foundSid, ref uint sidLength);
    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    static extern int MsiGetComponentPathEx(string product, string component, string sid, uint context, StringBuilder path, ref uint length);
    public static string Enumerate(string product, uint context) {
        var found = new StringBuilder(39); var sid = new StringBuilder(32768);
        uint foundContext, size = 32768;
        uint code = MsiEnumProductsEx(product, null, context, 0, found, out foundContext, sid, ref size);
        return "enum context=" + context + " code=" + code + " found=" + found + " installedContext=" + foundContext + " SID=" + sid;
    }
    public static string SystemUser(string product, string component) {
        var path = new StringBuilder(32768); uint length = 32768;
        int state = MsiGetComponentPathEx(product, component, "S-1-5-18", 2, path, ref length);
        return "explicit SYSTEM user state=" + state + " path=" + path;
    }
    public static string Classic(string product, string component) {
        var path = new StringBuilder(32768); uint length = 32768;
        int state = MsiGetComponentPath(product, component, path, ref length);
        return "classic state=" + state + " path=" + path;
    }
}
'@
                $probes = @()
                foreach ($sample in @($evidence.ComponentDiagnostics)) {
                    $probes += "product=$($config.ProductCode) component=$($sample.ComponentId)"
                    $probes += [FixtureMsiProbe]::Classic($config.ProductCode, $sample.ComponentId)
                    $probes += [FixtureMsiProbe]::SystemUser($config.ProductCode, $sample.ComponentId)
                    $com = New-Object -ComObject WindowsInstaller.Installer
                    try { $probes += "COM path=$($com.ComponentPath($config.ProductCode, $sample.ComponentId))" }
                    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($com) }
                    foreach ($context in @(4, 2, 1)) {
                        $buffer = New-Object Text.StringBuilder 32768
                        $length = [uint32]32768
                        $state = [Softwarekatalog.NativeMsi]::GetComponentPath($config.ProductCode, $sample.ComponentId, [uint32]$context, $buffer, [ref]$length)
                        $probes += "context=$context state=$state path=$($buffer.ToString())"
                        $buffer = New-Object Text.StringBuilder 32768
                        $length = [uint32]32768
                        $code = [Softwarekatalog.NativeMsi]::GetProductInfo($config.ProductCode, [uint32]$context, 'LocalPackage', $buffer, [ref]$length)
                        $probes += "context=$context cacheCode=$code"
                        $length = [uint32]32768
                        $code = [Softwarekatalog.NativeMsi]::GetProductInfo($config.ProductCode, [uint32]$context, 'State', $buffer, [ref]$length)
                        $probes += "context=$context productStateCode=$code state=$buffer"
                        $probes += [FixtureMsiProbe]::Enumerate($config.ProductCode, [uint32]$context)
                    }
                }
                $msiLog = @(Get-Content (Join-Path $Root 'legacy-install.log') | Select-String 'Feature: Main|Component:|ComponentRegister|RegisterProduct|PublishProduct|PublishComponents|ALLUSERS|MSIINSTALLPERUSER' | Select-Object -Last 12) -join "`n"
                throw "Native component lookup did not find the SYSTEM-profile payload: $detail; probes=$($probes -join '; '); MSI=$msiLog"
            }
        }
        Case 'Production repair loop migrates real MSI to Program Files' {
            Invoke-ProcessQueueMode
            Check (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe')) 'Machine executable is missing.'
            Check (-not (Test-Path -LiteralPath (Join-Path $config.LegacyDir 'fixture.exe'))) 'Old SYSTEM-profile executable remains after MSI migration.'
            Check (@(Get-RegisteredApplications | Where-Object { $_.ProductCode -eq $config.ProductCode -and $_.Scope -eq 'user' }).Count -eq 0) 'Old user registration remains.'
            Check (@(Get-RegisteredApplications | Where-Object { $_.ProductCode -eq $config.ProductCode -and $_.Scope -eq 'machine' }).Count -gt 0) 'Machine MSI registration is missing.'
            Check ((Get-InstalledPackageIdSet).Contains($config.PackageId)) 'Installed snapshot not updated.'
            $rawJournal = Get-Content -LiteralPath $ScopeRepairPath -Raw
            $journal = $rawJournal | ConvertFrom-Json
            Check ($rawJournal.TrimStart().StartsWith('[') -and @($journal).Count -eq 0) 'Repair journal was not completed.'
        }
        Case 'Second worker pass is idempotent, including empty PS5.1 repair journal' {
            $before = @(Get-Content (Join-Path $Root 'winget-invocations.jsonl') | Where-Object { $_ -match '"uninstall"' }).Count
            Invoke-ProcessQueueMode
            $after = @(Get-Content (Join-Path $Root 'winget-invocations.jsonl') | Where-Object { $_ -match '"uninstall"' }).Count
            Check ($before -eq $after) 'Healthy machine application was uninstalled again.'
        }
        Case 'Real queued uninstall and reinstall complete successfully' {
            $request = Add-SoftwareRequestToQueue -Action Uninstall -Alias ci -RequestedBy CI -RequestedBySid 'S-1-5-18'
            Check $request.Added 'Uninstall was not queued.'
            Invoke-ProcessQueueMode
            Check (-not (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe'))) 'Queued uninstall left payload installed.'
            $request = Add-SoftwareRequestToQueue -Action Install -Alias ci -RequestedBy CI -RequestedBySid 'S-1-5-18'
            Invoke-ProcessQueueMode
            Check (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe')) 'Queued reinstall failed.'
            Check (@(Get-QueueItemsInDirectory -Directory $QueueSucceededDir -DefaultState Succeeded).Count -ge 2) 'Success queue history is missing.'
            Check (@(Get-QueueItemsInDirectory -Directory $QueueFailedDir -DefaultState Failed).Count -eq 0) 'Queue history contains an unexpected failure.'
        }
        Case 'Required policy reinstalls missing software and refuses user removal' {
            New-Item -Path $PolicyRequiredRoot -Force | Out-Null
            New-ItemProperty -Path $PolicyRequiredRoot -Name ci -PropertyType String -Value 1 -Force | Out-Null
            New-ItemProperty -Path $PolicyRoot -Name EnforceRequired -PropertyType DWord -Value 1 -Force | Out-Null
            Check ((Run-Msi ("/x {0} ALLUSERS=1 /qn /norestart" -f $config.ProductCode)) -eq 0) 'Could not remove fixture for required-software recovery test.'
            Invoke-ProcessQueueMode
            Check (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe')) 'Required enforcement did not restore MSI.'
            $blocked = $false
            try { Add-SoftwareRequestToQueue -Action Uninstall -Alias ci -RequestedBy CI -RequestedBySid 'S-1-5-18' | Out-Null } catch { $blocked = $true }
            Check $blocked 'Required software accepted a user uninstall.'
        }
        # SYSTEM-owned sentinel: a normal user must not modify/delete it.
        Set-Content -LiteralPath (Join-Path $RequestsDir 'system-owner.tmp') -Value 'protected request'
    }
    elseif ($Phase -eq 'Requests') {
        $accounts = Get-Content -LiteralPath (Join-Path $Root 'authorization-accounts.json') -Raw | ConvertFrom-Json
        $productType = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -Name ProductType).ProductType
        Check ($productType -in @('WinNT','ServerNT','LanmanNT')) 'Unknown actual Windows product type.'
        $isServer = $productType -ne 'WinNT'
        Case 'Actual protected ProductType and production native Authz distinguish real standard and administrator accounts' {
            Check ($ExpectedUserSid -eq $accounts.StandardSid) 'Standard account metadata does not match the real process SID.'
            Check ((Test-ServerOperatingSystem) -eq $isServer) 'Production server classification disagrees with the real protected ProductType.'
            if ($isServer) {
                $adminDrop = Get-AdminRequestsDirectory
                Check (Test-Path -LiteralPath $adminDrop -PathType Container) 'Protected administrator drop was not deployed.'
                foreach ($path in @($BaseDir,$adminDrop)) {
                    Check ((Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'Admin drop or protected parent lacks genuine BA ownership.'
                    Check (((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Admin drop or protected parent is a reparse point.'
                }
            }
            $standardIsAdmin = Test-AdministratorSid -Sid $accounts.StandardSid
            $administratorIsAdmin = Test-AdministratorSid -Sid $accounts.AdministratorSid
            Check (-not $standardIsAdmin -and $administratorIsAdmin) 'Native Authz did not distinguish actual standard/admin accounts.'
            Check (Test-AdministratorSid -Sid 'S-1-5-18') 'Authentic SYSTEM ownership must remain privileged.'
            Check (Test-AdministratorSid -Sid 'S-1-5-32-544') 'Authentic Administrators-group ownership must remain privileged.'
            Check (-not (Test-AdministratorSid -Sid 'not-a-sid')) 'Invalid owner SID was accepted.'
            $unknownSid = $accounts.StandardSid -replace '-[0-9]+$', '-2147483000'
            Check (-not (Test-AdministratorSid -Sid $unknownSid)) 'Unresolvable owner SID was accepted.'
            [pscustomobject]@{ ProductType = $productType; IsServer = $isServer; StandardSid = $accounts.StandardSid
                StandardIsAdministrator = $standardIsAdmin; AdministratorSid = $accounts.AdministratorSid
                AdministratorIsAdministrator = $administratorIsAdmin; Resolver = 'Unmodified production Windows Authz' } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Root 'native-authorization.json') -Encoding UTF8
        }
        $protectedNames = @('standard-spoof-system.json','standard-spoof-admin.json','standard-spoof-required.json','standard-spoof-authorization.json')
        Case 'Real standard-user ownership and protected queue metadata cannot be forged in JSON' {
            foreach ($name in @('standard-spoof-identity.json') + $protectedNames) {
                $owner = Get-RequestFileOwnerInfo -Path (Join-Path $RequestsDir $name)
                Check ($owner.Sid -eq $accounts.StandardSid) "Raw request lacks the actual standard-user owner: $name"
            }
            if ($isServer) {
                $owner = Get-RequestFileOwnerInfo -Path (Join-Path $RequestsDir 'standard-admin-owned-writable.json')
                Check ($owner.Sid -eq 'S-1-5-32-544') 'Writable privileged-owner fixture did not retain actual BA ownership.'
                Check $owner.SafeForInstall 'Attacker did not finish forging the superficially safe BA/SYSTEM-only file DACL.'
            }
            Invoke-ProcessRequestsMode
            $items = @(Get-QueueItemsInDirectory -Directory $QueuePendingDir -DefaultState Queued)
            $accepted = @($items | Where-Object { $_.Alias -eq 'ci' -and $_.Action -eq 'Install' })
            if ($isServer) {
                Check ($accepted.Count -eq 0) 'Server standard account bypassed Install authorization through raw JSON.'
                Check (Test-Path -LiteralPath (Join-Path $FailedRequestsDir 'standard-spoof-identity.json')) 'Server forged-admin identity request was not rejected.'
                Check (Test-Path -LiteralPath (Join-Path $FailedRequestsDir 'standard-spoof-identity.json.error.txt')) 'Server owner rejection reason is missing.'
                Check (Test-Path -LiteralPath (Join-Path $FailedRequestsDir 'standard-admin-owned-writable.json')) 'Server accepted attacker-controlled contents solely due to privileged file ownership.'
                Check (Test-Path -LiteralPath (Join-Path $FailedRequestsDir 'standard-admin-owned-writable.json.error.txt')) 'Writable privileged-owner rejection reason is missing.'
            }
            else {
                Check ($accepted.Count -eq 1) 'Client standard-user install must remain accepted and deduplicated.'
                Check ($accepted[0].RequestedBySid -eq $ExpectedUserSid -and $accepted[0].RequestedBySid -ne 'S-1-5-18') 'Caller identity was taken from JSON rather than file ownership.'
                Check ($accepted[0].Source -eq 'User' -and $accepted[0].Required) 'Trusted Source/Required metadata did not come from actual policy.'
                foreach ($name in @('standard-helper.json','standard-spoof-identity.json')) { Check (Test-Path -LiteralPath (Join-Path $ProcessedRequestsDir $name)) "Authorized client request was not processed: $name" }
            }
            foreach ($name in $protectedNames) {
                Check (Test-Path -LiteralPath (Join-Path $FailedRequestsDir $name)) "Protected queue metadata claim was not quarantined: $name"
                Check (Test-Path -LiteralPath (Join-Path $FailedRequestsDir "$name.error.txt")) "Missing protected-metadata rejection reason: $name"
            }
        }
        Case 'Unapproved, required-uninstall, oversized and root-array requests are quarantined' {
            foreach ($name in @('unapproved.json','required-uninstall.json','oversized.json','array-root.json')) {
                Check (Test-Path -LiteralPath (Join-Path $FailedRequestsDir $name)) "Rejected request not quarantined: $name"
                Check (Test-Path -LiteralPath (Join-Path $FailedRequestsDir "$name.error.txt")) "Missing rejection reason: $name"
            }
            Check (@(Get-QueueItemsInDirectory -Directory $QueuePendingDir -DefaultState Queued | Where-Object { $_.Action -ne 'Install' -or $_.Alias -ne 'ci' }).Count -eq 0) 'Invalid request reached the executable queue.'
            Invoke-ProcessQueueMode
            Check (@(Get-QueueItemsInDirectory -Directory $QueuePendingDir -DefaultState Queued).Count -eq 0) 'Accepted user queue did not drain.'
        }
        Case 'Actual standard-user non-Required Uninstall retains its existing policy on both server and client' {
            $deferredPath = Join-Path $RequestsDir 'standard-uninstall.deferred'
            Check ((Get-RequestFileOwnerInfo -Path $deferredPath).Sid -eq $accounts.StandardSid) 'Deferred Uninstall was not created by the real standard account.'
            try {
                Remove-ItemProperty -LiteralPath $PolicyRequiredRoot -Name ci
                Move-Item -LiteralPath $deferredPath -Destination (Join-Path $RequestsDir 'standard-uninstall.json')
                Invoke-ProcessRequestsMode
                $items = @(Get-QueueItemsInDirectory -Directory $QueuePendingDir -DefaultState Queued)
                Check ($items.Count -eq 1 -and $items[0].Action -eq 'Uninstall' -and $items[0].RequestedBySid -eq $accounts.StandardSid) 'Standard-user Uninstall received a new blanket admin restriction.'
                $uninstallId = $items[0].Id
                Invoke-ProcessQueueMode
                $completed = Read-QueueItemFile -Path (Get-QueueItemPath -Directory $QueueSucceededDir -Id $uninstallId)
                Check ($null -ne $completed -and -not (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe'))) 'Permitted standard-user Uninstall did not complete.'
            }
            finally { New-ItemProperty -LiteralPath $PolicyRequiredRoot -Name ci -PropertyType String -Value 1 -Force | Out-Null }
            Invoke-ProcessQueueMode
            Check (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe')) 'Required policy did not restore the fixture after permitted Uninstall.'
        }
        Case 'Historical protected Source=User queues are reauthorized before the already-installed shortcut' {
            Check ((Get-InstalledPackageIdSet).Contains($config.PackageId)) 'Stale-queue test requires the actual installed MSI snapshot.'
            foreach ($version in @(0,1)) {
                # Seed only the protected old queue as SYSTEM. Version zero
                # represents old acceptance; version one also proves CURRENT
                # membership is checked rather than trusting a previous marker.
                $old = New-QueueItem -Action Install -Alias ci -PackageId $config.PackageId -DisplayName $config.Name -Source User `
                    -Required $true -RequestedBy 'Historical standard user' -RequestedBySid $accounts.StandardSid
                $old.UserInstallAuthorizationVersion = $version
                Check ((Add-QueueItem -Item $old).Added) 'Could not seed protected historical User queue.'
                $before = Get-CiWingetMutationCount
                Invoke-ProcessQueueMode
                $directory = if ($isServer) { $QueueFailedDir } else { $QueueSucceededDir }
                $completed = Read-QueueItemFile -Path (Get-QueueItemPath -Directory $directory -Id $old.Id)
                Check ($null -ne $completed) "Historical queue version $version produced the wrong terminal state."
                Check ($completed.RequestedBySid -eq $accounts.StandardSid -and $completed.Source -eq 'User') 'Historical protected identity/source changed.'
                Check ((Get-CiWingetMutationCount) -eq $before) 'Historical already-installed item unexpectedly dispatched an installer.'
                if ($isServer) { Check ($completed.State -eq 'Failed' -and $completed.ExitCode -ne 0) 'Server old user queue bypassed authorization through installed/Required shortcut.' }
                else { Check ($completed.State -eq 'Succeeded') 'Client historical standard-user queue was incorrectly denied.' }
            }
        }
        Case 'Missing-MSI historical standard-user dispatch is denied on Server and remains allowed on client' {
            $enforceBefore = (Get-ItemProperty -LiteralPath $PolicyRoot -Name EnforceRequired).EnforceRequired
            try {
                New-ItemProperty -LiteralPath $PolicyRoot -Name EnforceRequired -PropertyType DWord -Value 0 -Force | Out-Null
                Check ((Run-Msi ("/x {0} ALLUSERS=1 /qn /norestart" -f $config.ProductCode)) -eq 0) 'Could not remove fixture for dispatch authorization proof.'
                $old = New-QueueItem -Action Install -Alias ci -PackageId $config.PackageId -DisplayName $config.Name -Source User `
                    -Required $true -RequestedBy 'Historical standard user' -RequestedBySid $accounts.StandardSid
                $old.UserInstallAuthorizationVersion = 1
                Check ((Add-QueueItem -Item $old).Added) 'Could not seed missing-package historical queue.'
                $before = Get-CiWingetMutationCount
                Invoke-ProcessQueueMode
                $directory = if ($isServer) { $QueueFailedDir } else { $QueueSucceededDir }
                $completed = Read-QueueItemFile -Path (Get-QueueItemPath -Directory $directory -Id $old.Id)
                Check ($null -ne $completed -and $completed.Source -eq 'User' -and $completed.RequestedBySid -eq $accounts.StandardSid) 'Historical queue identity or expected terminal state was lost.'
                if ($isServer) {
                    Check ($completed.State -eq 'Failed') 'Unauthorized old queue installed missing MSI.'
                    Check ((Get-CiWingetMutationCount) -eq $before -and -not (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe'))) 'Unauthorized old queue dispatched an installer.'
                }
                else {
                    Check ($completed.State -eq 'Succeeded') 'Client standard-user MSI installation was newly restricted.'
                    Check ((Get-CiWingetMutationCount) -gt $before -and (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe'))) 'Client standard-user queue did not dispatch and install the actual MSI.'
                }
            }
            finally { New-ItemProperty -LiteralPath $PolicyRoot -Name EnforceRequired -PropertyType DWord -Value $enforceBefore -Force | Out-Null }
            Invoke-ProcessQueueMode
            Check (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe')) 'Authentic Required/System policy did not restore or preserve the MSI.'
            Check (@(Get-QueueItemsInDirectory -Directory $QueueSucceededDir -DefaultState Succeeded | Where-Object { $_.Source -eq 'Required' -and $_.PackageId -eq $config.PackageId }).Count -gt 0) 'Required policy queue did not complete.'
        }
        Case 'Authentic protected System update queue remains permitted' {
            $systemItem = New-QueueItem -Action UpgradeAll -Source System -RequestedBy SYSTEM -RequestedBySid 'S-1-5-18'
            Check ((Add-QueueItem -Item $systemItem).Added) 'System update was not queued.'
            Invoke-ProcessQueueMode
            $completed = Read-QueueItemFile -Path (Get-QueueItemPath -Directory $QueueSucceededDir -Id $systemItem.Id)
            Check ($null -ne $completed -and $completed.Source -eq 'System') 'Authentic System update was denied.'
        }
    }
    elseif ($Phase -eq 'AdministratorRequests') {
        $accounts = Get-Content -LiteralPath (Join-Path $Root 'authorization-accounts.json') -Raw | ConvertFrom-Json
        Case 'Actual administrator-account file owner is allowed despite forged non-admin JSON identity' {
            Check (Test-AdministratorSid -Sid $accounts.AdministratorSid) 'Real administrator account failed fresh production Authz resolution.'
            $requestDirectory = if (Test-ServerOperatingSystem) { Get-AdminRequestsDirectory } else { $RequestsDir }
            $owner = Get-RequestFileOwnerInfo -Path (Join-Path $requestDirectory 'admin-install.json')
            Check ($owner.Sid -eq $accounts.AdministratorSid) 'Admin helper did not explicitly retain its actual individual account owner.'
            Invoke-ProcessRequestsMode
            $accepted = @(Get-QueueItemsInDirectory -Directory $QueuePendingDir -DefaultState Queued)
            Check ($accepted.Count -eq 1 -and $accepted[0].Action -eq 'Install' -and $accepted[0].Source -eq 'User') 'Real admin Install was not queued as User.'
            Check ($accepted[0].RequestedBySid -eq $owner.Sid -and $accepted[0].RequestedBySid -ne $accounts.StandardSid) 'Admin request used spoofed JSON identity rather than its real file owner.'
            $adminItem = $accepted[0]
            $enforceBefore = (Get-ItemProperty -LiteralPath $PolicyRoot -Name EnforceRequired).EnforceRequired
            try {
                New-ItemProperty -LiteralPath $PolicyRoot -Name EnforceRequired -PropertyType DWord -Value 0 -Force | Out-Null
                Check ((Run-Msi ("/x {0} ALLUSERS=1 /qn /norestart" -f $config.ProductCode)) -eq 0) 'Could not remove fixture for actual admin Install dispatch.'
                $before = Get-CiWingetMutationCount
                Invoke-ProcessQueueMode
                $completed = Read-QueueItemFile -Path (Get-QueueItemPath -Directory $QueueSucceededDir -Id $adminItem.Id)
                Check ($null -ne $completed -and $completed.Source -eq 'User' -and $completed.RequestedBySid -eq $owner.Sid) 'Admin account request did not complete through the User authorization path.'
                Check ((Get-CiWingetMutationCount) -gt $before -and (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe'))) 'Real admin request did not dispatch and complete the native MSI installation.'
            }
            finally { New-ItemProperty -LiteralPath $PolicyRoot -Name EnforceRequired -PropertyType DWord -Value $enforceBefore -Force | Out-Null }
        }
    }
    else {
        foreach ($registration in @(Get-RegisteredApplications | Where-Object { $_.ProductCode -eq $config.ProductCode } | Sort-Object Scope -Unique)) {
            $arguments = "/x $($config.ProductCode) /qn /norestart"
            if ($registration.Scope -eq 'machine') { $arguments += ' ALLUSERS=1' }
            $code = Run-Msi $arguments
            if ($code -notin @(0, 1605)) { throw "Fixture cleanup returned $code" }
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
