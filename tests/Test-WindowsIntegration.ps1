[CmdletBinding()]
param(
    [Parameter(Mandatory)][switch]$AllowDisposableMachine,
    [Parameter(Mandatory)][string]$WixPath,
    [string]$ResultsDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'test-results\windows-integration')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# This suite creates services' scheduled tasks, policy, a local user and real
# MSI registrations. Never silently run it on a developer/domain workstation.
if (-not $AllowDisposableMachine -or $env:OS -ne 'Windows_NT' -or
    $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
    $PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess) {
    throw 'Integration tests require explicit opt-in and a disposable GitHub-hosted Windows x64 PowerShell 5.1 runner.'
}
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

function Check($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Record([string]$Name) { $cases.Add([pscustomobject]@{ Name = $Name; Success = $true; Error = '' }); Write-Output "PASS $Name" }
function Write-CiError([string]$Detail) {
    if ($Detail.Length -gt 12000) { $Detail = $Detail.Substring($Detail.Length - 12000) }
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
function Run-SystemPhase([string]$Phase, [string]$Sid = '') {
    $scriptPath = Join-Path $PSScriptRoot 'windows\SystemScenario.ps1'
    $command = "& '$($scriptPath.Replace("'", "''"))' -Root '$($root.Replace("'", "''"))' -Phase '$Phase' -ExpectedUserSid '$Sid'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 8) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $taskPrincipal -Settings $settings -Force | Out-Null
    $resultPath = Join-Path $root "$Phase.result.json"
    $lastRun = (Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes(8)
    while (-not (Test-Path -LiteralPath $resultPath)) {
        if ((Get-Date) -gt $deadline) { throw "SYSTEM phase timed out: $Phase" }
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        if ($info.LastRunTime -gt $lastRun -and (Get-ScheduledTask -TaskName $taskName).State -notin @('Running', 'Queued')) {
            throw "SYSTEM phase '$Phase' exited without a result (task code $($info.LastTaskResult))."
        }
        Start-Sleep -Milliseconds 250
    }
    while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
        if ((Get-Date) -gt $deadline) { throw "SYSTEM phase did not exit: $Phase" }
        Start-Sleep -Milliseconds 200
    }
    $result = Get-Content $resultPath -Raw | ConvertFrom-Json
    foreach ($case in @($result.Cases)) { $cases.Add($case) }
    Check ($result.Identity -match '(?i)SYSTEM$') 'Scheduled scenario did not run as SYSTEM.'
    $errors = @($result.Cases | Where-Object { -not $_.Success } | ForEach-Object { $_.Error }) -join "`n"
    Check ($result.Success -and (Get-ScheduledTaskInfo -TaskName $taskName).LastTaskResult -eq 0) "SYSTEM phase failed: $Phase. $errors (see transcript artifact)."
}
try {
    & (Join-Path $PSScriptRoot 'windows\New-Fixture.ps1') -Root $root -WixPath $WixPath
    $config = Get-Content (Join-Path $root 'fixture-config.json') -Raw | ConvertFrom-Json
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
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutputPath "{1}"' -f $userScript, $userResult
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Credential $credential -LoadUserProfile -WorkingDirectory $userOutput -PassThru -RedirectStandardOutput (Join-Path $userOutput 'stdout.log') -RedirectStandardError (Join-Path $userOutput 'stderr.log')
    $handle = $process.Handle
    if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'Standard-user scenario timed out.' }
    Check ($process.ExitCode -eq 0 -and (Test-Path $userResult)) 'Standard-user scenario failed (see stdout/stderr artifacts).'
    $result = Get-Content $userResult -Raw | ConvertFrom-Json
    Check (-not $result.IsAdmin -and $result.Sid -eq $user.Sid.Value) 'Test used the wrong user token.'
    Check (@($result.TamperAttempts | Where-Object { -not $_.Blocked }).Count -eq 0) 'Standard user could modify privileged runtime/queue/journal/another owner request.'
    Check $result.PolicyWriteBlocked 'Standard user could rewrite catalog policy.'
    Check ($result.SharedShortcut -and $result.LaunchExitCode -eq 0 -and $result.LaunchOutput -match 'fixture OK') 'Machine MSI was not accessible to the second standard user.'
    Record 'Real standard-user ACL enforcement, policy protection and all-users executable/shortcut access'
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
        try { Stop-ProductTasks; Run-SystemPhase Cleanup } catch { $failed = $true; Write-Warning "Fixture cleanup failed: $_" }
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
    [pscustomobject]@{ Success = (-not $failed); OS = [Environment]::OSVersion.VersionString; Cases = @($cases.ToArray()) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ResultsDirectory 'summary.json') -Encoding UTF8
}
if ($failed) { throw 'Windows SYSTEM integration failed; inspect uploaded test-results artifacts.' }
Write-Output "$($cases.Count) Windows integration checks passed."
