[CmdletBinding()]
param([Parameter(Mandatory)][string]$Root, [ValidateSet('Lifecycle','Requests','Cleanup')][string]$Phase, [string]$ExpectedUserSid)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'This scenario must really run as SYSTEM.' }
if (-not (Test-Path -LiteralPath (Join-Path $Root '.disposable-ci-fixture'))) { throw 'Missing disposable fixture marker.' }
$config = Get-Content -LiteralPath (Join-Path $Root 'fixture-config.json') -Raw | ConvertFrom-Json
$installedScript = Join-Path $env:ProgramData '__Softwarekatalog\SelfServiceWinget.ps1'
$source = [IO.File]::ReadAllText($installedScript)
$entry = $source.IndexOf('# Entry point')
if ($entry -lt 0) { throw 'Production entry point marker missing.' }
# Use the deployed payload's unmodified configuration and production functions,
# without invoking its entry point a second time.
. ([scriptblock]::Create($source.Substring(0, $entry)))
$script:fixtureWinget = Join-Path $Root 'winget-fixture.exe'
# Only the external CLI/discovery and asynchronous worker-start boundaries are
# controlled. Registry, MSI APIs, ACLs, policy, request validation, disk queue,
# installed snapshots, locks and the complete worker loop are real.
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
        $script:cases += [pscustomobject]@{ Name = $Name; Success = $false; Error = $_.ToString() }
        throw
    }
}
function Run-Msi([string]$Arguments) {
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') -ArgumentList $Arguments -PassThru
    $handle = $p.Handle
    if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'MSI fixture operation timed out.' }
    return $p.ExitCode
}
Start-Transcript -Path (Join-Path $Root "$Phase.transcript.txt") | Out-Null
try {
    if ($Phase -eq 'Lifecycle') {
        Case 'Actual SYSTEM identity and real per-user MSI installation' {
            $arguments = '/i "{0}" ALLUSERS=2 MSIINSTALLPERUSER=1 INSTALLFOLDER="{1}" /qn /norestart /l*v "{2}"' -f $config.Msi, $config.LegacyDir, (Join-Path $Root 'legacy-install.log')
            Check ((Run-Msi $arguments) -eq 0) 'Could not seed the legacy per-user MSI.'
            Check (Test-Path -LiteralPath (Join-Path $config.LegacyDir 'fixture.exe')) 'Legacy executable is missing.'
        }
        Case 'Native context-specific MSI cache and component APIs under SYSTEM' {
            $registration = @(Get-RegisteredApplications | Where-Object { $_.ProductCode -eq $config.ProductCode -and $_.Scope -eq 'user' })
            Check ($registration.Count -gt 0) 'No SYSTEM-user MSI registration.'
            $evidence = Get-MsiRegistrationEvidence -Registration $registration[0]
            Check ($null -ne $evidence) 'Native MSI lookup failed (NULL SID regression).'
            Check ($evidence.UpgradeCode -eq $config.UpgradeCode) 'Wrong cached MSI identity.'
            Check (@($evidence.ExecutablePaths | Where-Object { Test-SystemProfileAppDataPath $_ }).Count -gt 0) 'Native component lookup did not find the SYSTEM-profile payload.'
        }
        Case 'Production repair loop migrates real MSI to Program Files' {
            Invoke-ProcessQueueMode
            Check (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe')) 'Machine executable is missing.'
            Check (@(Get-RegisteredApplications | Where-Object { $_.ProductCode -eq $config.ProductCode -and $_.Scope -eq 'user' }).Count -eq 0) 'Old user registration remains.'
            Check (@(Get-RegisteredApplications | Where-Object { $_.ProductCode -eq $config.ProductCode -and $_.Scope -eq 'machine' }).Count -gt 0) 'Machine MSI registration is missing.'
            Check ((Get-InstalledPackageIdSet).Contains($config.PackageId)) 'Installed snapshot not updated.'
            Check ((Get-Content -LiteralPath $ScopeRepairPath -Raw).Trim() -eq '[]') 'Repair journal was not completed.'
        }
        Case 'Second worker pass is idempotent, including empty PS5.1 repair journal' {
            $before = @(Get-Content (Join-Path $Root 'winget-invocations.jsonl') | Where-Object { $_ -match '"uninstall"' }).Count
            Invoke-ProcessQueueMode
            $after = @(Get-Content (Join-Path $Root 'winget-invocations.jsonl') | Where-Object { $_ -match '"uninstall"' }).Count
            Check ($before -eq $after) 'Healthy machine application was uninstalled again.'
        }
        Case 'Real queued uninstall and reinstall complete successfully' {
            $request = Add-SoftwareRequestToQueue -Action Uninstall -Alias ci -RequestedBy CI -RequestedBySid CI
            Check $request.Added 'Uninstall was not queued.'
            Invoke-ProcessQueueMode
            Check (-not (Test-Path -LiteralPath (Join-Path $config.MachineDir 'fixture.exe'))) 'Queued uninstall left payload installed.'
            $request = Add-SoftwareRequestToQueue -Action Install -Alias ci -RequestedBy CI -RequestedBySid CI
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
            try { Add-SoftwareRequestToQueue -Action Uninstall -Alias ci -RequestedBy CI -RequestedBySid CI | Out-Null } catch { $blocked = $true }
            Check $blocked 'Required software accepted a user uninstall.'
        }
        # SYSTEM-owned sentinel: a normal user must not modify/delete it.
        Set-Content -LiteralPath (Join-Path $RequestsDir 'system-owner.tmp') -Value 'protected request'
    }
    elseif ($Phase -eq 'Requests') {
        Case 'Actual standard-user owner defeats spoofed request identity' {
            Invoke-ProcessRequestsMode
            $items = @(Get-QueueItemsInDirectory -Directory $QueuePendingDir -DefaultState Queued)
            $accepted = @($items | Where-Object { $_.Alias -eq 'ci' -and $_.Action -eq 'Install' })
            Check ($accepted.Count -eq 1) 'Expected one accepted user install.'
            Check ($accepted[0].RequestedBySid -eq $ExpectedUserSid) 'Caller identity was taken from JSON rather than file ownership.'
            Check ($accepted[0].RequestedBySid -ne 'S-1-5-18') 'Spoofed SYSTEM SID was trusted.'
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
