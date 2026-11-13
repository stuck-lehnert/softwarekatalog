[CmdletBinding()]
param(
    [Parameter(Mandatory)][switch]$AllowDisposableMachine,
    [Parameter(Mandatory)][string]$WixPath,
    [Parameter(Mandatory)][ValidateSet('x64','arm64')][string]$ExpectedArchitecture,
    [string]$ResultsDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $ResultsDirectory) { $ResultsDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'test-results\windows-integration' }
# This suite creates services' scheduled tasks, policy, a local user and real
# MSI registrations. Never silently run it on a developer/domain workstation.
if (-not $AllowDisposableMachine -or $env:OS -ne 'Windows_NT' -or
    $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Integration tests require explicit opt-in and a disposable GitHub-hosted native Windows x64/ARM64 PowerShell 5.1 runner.'
}
. (Join-Path $PSScriptRoot 'helpers/WindowsArchitecture.ps1')
$architecture = Assert-CiWindowsArchitecture -ExpectedArchitecture $ExpectedArchitecture -ExpectedOSArchitecture $ExpectedArchitecture `
    -RequireNative -OutputPath (Join-Path $ResultsDirectory 'architecture.json')
Write-Output ('Integration architecture evidence: ' + ($architecture | ConvertTo-Json -Compress))
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator rights required.' }
$repo = Split-Path $PSScriptRoot -Parent
$base = Join-Path $env:ProgramData '__Softwarekatalog'
$policy = 'HKLM:\Software\Policies\STL\Softwarekatalog'
$tasks = @('Softwarekatalog - Requests', 'Softwarekatalog - Queue', 'Softwarekatalog - Winget Upgrade')
$shortcuts = @(
    (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Softwarekatalog.lnk'),
    (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Softwarekatalog.lnk')
)
if ((Test-Path $base) -or (Test-Path $policy) -or @($tasks | Where-Object { Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue }).Count -gt 0 -or
    @($shortcuts | Where-Object { Test-Path $_ }).Count -gt 0) { throw 'Refusing to overwrite a pre-existing Softwarekatalog installation/policy/task/shortcut.' }
$root = Join-Path $env:PUBLIC ('Softwarekatalog-CI-' + [Guid]::NewGuid().ToString('N'))
$taskName = 'Softwarekatalog CI ' + [Guid]::NewGuid().ToString('N')
$userName = 'SoftkatCi' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$createdDeployment = $false
$createdUser = $false
$failed = $false
$cases = New-Object 'System.Collections.Generic.List[object]'
New-Item -ItemType Directory -Path $ResultsDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $root | Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect disposable fixture root.' }
Set-Content -LiteralPath (Join-Path $root '.disposable-ci-fixture') -Value 'Owned by Softwarekatalog CI'
$architectureHelper = Join-Path $root 'WindowsArchitecture.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'helpers/WindowsArchitecture.ps1') -Destination $architectureHelper

function Check($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Record([string]$Name) { $cases.Add([pscustomobject]@{ Name = $Name; Success = $true; Error = '' }); Write-Output "PASS $Name" }
function Write-CiError([string]$Detail) {
    if ($Detail.Length -gt 12000) { $Detail = $Detail.Substring(0, 12000) }
    $Detail = $Detail.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    Write-Output "::error title=Windows SYSTEM integration::$Detail"
}
function Stop-ProductTasks {
    foreach ($name in $tasks) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
            Disable-ScheduledTask -TaskName $name | Out-Null
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        }
    }
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $running = @($tasks | Where-Object { $task = Get-ScheduledTask -TaskName $_ -ErrorAction SilentlyContinue; $task -and $task.State -eq 'Running' })
        if (-not $running.Count) { return }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw 'Production tasks did not stop in time.'
}
function Get-SystemPhaseFailureDetails([string]$Phase, [bool]$ExpectedInterruption) {
    $markerPath = Join-Path $root 'artcraft-interruption.json'
    $detail = "ExpectedInterruption=$ExpectedInterruption; marker='$markerPath'; markerExists=$(Test-Path -LiteralPath $markerPath)"
    foreach ($path in @($markerPath, (Join-Path $root "$Phase.transcript.txt"),
        (Join-Path $root 'artcraft-msi-invocations.jsonl'), (Join-Path $base 'ArtCraft\State.json'))) {
        if (Test-Path -LiteralPath $path) {
            try { $detail += "`n--- $path ---`n" + ((Get-Content -LiteralPath $path -Tail 24) -join "`n") }
            catch { $detail += "`nCould not read diagnostic '$path': $_" }
        }
    }
    $detail
}
function Run-SystemPhase([string]$Phase, [string]$Sid = '', [switch]$ExpectInterrupted) {
    $scriptPath = Join-Path $PSScriptRoot 'windows\SystemScenario.ps1'
    $architecturePath = Join-Path $root "$Phase.architecture.json"
    # Architecture assertion and scenario execute in the SAME scheduled process.
    # No fallback to an emulated x64 PowerShell is permitted on the ARM64 lane.
    $command = ". '$($architectureHelper.Replace("'", "''"))'; `$null = Assert-CiWindowsArchitecture -ExpectedArchitecture '$ExpectedArchitecture' -ExpectedOSArchitecture '$ExpectedArchitecture' -RequireNative -OutputPath '$($architecturePath.Replace("'", "''"))'; & '$($scriptPath.Replace("'", "''"))' -Root '$($root.Replace("'", "''"))' -Phase '$Phase' -ExpectedUserSid '$Sid'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 8) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskPrincipal -Settings $settings -Force | Out-Null
    $resultPath = Join-Path $root "$Phase.result.json"
    $lastRun = (Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes(8)
    $wasInterrupted = $false
    while (-not (Test-Path -LiteralPath $resultPath)) {
        if ((Get-Date) -gt $deadline) {
            $diagnostic = Get-SystemPhaseFailureDetails -Phase $Phase -ExpectedInterruption ([bool]$ExpectInterrupted)
            throw "SYSTEM phase timed out: $Phase`n$diagnostic"
        }
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        if ($info.LastRunTime -gt $lastRun -and (Get-ScheduledTask -TaskName $taskName).State -notin @('Running', 'Queued')) {
            if ($ExpectInterrupted -and $Phase -eq 'ArtCraftInterrupt' -and (Test-Path -LiteralPath (Join-Path $root 'artcraft-interruption.json'))) {
                $wasInterrupted = $true
                break
            }
            $diagnostic = Get-SystemPhaseFailureDetails -Phase $Phase -ExpectedInterruption ([bool]$ExpectInterrupted)
            throw "SYSTEM phase '$Phase' exited without a result (task code $($info.LastTaskResult)).`n$diagnostic"
        }
        Start-Sleep -Milliseconds 250
    }
    while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        if ((Get-Date) -gt $deadline) {
            $diagnostic = Get-SystemPhaseFailureDetails -Phase $Phase -ExpectedInterruption ([bool]$ExpectInterrupted)
            throw "SYSTEM phase did not exit: $Phase`n$diagnostic"
        }
        Start-Sleep -Milliseconds 200
    }
    $systemArchitecture = Get-Content -LiteralPath $architecturePath -Raw | ConvertFrom-Json
    Assert-CiArchitectureRecord $systemArchitecture $ExpectedArchitecture $ExpectedArchitecture -RequireNative
    Check ($systemArchitecture.Sid -eq 'S-1-5-18') 'Architecture proof did not come from the actual SYSTEM token.'
    Record "Native $ExpectedArchitecture SYSTEM process ($Phase)"
    if ($wasInterrupted) {
        $interruption = Get-Content -LiteralPath (Join-Path $root 'artcraft-interruption.json') -Raw | ConvertFrom-Json
        $word = $artConfig.Packages | Where-Object Alias -eq wordcraft
        Check ($interruption.ProcessId -eq $systemArchitecture.ProcessId -and $interruption.ProductCode -eq $word.OldProductCode -and $interruption.ExitCode -in @(0,3010)) 'Interruption was not the bounded successful-removal process boundary.'
        Check ((Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult -ne 0) 'Interrupted process unexpectedly returned success.'
        Record 'Real SYSTEM process terminated immediately after successful MSI removal'
        return
    }
    Check (-not $ExpectInterrupted) 'Expected removal-boundary process termination did not happen.'
    $result = Get-Content $resultPath -Raw | ConvertFrom-Json
    foreach ($case in @($result.Cases)) { $cases.Add($case) }
    Check ($result.Identity -match '(?i)SYSTEM$') 'Scheduled scenario did not run as SYSTEM.'
    $errors = @($result.Cases | Where-Object { -not $_.Success } | ForEach-Object { $_.Error }) -join "`n"
    Check ($result.Success -and (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult -eq 0) "SYSTEM phase failed: $Phase. $errors (see transcript artifact)."
}
try {
    & (Join-Path $PSScriptRoot 'windows\New-Fixture.ps1') -Root $root -WixPath $WixPath -Architecture $ExpectedArchitecture
    $config = Get-Content (Join-Path $root 'fixture-config.json') -Raw | ConvertFrom-Json
    $artConfig = Get-Content (Join-Path $root 'artcraft-fixture-config.json') -Raw | ConvertFrom-Json
    Check ($config.Architecture -eq $ExpectedArchitecture -and ($config.MsiTemplate -split ';')[0] -ieq $ExpectedArchitecture) 'Fixture MSI architecture does not match the native lane.'
    Record "Matching native $ExpectedArchitecture MSI package template"
    New-Item -Path "$policy\Catalog" -Force | Out-Null
    New-ItemProperty -Path $policy -Name Enabled -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $policy -Name EnforceRequired -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path "$policy\Catalog" -Name ci -PropertyType String -Value "$($config.PackageId)|CI Fixture|Disposable MSI integration fixture" -Force | Out-Null
    $createdDeployment = $true
    # This is the actual release bootstrap, not an AST-only mock of Install.
    & (Join-Path $repo 'dist\setup.ps1') -Mode Install
    Stop-ProductTasks # In particular: never upgrade the runner's other software.
    $rawWrapper = [IO.File]::ReadAllText((Join-Path $repo 'dist\setup.ps1'))
    Check ($rawWrapper -match '(?s)\$Payload = @''\r?\n(?<payload>[^\r\n]+)\r?\n''@') 'Distribution payload missing.'
    $expectedPayload = $Matches.payload
    $deployed = [IO.File]::ReadAllBytes((Join-Path $base 'SelfServiceWinget.ps1'))
    Check ($deployed.Length -gt 3 -and $deployed[0] -eq 0xEF -and $deployed[1] -eq 0xBB -and $deployed[2] -eq 0xBF) 'Deployed script lost its UTF-8 BOM.'
    Check ([Convert]::ToBase64String($deployed, 3, $deployed.Length - 3) -eq $expectedPayload) 'Installed payload differs from release artifact.'
    foreach ($name in $tasks) {
        $task = Get-ScheduledTask -TaskName $name
        Check ($task.Principal.UserId -in @('SYSTEM', 'S-1-5-18')) "Wrong task identity: $name"
        Check ([int]$task.Principal.RunLevel -eq 1) "Task not highest-privilege: $name"
        Check ([int]$task.Settings.MultipleInstances -eq 2) "Task does not prevent overlapping instances: $name"
        Export-ScheduledTask -TaskName $name | Set-Content -LiteralPath (Join-Path $ResultsDirectory (($name -replace '[^A-Za-z0-9-]', '_') + '.xml'))
    }
    foreach ($path in @('Request-App.ps1', 'Software-Catalog.ps1', 'Launch-Software-Catalog.vbs')) { Check (Test-Path (Join-Path $base $path)) "Generated runtime file missing: $path" }
    foreach ($path in $shortcuts) { Check (Test-Path $path) "All-users catalog shortcut missing: $path" }
    Record 'Actual distribution deployment, task principals/settings, generated runtime and shortcuts'
    Run-SystemPhase Lifecycle
    # Isolate ArtCraft's Required=gridcraft test from the original ci request
    # security lane. Restore actual registry values/types even when a phase fails.
    $requiredPath = "$policy\Required"
    $requiredKey = Get-Item -LiteralPath $requiredPath
    $requiredBeforeArtCraft = @(foreach ($name in $requiredKey.GetValueNames()) {
        [pscustomobject]@{ Name = $name; Kind = $requiredKey.GetValueKind($name); Value = $requiredKey.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    })
    $enforceBeforeArtCraft = (Get-ItemProperty -LiteralPath $policy -Name EnforceRequired).EnforceRequired
    try {
        Run-SystemPhase ArtCraft
        Run-SystemPhase ArtCraftInterrupt -ExpectInterrupted
        Run-SystemPhase ArtCraftResume
    }
    finally {
        foreach ($name in (Get-Item -LiteralPath $requiredPath).GetValueNames()) { Remove-ItemProperty -LiteralPath $requiredPath -Name $name }
        foreach ($value in $requiredBeforeArtCraft) { New-ItemProperty -LiteralPath $requiredPath -Name $value.Name -PropertyType $value.Kind -Value $value.Value -Force | Out-Null }
        New-ItemProperty -LiteralPath $policy -Name EnforceRequired -PropertyType DWord -Value $enforceBeforeArtCraft -Force | Out-Null
    }
    Check ((Get-ItemProperty -LiteralPath $requiredPath -Name ci).ci -eq 1) 'Original Required=ci policy was not restored before the unchanged request-security scenario.'
    Record 'ArtCraft Required-policy changes are isolated from original standard-user/Requests security lane'

    # Create a real non-admin account; never use the runner's elevated token
    # as a substitute for testing NTFS/registry enforcement.
    $password = ConvertTo-SecureString ('Ci!' + [Guid]::NewGuid().ToString('N') + '9aZ') -AsPlainText -Force
    $user = New-LocalUser -Name $userName -Password $password -PasswordNeverExpires
    $createdUser = $true
    $usersGroup = Get-LocalGroup -SID 'S-1-5-32-545'
    Add-LocalGroupMember -Group $usersGroup -Member $user
    $userOutput = Join-Path $root 'user-output'
    New-Item -ItemType Directory -Path $userOutput | Out-Null
    $acl = Get-Acl $userOutput
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($user.Sid, 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl $userOutput $acl
    Start-Service -Name seclogon
    $credential = New-Object Management.Automation.PSCredential("$env:COMPUTERNAME\$userName", $password)
    $userResult = Join-Path $userOutput 'result.json'
    $userScript = Join-Path $root 'StandardUserScenario.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows\StandardUserScenario.ps1') -Destination $userScript
    $userArchitecturePath = Join-Path $userOutput 'architecture.json'
    $artUserResult = Join-Path $userOutput 'artcraft.json'
    $artUserScript = Join-Path $root 'StandardUser-ArtCraft.ps1'
    # Keep the existing real standard-user scenario unchanged. This additional
    # protected bootstrap verifies all three custom-installed MSI payloads and
    # their all-users shortcuts using that SAME non-administrator token.
    $artUserSource = @'
param([string]$Root, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath (Join-Path $Root 'artcraft-fixture-config.json') -Raw | ConvertFrom-Json
$checks = @()
foreach ($package in @($config.Packages)) {
    $output = & $package.Executable 2>&1 | Out-String
    $checks += [pscustomobject]@{ Alias = $package.Alias; ExitCode = $LASTEXITCODE; Output = $output
        SharedShortcut = Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonPrograms')) ($package.ShortcutName + '.lnk')) }
}
$denials = @()
foreach ($path in @((Join-Path $env:ProgramData '__Softwarekatalog\ArtCraft\State.json'), (Join-Path $env:ProgramData '__Softwarekatalog\ArtCraft\Cache\user-injected.msi'))) {
    $blocked = $false
    try { [IO.File]::WriteAllText($path, 'tamper attempt') } catch [UnauthorizedAccessException] { $blocked = $true }
    $denials += [pscustomobject]@{ Path = $path; Blocked = $blocked }
}
[pscustomobject]@{ Checks = $checks; Denials = $denials } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
'@
    [IO.File]::WriteAllText($artUserScript, $artUserSource, (New-Object Text.UTF8Encoding($true)))
    # PS5.1 Add-Type uses CodeDOM temporary files. Do not rely on an inherited
    # runner-admin TEMP directory being writable by this real standard user.
    $command = "Write-Output 'Standard-user process started'; `$env:TEMP = '$($userOutput.Replace("'", "''"))'; `$env:TMP = `$env:TEMP; . '$($architectureHelper.Replace("'", "''"))'; `$null = Assert-CiWindowsArchitecture -ExpectedArchitecture '$ExpectedArchitecture' -ExpectedOSArchitecture '$ExpectedArchitecture' -RequireNative -OutputPath '$($userArchitecturePath.Replace("'", "''"))'; Write-Output 'Native architecture verified'; & '$($userScript.Replace("'", "''"))' -OutputPath '$($userResult.Replace("'", "''"))'"
    $command += "; & '$($artUserScript.Replace("'", "''"))' -Root '$($root.Replace("'", "''"))' -OutputPath '$($artUserResult.Replace("'", "''"))'"
    $userLog = Join-Path $userOutput 'console.log'
    $command = "& { `$ErrorActionPreference = 'Stop'; $command } *> '$($userLog.Replace("'", "''"))'"
    # CreateProcessWithLogonW limits the entire command line to 1024 characters.
    # An encoded inline bootstrap exceeds that limit (Win32 error 87). Keep the
    # bootstrap in the protected root, not the user-writable output directory.
    $userBootstrap = Join-Path $root 'Run-StandardUser.ps1'
    [IO.File]::WriteAllText($userBootstrap, $command, (New-Object Text.UTF8Encoding($true)))
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $userBootstrap + '"'
    $userEngine = Join-Path $PSHOME 'powershell.exe'
    Check (($userEngine.Length + $arguments.Length + 4) -lt 1024) 'Credential process command line exceeds the Windows logon API limit.'
    # Redirect PowerShell streams inside the child; do not inherit runner log handles.
    $process = Start-Process -FilePath $userEngine -ArgumentList $arguments `
        -Credential $credential -LoadUserProfile -WorkingDirectory $userOutput -PassThru
    $handle = $process.Handle
    if (-not $process.WaitForExit(120000)) {
        $process.Kill()
        $userDetail = if (Test-Path $userLog) { (Get-Content $userLog -Tail 40) -join "`n" } else { 'No console log.' }
        throw "Standard-user scenario timed out: $userDetail"
    }
    $userDetail = if (Test-Path $userLog) { (Get-Content $userLog -Tail 40) -join "`n" } else { 'No standard-user console log was written.' }
    Check ($process.ExitCode -eq 0 -and (Test-Path $userResult)) "Standard-user scenario failed (exit code $($process.ExitCode)): $userDetail"
    $result = Get-Content $userResult -Raw | ConvertFrom-Json
    $userArchitecture = Get-Content -LiteralPath $userArchitecturePath -Raw | ConvertFrom-Json
    Assert-CiArchitectureRecord $userArchitecture $ExpectedArchitecture $ExpectedArchitecture -RequireNative
    Check ($userArchitecture.Sid -eq $user.Sid.Value) 'Architecture proof did not come from the actual standard-user token.'
    Record "Native $ExpectedArchitecture standard-user PowerShell process"
    Check (-not $result.IsAdmin -and $result.Sid -eq $user.Sid.Value) 'Test used the wrong user token.'
    Check (@($result.TamperAttempts | Where-Object { -not $_.Blocked }).Count -eq 0) 'Standard user could modify privileged runtime/queue/journal/another owner request.'
    Check $result.PolicyWriteBlocked 'Standard user could rewrite catalog policy.'
    Check ($result.SharedShortcut -and $result.LaunchExitCode -eq 0 -and $result.LaunchOutput -match 'fixture OK') 'Machine MSI was not accessible to the second standard user.'
    Check ($result.LaunchOutput -match "process=$ExpectedArchitecture; os=$ExpectedArchitecture; native=True") 'The installed MSI executable did not prove native execution under the standard-user token.'
    Record 'Real standard-user ACL enforcement, policy protection and all-users executable/shortcut access'
    $artUser = Get-Content -LiteralPath $artUserResult -Raw | ConvertFrom-Json
    Check (@($artUser.Checks).Count -eq 3 -and @($artUser.Denials | Where-Object { -not $_.Blocked }).Count -eq 0) 'ArtCraft protected state/cache was writable by standard user.'
    foreach ($check in @($artUser.Checks)) {
        Check ($check.ExitCode -eq 0 -and $check.SharedShortcut -and $check.Output -match "process=$ExpectedArchitecture; os=$ExpectedArchitecture; native=True") "Custom MSI/shortcut was not accessible and native for standard user: $($check.Alias)"
    }
    Record 'Real standard-user native ArtCraft launches/all-users shortcuts and custom state/cache ACL enforcement'
    Run-SystemPhase Requests $user.Sid.Value
}
catch {
    $failed = $true
    $cases.Add([pscustomobject]@{ Name = 'Integration harness'; Success = $false; Error = ($_ | Out-String) })
    Write-Warning ($_ | Out-String)
    $detail = $_ | Out-String
    $serviceLog = Join-Path $base 'Logs\service.log'
    if (Test-Path $serviceLog) { $detail += (Get-Content $serviceLog -Tail 60) -join "`n" }
    Write-CiError $detail
}
finally {
    if ($createdDeployment) {
        if (Test-Path -LiteralPath (Join-Path $root 'artcraft-fixture-config.json')) {
            try { Stop-ProductTasks; Run-SystemPhase ArtCraftCleanup } catch { $failed = $true; Write-Warning "ArtCraft fixture cleanup failed: $_" }
        }
        try { Stop-ProductTasks; Run-SystemPhase Cleanup } catch { $failed = $true; Write-Warning "Fixture cleanup failed: $_" }
    }
    # Revoke the fixture trust before any artifact/user/task operation that
    # might itself throw. Native fixture removals above are individually caught.
    $certificateHelper = Join-Path $root 'Manage-ArtCraftCertificate.ps1'
    if (Test-Path -LiteralPath (Join-Path $root 'artcraft-fixture-config.json')) {
        if (Test-Path -LiteralPath $certificateHelper) {
            try {
                & $certificateHelper -Root $root -ExpectedArchitecture $ExpectedArchitecture -Operation Remove
                Record "Native $ExpectedArchitecture SYSTEM revokes exact disposable certificate and private key"
            }
            catch { $failed = $true; Write-Warning "SYSTEM fixture certificate cleanup failed: $_"; Write-CiError ($_ | Out-String) }
        }
        # Also verify all stores from this token, and try each store even if a
        # failed build never reached the SYSTEM helper/bootstrap creation.
        $ownedCertificate = (Get-Content -LiteralPath (Join-Path $root 'artcraft-fixture-config.json') -Raw | ConvertFrom-Json).CertificateThumbprint
        if ($ownedCertificate -match '^[A-Fa-f0-9]{40}$') {
            foreach ($store in @('Root','TrustedPublisher','My')) {
                try {
                    $certificatePath = "Cert:\LocalMachine\$store\$ownedCertificate"
                    if (Test-Path -LiteralPath $certificatePath) {
                        if ($store -eq 'My') { Remove-Item -LiteralPath $certificatePath -DeleteKey -Force -ErrorAction Stop }
                        else { Remove-Item -LiteralPath $certificatePath -Force -ErrorAction Stop }
                    }
                    Check (-not (Test-Path -LiteralPath $certificatePath)) 'Disposable fixture publisher remained trusted after cleanup.'
                }
                catch { $failed = $true; Write-Warning "Could not remove disposable fixture certificate/key from ${store}: $_" }
            }
        }
    }
    if (Test-Path -LiteralPath $certificateHelper) {
        try { Remove-Item -LiteralPath $certificateHelper -Force -ErrorAction Stop }
        catch { $failed = $true; Write-Warning "Could not remove fixture certificate helper: $_" }
    }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask $taskName -ErrorAction SilentlyContinue; Unregister-ScheduledTask $taskName -Confirm:$false }
    if ($createdDeployment) {
        foreach ($name in $tasks) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
        if (Test-Path $base) { Copy-Item -LiteralPath $base -Destination (Join-Path $ResultsDirectory 'deployed-state') -Recurse -Force }
        foreach ($path in $shortcuts) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $policy -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($createdUser) { Remove-LocalUser -Name $userName }
    Copy-Item -LiteralPath $root -Destination (Join-Path $ResultsDirectory 'fixture-diagnostics') -Recurse -Force
    Remove-Item -LiteralPath $root -Recurse -Force
    [pscustomobject]@{ Success = (-not $failed); OS = [Environment]::OSVersion.VersionString; Architecture = $architecture; Cases = @($cases.ToArray()) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'summary.json') -Encoding UTF8
}
if ($failed) { throw 'Windows SYSTEM integration failed; inspect uploaded test-results artifacts.' }
Write-Output "$($cases.Count) Windows integration checks passed."
