[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputPath,
    [ValidateSet('Standard','Administrator','AdministratorFiltered')][string]$AccountKind = 'Standard',
    [Parameter(Mandatory)][string]$SpoofedIdentitySid,
    [Parameter(Mandatory)][string]$FixtureRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath (Join-Path $FixtureRoot '.disposable-ci-fixture'))) { throw 'Missing disposable account-test fixture marker.' }
$base = Join-Path $env:ProgramData '__Softwarekatalog'
$requests = Join-Path $base 'Requests'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$tokenIsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($AccountKind -eq 'Standard' -and $tokenIsAdmin) { throw 'Standard test account must not be an administrator.' }
if ($AccountKind -eq 'Administrator' -and -not $tokenIsAdmin) { throw 'Administrator scenario requires an actually elevated BA token.' }
if ($AccountKind -eq 'AdministratorFiltered' -and $tokenIsAdmin) { throw 'Filtered administrator scenario requires a real unelevated token.' }
$productType = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ProductOptions' -Name ProductType).ProductType
if ($productType -notin @('WinNT','ServerNT','LanmanNT')) { throw 'Unknown actual Windows product type; cannot prove the authorization lane.' }
$isServer = $productType -ne 'WinNT'
$expectHelperBlocked = $isServer -and $AccountKind -ne 'Administrator'
$requestDirectory = if ($isServer -and $AccountKind -eq 'Administrator') { Join-Path $base 'AdminRequests' } else { $requests }
Write-Output 'Checking privileged file and policy write denials'
$attempts = @()
$adminDropAttempts = @()
$policyBlocked = $false
if ($AccountKind -eq 'Standard') {
    foreach ($path in @((Join-Path $base 'SelfServiceWinget.ps1'), (Join-Path $base 'Queue\injected.json'), (Join-Path $base 'Scope-Repairs.json'), (Join-Path $requests 'system-owner.tmp'))) {
        $blocked = $false
        try { [IO.File]::WriteAllText($path, 'tamper attempt') } catch [UnauthorizedAccessException] { $blocked = $true }
        $attempts += [pscustomobject]@{ Path = $path; Blocked = $blocked }
    }
    try { New-ItemProperty -Path 'HKLM:\Software\Policies\STL\Softwarekatalog' -Name Enabled -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null } catch { $policyBlocked = $true }
    if ($isServer) {
        $adminDrop = Join-Path $base 'AdminRequests'
        $attackSource = Join-Path $requests 'admin-drop-attack.tmp'
        Set-Content -LiteralPath $attackSource -Value '{"Command":"Install","AppAlias":"ci"}' -Encoding UTF8
        # Prove this actual account/provider can create hardlinks on the SAME
        # volume before interpreting the protected destination's failure.
        $controlLink = Join-Path $requests 'admin-drop-hardlink-control.tmp'
        New-Item -ItemType HardLink -Path $controlLink -Value $attackSource -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $controlLink -Force
        foreach ($operation in @('Write','Move','Hardlink')) {
            $blocked = $false; $errorDetail = ''
            try {
                $destination = Join-Path $adminDrop ("standard-$operation.json")
                switch ($operation) {
                    Write { [IO.File]::WriteAllText($destination, '{"Command":"Install","AppAlias":"ci"}') }
                    Move { Move-Item -LiteralPath $attackSource -Destination $destination -ErrorAction Stop }
                    Hardlink { New-Item -ItemType HardLink -Path $destination -Value $attackSource -ErrorAction Stop | Out-Null }
                }
            }
            catch { $blocked = $true; $errorDetail = $_ | Out-String }
            $adminDropAttempts += [pscustomobject]@{ Operation = $operation; Blocked = $blocked; Error = $errorDetail }
        }
        Remove-Item -LiteralPath $attackSource -Force -ErrorAction SilentlyContinue
    }
}
Write-Output 'Invoking the generated request helper'
$helperBlocked = $false; $helperError = ''
try { & (Join-Path $base 'Request-App.ps1') -AppAlias ci } catch { $helperBlocked = $true; $helperError = $_ | Out-String }
$created = @(Get-ChildItem -LiteralPath $requestDirectory -Filter '*.json' -File)
if ($expectHelperBlocked) {
    if (-not $helperBlocked -or $created.Count -ne 0) { throw 'Server unelevated-user helper must reject Install without creating a request.' }
}
else {
    if ($helperBlocked -or $created.Count -ne 1) { throw "Authorized account helper must create exactly one request: $helperError" }
    $name = if ($AccountKind -eq 'Administrator') { 'admin-install.json' } else { 'standard-helper.json' }
    $path = Join-Path $requestDirectory $name
    Move-Item -LiteralPath $created[0].FullName -Destination $path
    $payload = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $payload | Add-Member -NotePropertyName RequestedBySid -NotePropertyValue $SpoofedIdentitySid -Force
    $payload | Add-Member -NotePropertyName RequestedBy -NotePropertyValue 'Forged JSON identity' -Force
    $payload | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}
if ($AccountKind -eq 'Standard') {
    if ($isServer) {
        # Same-volume move preserves the real BA owner. An attacker who initially
        # has FullControl can supply content AND then hide its own writable ACE.
        # Even a final BA/SYSTEM-only file DACL is not authenticated provenance.
        $writableRequest = Join-Path $requests 'standard-admin-owned-writable.json'
        Move-Item -LiteralPath (Join-Path $FixtureRoot 'admin-owned-writable-template.json') -Destination $writableRequest
        @{ Command = 'Install'; AppAlias = 'ci'; RequestedBySid = $SpoofedIdentitySid; RequestedBy = 'Forged administrator' } |
            ConvertTo-Json | Set-Content -LiteralPath $writableRequest -Encoding UTF8
        $owner = (Get-Acl -LiteralPath $writableRequest).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -ne 'S-1-5-32-544') { throw 'Writable privileged-owner attack fixture did not preserve its genuine BA owner.' }
        $forgedAcl = Get-Acl -LiteralPath $writableRequest
        $forgedAcl.PurgeAccessRules([Security.Principal.WindowsIdentity]::GetCurrent().User)
        Set-Acl -LiteralPath $writableRequest -AclObject $forgedAcl
    }
    Write-Output 'Writing owned raw requests that forge SYSTEM/admin identity and Required/System source'
    @{ Command = 'Install'; AppAlias = 'ci'; RequestedBySid = $SpoofedIdentitySid; RequestedBy = 'Forged administrator' } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $requests 'standard-spoof-identity.json') -Encoding UTF8
    foreach ($spoof in @(
        @{ Name = 'standard-spoof-system.json'; Sid = 'S-1-5-18'; Source = 'System'; Required = $true },
        @{ Name = 'standard-spoof-admin.json'; Sid = $SpoofedIdentitySid; Source = 'User'; Required = $true },
        @{ Name = 'standard-spoof-required.json'; Sid = 'S-1-5-18'; Source = 'Required'; Required = $false }
    )) {
        @{ Command = 'Install'; AppAlias = 'ci'; RequestedBySid = $spoof.Sid; RequestedBy = 'Forged'; Source = $spoof.Source; Required = $spoof.Required } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $requests $spoof.Name) -Encoding UTF8
    }
    @{ Command = 'Install'; AppAlias = 'ci'; RequestedBySid = $SpoofedIdentitySid; UserInstallAuthorizationVersion = 1 } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $requests 'standard-spoof-authorization.json') -Encoding UTF8
    @{ Command = 'Install'; AppAlias = 'not-approved' } | ConvertTo-Json | Set-Content (Join-Path $requests 'unapproved.json') -Encoding UTF8
    @{ Command = 'Uninstall'; AppAlias = 'ci' } | ConvertTo-Json | Set-Content (Join-Path $requests 'required-uninstall.json') -Encoding UTF8
    @{ Command = 'Uninstall'; AppAlias = 'ci' } | ConvertTo-Json | Set-Content (Join-Path $requests 'standard-uninstall.deferred') -Encoding UTF8
    '[{"Command":"Install","AppAlias":"ci"}]' | Set-Content (Join-Path $requests 'array-root.json') -Encoding UTF8
    @{ Command = 'Install'; AppAlias = 'ci'; Padding = ('a' * 40000) } | ConvertTo-Json | Set-Content (Join-Path $requests 'oversized.json') -Encoding UTF8
}
$machineFixture = Get-ChildItem -LiteralPath $env:ProgramFiles -Directory -Filter 'SoftwarekatalogCiFixture-*' | Select-Object -First 1
if (-not $machineFixture) { throw 'No machine fixture to launch.' }
Write-Output 'Launching the installed all-users executable'
$output = & (Join-Path $machineFixture.FullName 'fixture.exe')
$exitCode = $LASTEXITCODE
$shortcut = @(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('CommonPrograms')) -Filter 'Softwarekatalog CI Fixture *.lnk').Count -gt 0
[pscustomobject]@{
    Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    IsAdmin = $tokenIsAdmin; AccountKind = $AccountKind; ProductType = $productType; IsServer = $isServer
    HelperBlocked = $helperBlocked; HelperError = $helperError; RequestDirectory = $requestDirectory
    TamperAttempts = $attempts; AdminDropTamperAttempts = $adminDropAttempts; PolicyWriteBlocked = $policyBlocked
    SharedShortcut = $shortcut; LaunchExitCode = $exitCode; LaunchOutput = [string]$output
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Output "$AccountKind account scenario completed"
