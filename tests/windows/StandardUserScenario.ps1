[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$base = Join-Path $env:ProgramData '__Softwarekatalog'
$requests = Join-Path $base 'Requests'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Test account must not be an administrator.' }
Write-Output 'Checking privileged file and policy write denials'
$attempts = @()
foreach ($path in @((Join-Path $base 'SelfServiceWinget.ps1'), (Join-Path $base 'Queue\injected.json'), (Join-Path $base 'Scope-Repairs.json'), (Join-Path $requests 'system-owner.tmp'))) {
    $blocked = $false
    try { [IO.File]::WriteAllText($path, 'tamper attempt') } catch [UnauthorizedAccessException] { $blocked = $true }
    $attempts += [pscustomobject]@{ Path = $path; Blocked = $blocked }
}
$policyBlocked = $false
try { New-ItemProperty -Path 'HKLM:\Software\Policies\STL\Softwarekatalog' -Name Enabled -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null } catch { $policyBlocked = $true }
Write-Output 'Invoking the generated request helper'
& (Join-Path $base 'Request-App.ps1') -AppAlias ci
Write-Output 'Writing spoofed and invalid requests'
$created = @(Get-ChildItem -LiteralPath $requests -Filter '*.json')
if ($created.Count -ne 1) { throw 'Generated user helper did not create exactly one request.' }
$payload = Get-Content $created[0].FullName -Raw | ConvertFrom-Json
$payload | Add-Member -NotePropertyName RequestedBySid -NotePropertyValue 'S-1-5-18'
$payload | Add-Member -NotePropertyName RequestedBy -NotePropertyValue 'SYSTEM'
$payload | ConvertTo-Json | Set-Content -LiteralPath $created[0].FullName -Encoding UTF8
@{ Command = 'Install'; AppAlias = 'not-approved' } | ConvertTo-Json | Set-Content (Join-Path $requests 'unapproved.json') -Encoding UTF8
@{ Command = 'Uninstall'; AppAlias = 'ci' } | ConvertTo-Json | Set-Content (Join-Path $requests 'required-uninstall.json') -Encoding UTF8
'[{"Command":"Install","AppAlias":"ci"}]' | Set-Content (Join-Path $requests 'array-root.json') -Encoding UTF8
@{ Command = 'Install'; AppAlias = 'ci'; Padding = ('a' * 40000) } | ConvertTo-Json | Set-Content (Join-Path $requests 'oversized.json') -Encoding UTF8
$machineFixture = Get-ChildItem -LiteralPath $env:ProgramFiles -Directory -Filter 'SoftwarekatalogCiFixture-*' | Select-Object -First 1
if (-not $machineFixture) { throw 'No machine fixture to launch.' }
Write-Output 'Launching the installed all-users executable'
$output = & (Join-Path $machineFixture.FullName 'fixture.exe')
$exitCode = $LASTEXITCODE
$shortcut = @(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('CommonPrograms')) -Filter 'Softwarekatalog CI Fixture *.lnk').Count -gt 0
[pscustomobject]@{
    Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    IsAdmin = $false; TamperAttempts = $attempts; PolicyWriteBlocked = $policyBlocked
    SharedShortcut = $shortcut; LaunchExitCode = $exitCode; LaunchOutput = [string]$output
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output 'Standard-user scenario completed'
